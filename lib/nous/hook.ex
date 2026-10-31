defmodule Nous.Hook do
  @moduledoc """
  Lifecycle interceptors for agent tool execution and request/response flow.

  Hooks provide granular control over agent behavior at specific lifecycle
  events. They can block actions, modify inputs/outputs, and execute external
  commands for policy enforcement.

  ## Hook Events

  | Event | When Fired | Can Block? |
  |-------|-----------|-----------|
  | `:session_start` | Agent run begins | No |
  | `:pre_request` | Before LLM API call | Yes |
  | `:post_response` | After LLM response received, before anything sees it | Yes (`{:modify, %{response: text}}` rewrites it) |
  | `:pre_tool_use` | Before each tool execution | Yes |
  | `:post_tool_use` | After each tool execution | No (can modify result) |
  | `:pre_node` | Before each workflow node (`Nous.Workflow.Engine`) | Yes (`:deny` / `{:pause, reason}`) |
  | `:post_node` | After each workflow node | No (can modify workflow state) |
  | `:session_end` | After run completes | No |

  ## Hook Types

  - `:function` — Inline function `fn event, payload -> result end`
  - `:module` — Module implementing `Nous.Hook` behaviour
  - `:command` — Shell command executed via `NetRunner.run/2`
  - `:decision` — A `Nous.Hook.Decision` config: the payload is classified by
    a `Nous.DecisionModel` and mapped to allow / escalate / deny through
    per-question probability bands. It is the only type that receives the
    runner's `env` (approval handler, agent name, task, tool); see
    `Nous.Hook.Runner.run/4`.

  ## Matchers

  Matchers filter hooks to specific tools (for `:pre_tool_use` / `:post_tool_use`):

  - `nil` — matches all tool calls
  - `"tool_name"` — exact name match
  - `~r/pattern/` — regex match on tool name
  - `fn payload -> boolean end` — arbitrary predicate

  ## Examples

      # Block dangerous tool calls
      %Nous.Hook{
        event: :pre_tool_use,
        matcher: "delete_file",
        type: :function,
        handler: fn _event, %{arguments: %{"path" => path}} ->
          if String.starts_with?(path, "/etc"), do: :deny, else: :allow
        end
      }

      # External policy check via an external command. `:command` handlers are an
      # argv list, never a shell string — there is no shell, so no word splitting
      # and no expansion. `Nous.Hook.Runner` rejects a raw string with
      # `{:error, :invalid_command_handler}`.
      %Nous.Hook{
        event: :pre_tool_use,
        matcher: ~r/^(write|delete)/,
        type: :command,
        handler: ["python3", "scripts/policy_check.py"],
        timeout: 5_000
      }
  """

  alias __MODULE__

  @type event ::
          :pre_tool_use
          | :post_tool_use
          | :pre_request
          | :post_response
          # Dispatched by Nous.Workflow.Engine, not the agent runner.
          | :workflow_start
          | :workflow_end
          | :pre_node
          | :post_node
          | :session_start
          | :session_end

  @type hook_type :: :function | :module | :command | :decision

  @type result :: :allow | :deny | {:deny, String.t()} | {:modify, map()} | {:error, term()}

  @type matcher :: String.t() | Regex.t() | (map() -> boolean()) | nil

  @type t :: %Hook{
          event: event(),
          matcher: matcher(),
          handler:
            (event(), map() -> result()) | module() | [String.t()] | Nous.Hook.Decision.t(),
          priority: integer(),
          timeout: non_neg_integer() | :infinity,
          name: String.t() | nil,
          fail_closed: boolean()
        }

  @enforce_keys [:event, :type, :handler]
  defstruct [
    :event,
    :handler,
    :name,
    type: :function,
    matcher: nil,
    priority: 100,
    # Milliseconds a :function/:module handler may run before it is killed and
    # treated as `{:error, :timeout}` (also bounds :command hooks, and each
    # decision-model call of a :decision hook). `:infinity` runs a
    # :function/:module handler in the calling process, unbounded.
    timeout: 10_000,
    # When set, runtime errors (raised exceptions, timeouts, non-0/2 exit codes
    # from command hooks) fail closed: a blocking event (:pre_tool_use,
    # :pre_request, :post_response) is denied, and on :post_tool_use the tool
    # result is withheld. Defaults to false to preserve existing fail-open
    # behavior (`Hook.new/2` defaults it to true for :decision hooks); set to
    # true on hooks that gate security-sensitive operations so a broken hook
    # can't silently bypass the check.
    fail_closed: false
  ]

  @doc """
  Handle a hook event with the given payload.

  Return `:allow` to proceed, `:deny` or `{:deny, reason}` to block,
  or `{:modify, changes}` to modify the payload.
  """
  @callback handle(event(), payload :: map()) :: result()

  @blocking_events [:pre_tool_use, :pre_request, :post_response]

  @doc """
  Returns whether an event type supports blocking (returning `:deny`).
  """
  @spec blocking_event?(event()) :: boolean()
  def blocking_event?(event), do: event in @blocking_events

  @doc """
  Check if a hook's matcher matches the given payload.

  For `:pre_tool_use` and `:post_tool_use` events, matches against the tool name.
  For other events, `nil` matchers always match.
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(%Hook{matcher: nil}, _payload), do: true

  def matches?(%Hook{matcher: name}, %{tool_name: tool_name}) when is_binary(name) do
    name == tool_name
  end

  def matches?(%Hook{matcher: %Regex{} = re}, %{tool_name: tool_name}) do
    Regex.match?(re, tool_name)
  end

  def matches?(%Hook{matcher: fun}, payload) when is_function(fun, 1) do
    fun.(payload)
  end

  def matches?(_hook, _payload), do: true

  @doc """
  Create a new hook.

  The type defaults to `:function`, or to `:decision` when `:handler` is a
  `Nous.Hook.Decision`. Decision hooks default to `fail_closed: true`.

      Nous.Hook.new(:post_response,
        name: "output_guard",
        handler: Nous.Hook.Decision.new(model: dm, questions: questions, bands: bands)
      )
  """
  @spec new(event(), keyword()) :: t()
  def new(event, opts \\ []) do
    handler = Keyword.fetch!(opts, :handler)

    type =
      Keyword.get_lazy(opts, :type, fn ->
        if match?(%Nous.Hook.Decision{}, handler), do: :decision, else: :function
      end)

    %Hook{
      event: event,
      type: type,
      handler: handler,
      matcher: Keyword.get(opts, :matcher),
      priority: Keyword.get(opts, :priority, 100),
      timeout: Keyword.get(opts, :timeout, 10_000),
      name: Keyword.get(opts, :name),
      # Reachable via the constructor so a security-gating hook can opt into
      # fail-closed (a crashing/timing-out hook on a blocking event denies).
      # A decision hook is a security control by construction, so it starts
      # closed.
      fail_closed: Keyword.get(opts, :fail_closed, type == :decision)
    }
  end
end

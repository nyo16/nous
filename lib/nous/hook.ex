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
  | `:post_response` | After LLM response received | No |
  | `:pre_tool_use` | Before each tool execution | Yes |
  | `:post_tool_use` | After each tool execution | No (can modify result) |
  | `:session_end` | After run completes | No |

  ## Hook Types

  - `:function` — Inline function `fn event, payload -> result end`
  - `:module` — Module implementing `Nous.Hook` behaviour
  - `:command` — Shell command executed via `NetRunner.run/2`

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

      # External policy check via shell command
      %Nous.Hook{
        event: :pre_tool_use,
        matcher: ~r/^(write|delete)/,
        type: :command,
        handler: "python3 scripts/policy_check.py",
        timeout: 5_000
      }
  """

  @type event ::
          :pre_tool_use
          | :post_tool_use
          | :pre_request
          | :post_response
          | :session_start
          | :session_end

  @type hook_type :: :function | :module | :command

  @type result :: :allow | :deny | {:deny, String.t()} | {:modify, map()} | {:error, term()}

  @type matcher :: String.t() | Regex.t() | (map() -> boolean()) | nil

  @type t :: %__MODULE__{
          event: event(),
          matcher: matcher(),
          type: hook_type(),
          handler: (event(), map() -> result()) | module() | String.t(),
          priority: integer(),
          timeout: non_neg_integer(),
          name: String.t() | nil
        }

  @enforce_keys [:event, :type, :handler]
  defstruct [
    :event,
    :handler,
    :name,
    type: :function,
    matcher: nil,
    priority: 100,
    timeout: 10_000
  ]

  @doc """
  Handle a hook event with the given payload.

  Return `:allow` to proceed, `:deny` or `{:deny, reason}` to block,
  or `{:modify, changes}` to modify the payload.
  """
  @callback handle(event(), payload :: map()) :: result()

  @blocking_events [:pre_tool_use, :pre_request]

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
  def matches?(%__MODULE__{matcher: nil}, _payload), do: true

  def matches?(%__MODULE__{matcher: name}, %{tool_name: tool_name}) when is_binary(name) do
    name == tool_name
  end

  def matches?(%__MODULE__{matcher: %Regex{} = re}, %{tool_name: tool_name}) do
    Regex.match?(re, tool_name)
  end

  def matches?(%__MODULE__{matcher: fun}, payload) when is_function(fun, 1) do
    fun.(payload)
  end

  def matches?(_hook, _payload), do: true

  @doc """
  Create a new function hook.
  """
  @spec new(event(), keyword()) :: t()
  def new(event, opts \\ []) do
    %__MODULE__{
      event: event,
      type: Keyword.get(opts, :type, :function),
      handler: Keyword.fetch!(opts, :handler),
      matcher: Keyword.get(opts, :matcher),
      priority: Keyword.get(opts, :priority, 100),
      timeout: Keyword.get(opts, :timeout, 10_000),
      name: Keyword.get(opts, :name)
    }
  end
end

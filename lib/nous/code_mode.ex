defmodule Nous.CodeMode do
  @moduledoc """
  Mode resolution and the visible tool set for Code Mode.

  Code Mode lets the model write a *program* that calls tools — looping,
  branching, fanning out — in one round trip, instead of emitting a chain of
  individual tool calls. The program runs on a `Nous.CodeRuntime` provider; the
  tools it may call are the same ones a direct call would reach, through the
  same permission policy.

  ## Modes

    * `:native` — no Code Mode. The model sees the tools and calls them
      directly. This is what every existing agent does.
    * `:code` — the model sees **only** `run_code`. Tools are reachable from
      inside a program and nowhere else.
    * `:both` — the model sees the tools *and* `run_code`, and picks per turn.
      A single `file_read` is already ideal as a native call; a ten-step search
      is not.

  Resolution order: the agent's `:code_mode` field, then
  `config :nous, :code_mode`, then `:both`. As with
  `Nous.Sandbox.Policy.default_mode/0`, a configured value may be a string (it
  often comes from an env var) and is matched against a literal whitelist —
  never `String.to_atom/1`.

  ## Degrading without a runtime

  `:both` needs a runtime to be worth advertising: with none configured it
  behaves as `:native` rather than showing the model a `run_code` that can only
  fail, since the native path is right there. `:code` is *not* degraded — an
  operator who asked for code mode gets `run_code`, and calling it without a
  provider returns an actionable error (see `Nous.Tools.RunCode`) instead of
  silently reverting to a mode they turned off.

  Configure a provider with:

      config :nous, :code_runtime, {MyApp.CodeRuntime, budget_ms: 5_000}

  ## `run_code` sits outside the restriction layers

  `visible_tools/4` injects `run_code` **after** `Nous.Permissions.filter_tools/2`
  has run. A restriction that denies every tool still leaves Code Mode's entry
  point reachable — otherwise a deny-all policy would not restrict the agent,
  it would mute it. That is not a hole: `run_code` still dispatches through the
  whole pipeline, so a pre-tool hook or a permission plugin can inspect the
  program text before it executes, and every tool the program calls is filtered
  by the same policy through `bindings/4`.

  ## One permission mechanism

  `bindings/4` derives the program's callable surface from
  `Nous.Permissions.filter_tools/2`. A granted tool becomes a real closure,
  already scoped to the caller; a denied one becomes a stub that returns an
  error naming the tool. Both appear, so a program that calls a denied tool
  reads a comprehensible refusal instead of crashing on an undefined function —
  and there is exactly one place that decides what may run.
  """

  alias Nous.CodeMode.Sdk
  alias Nous.CodeRuntime.Binding
  alias Nous.{Permissions, RunContext, Tool, ToolExecutor}

  require Logger

  @typedoc """
  How the model reaches tools this run.
  """
  @type mode :: :native | :code | :both

  @typedoc """
  A tool dispatch: what actually runs a sub-call made from inside a program.

  Sub-call scheduling, ordering and session-event logging live behind this
  function, which is why `bindings/4` takes it as an option instead of calling
  the executor directly.
  """
  @type dispatch :: (Tool.t(), map(), RunContext.t() -> {:ok, term()} | {:error, term()})

  @modes [:native, :code, :both]
  @default_mode :both
  @run_code_name "run_code"

  # The key that marks a tool call as transport rather than model. It lives on
  # the call map, which only Nous itself constructs — a provider response
  # carries a name, an id and an arguments blob, and nothing a model writes can
  # become a sibling key of those.
  @parent_token_key :_code_mode_parent

  @doc """
  The three modes.
  """
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  The name of the transport tool.
  """
  @spec run_code_name() :: String.t()
  def run_code_name, do: @run_code_name

  @doc """
  Normalise a mode given as an atom or a string.

  Raises `ArgumentError` on anything else, at the point of configuration rather
  than mid-run.

  ## Examples

      iex> Nous.CodeMode.new(:code)
      :code

      iex> Nous.CodeMode.new("both")
      :both

  """
  @spec new(term()) :: mode()
  def new(mode), do: coerce_mode!(mode)

  @doc """
  The application-wide default mode.
  """
  @spec default_mode() :: mode()
  def default_mode do
    case Application.get_env(:nous, :code_mode) do
      nil -> @default_mode
      configured -> coerce_mode!(configured)
    end
  end

  @doc """
  The mode for an agent: its own `:code_mode`, else `default_mode/0`.

  Takes anything with a `:code_mode` key, so it works on an agent, a plain map
  in a test, or `nil`.

  ## Examples

      iex> Nous.CodeMode.resolve(%{code_mode: :code})
      :code

      iex> Nous.CodeMode.resolve(nil)
      :both

  """
  @spec resolve(map() | nil) :: mode()
  def resolve(%{code_mode: mode}) when mode in @modes, do: mode
  def resolve(_agent), do: default_mode()

  @doc """
  The configured runtime provider, or an error message explaining what to do.

  Accepts `{module, config}` or a bare module (config defaults to `[]`), and
  checks the module actually implements the behaviour, so a typo is reported
  here rather than as an `UndefinedFunctionError` inside a tool call.
  """
  @spec runtime() :: {:ok, {module(), term()}} | {:error, String.t()}
  def runtime do
    case Application.get_env(:nous, :code_runtime) do
      nil ->
        {:error,
         "no code runtime is configured. Set `config :nous, :code_runtime, {MyProvider, config}` " <>
           "with a module implementing the Nous.CodeRuntime behaviour, or run this agent with " <>
           "code_mode: :native and call tools directly."}

      {module, config} when is_atom(module) ->
        check_runtime(module, config)

      module when is_atom(module) ->
        check_runtime(module, [])

      other ->
        {:error,
         "config :nous, :code_runtime must be a module or {module, config}, got #{inspect(other)}"}
    end
  end

  @doc """
  Whether a usable runtime provider is configured.
  """
  @spec runtime_configured?() :: boolean()
  def runtime_configured?, do: match?({:ok, _}, runtime())

  @doc """
  The tool set the model sees, given `mode`.

  `all_tools` is the set *before* the permission policy ran and `granted` the
  set after; both are needed because the SDK declares what the program may call
  (granted) while its bindings also stub what it may not (all).

  Injection happens here, after the filter, on purpose — see the moduledoc.

  ## Options

    * `:policy` — the `Nous.Permissions.Policy` in force, carried into the
      bindings so the program is filtered by the same mechanism.
  """
  @spec visible_tools(mode(), [Tool.t()], [Tool.t()], keyword()) :: [Tool.t()]
  def visible_tools(mode, all_tools, granted, opts \\ [])

  def visible_tools(:native, _all_tools, granted, _opts), do: granted

  def visible_tools(:code, all_tools, granted, opts) do
    [run_code_tool(all_tools, granted, opts)]
  end

  def visible_tools(:both, all_tools, granted, opts) do
    if runtime_configured?() do
      granted ++ [run_code_tool(all_tools, granted, opts)]
    else
      granted
    end
  end

  @doc """
  Build the `run_code` tool for this request.

  The generated SDK rides in the tool's description, which is where the model
  reads it: under `mode: :code` it is the only declaration of the tools that
  reaches the prompt at all. That also makes `Nous.CodeMode.Sdk`'s byte
  stability load-bearing — this string is part of the prompt prefix of every
  request in the run.

  `retries: 0` is deliberate. A program has side effects by the time it fails;
  re-running it because the model's code threw would repeat them.
  """
  @spec run_code_tool([Tool.t()], [Tool.t()], keyword()) :: Tool.t()
  def run_code_tool(all_tools, granted, opts \\ []) do
    tool = Tool.from_module(Nous.Tools.RunCode, retries: 0, timeout: tool_timeout_ms())
    policy = Keyword.get(opts, :policy)

    %{
      tool
      | description: "#{tool.description}\n\n#{Sdk.render(language(), granted)}",
        function: fn ctx, args ->
          Nous.Tools.RunCode.run(ctx, args, tools: all_tools, policy: policy)
        end
    }
  end

  @doc """
  Whether a model-direct call to `tool_name` collapses to "unknown tool".

  Under `mode: :code` the model was shown exactly one tool, so a call to any
  other one — hallucinated, or replayed from a transcript recorded in another
  mode — can only fail. It is refused here, *before* pre-tool hooks run: a
  guard must never be asked to approve a call that cannot execute, because an
  approval it grants is a decision about nothing.

  A sub-dispatch made from inside a program carries a parent token (see
  `tag_transport/2`) marking it as transport rather than model, and is let
  through.
  """
  @spec collapsed?(mode(), String.t(), map()) :: boolean()
  def collapsed?(:code, tool_name, call) when tool_name != @run_code_name do
    not transport_call?(call)
  end

  def collapsed?(_mode, _tool_name, _call), do: false

  @doc """
  What the model is told when a call collapses. Names the way back in, so the
  next turn is a `run_code` call rather than the same mistake.
  """
  @spec collapse_message(String.t()) :: String.t()
  def collapse_message(tool_name) do
    "Tool not found: #{tool_name}. This agent runs in code mode: the only tool you can call " <>
      "directly is `#{@run_code_name}`. Reach #{tool_name} from inside a program, with " <>
      "#{Sdk.global()}[\"#{tool_name}\"]({...})."
  end

  @doc """
  Mint a parent token for one `run_code` execution.
  """
  @spec new_parent_token() :: String.t()
  def new_parent_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  Tag a synthesised tool call as transport, so `collapsed?/3` lets it through.
  """
  @spec tag_transport(map(), String.t()) :: map()
  def tag_transport(call, token) when is_map(call) and is_binary(token) do
    Map.put(call, @parent_token_key, token)
  end

  @doc """
  Whether a tool call was synthesised by a running program rather than sent by
  the model.
  """
  @spec transport_call?(term()) :: boolean()
  def transport_call?(call) when is_map(call) do
    is_binary(Nous.ToolCall.field(call, @parent_token_key))
  end

  def transport_call?(_call), do: false

  @doc """
  The bindings a program is given: one global, one function per tool.

  Granted tools — those that survive `Nous.Permissions.filter_tools/2` — get a
  closure that dispatches the real tool with the caller's context. Denied tools
  get a stub returning an error naming the tool. Both are present, so the
  program never hits an undefined function and never gets to distinguish
  "denied" from "failed" by the shape of what it caught.

  ## Options

    * `:dispatch` — a `t:dispatch/0` replacing the default, `direct_dispatch/3`.
      This is where a sub-call scheduler plugs in: serialisation,
      `max_parallel`, argument snapshots and session-event logging all live
      behind it.
  """
  @spec bindings([Tool.t()], Permissions.Policy.t() | nil, RunContext.t(), keyword()) ::
          [Binding.t()]
  def bindings(tools, policy, %RunContext{} = run_ctx, opts \\ []) when is_list(tools) do
    dispatch = Keyword.get(opts, :dispatch) || (&direct_dispatch/3)
    granted = policy |> filter_tools(tools) |> MapSet.new(& &1.name)

    functions =
      tools
      |> Enum.filter(&is_binary(&1.name))
      |> Enum.uniq_by(& &1.name)
      |> Map.new(fn tool ->
        {tool.name, binding_fun(tool, MapSet.member?(granted, tool.name), run_ctx, dispatch)}
      end)

    [%Binding{global: Sdk.global(), functions: functions, error_class: Sdk.error_class()}]
  end

  @doc """
  Run one sub-call directly, with no scheduling in front of it.

  This is the default `t:dispatch/0`, and the one a scheduler should sit on top
  of rather than calling `Nous.ToolExecutor.execute/3` itself: the executor has
  a **three**-shape return (`{:ok, result}`, `{:ok, result, %ContextUpdate{}}`,
  `{:error, reason}`) and a dispatch must hand back two. Folding that here, in
  one place, is what keeps a tool that returns a context update from looking
  like a contract breach to everything downstream.

  The context update is dropped, loudly. There is no agent context at this
  depth to merge it into — a `%Nous.RunContext{}` is not one — so the honest
  options are "drop it and say so" or "lie". A caller that owns a
  `Nous.Agent.Context` should pass its own dispatch and merge properly.
  """
  @spec direct_dispatch(Tool.t(), map(), RunContext.t()) :: {:ok, term()} | {:error, map()}
  def direct_dispatch(%Tool{} = tool, args, %RunContext{} = run_ctx) do
    case ToolExecutor.execute(tool, args, run_ctx) do
      {:ok, value} ->
        {:ok, value}

      {:ok, value, _context_update} ->
        Logger.warning(
          "Tool '#{tool.name}' returned a context update from inside a code run; " <>
            "dropping it — a program has no agent context to merge into"
        )

        {:ok, value}

      {:error, reason} ->
        {:error, error_payload(tool.name, error_message(reason))}
    end
  end

  @doc """
  The language the configured provider runs, as an SDK language.

  Falls back to `:javascript` when nothing is configured or the provider names
  a language this repo cannot generate an SDK for — a provider must not be able
  to break tool visibility by reporting an exotic language.
  """
  @spec language() :: Sdk.language()
  def language do
    case runtime() do
      {:ok, {module, config}} -> reported_language(module, config)
      {:error, _reason} -> :javascript
    end
  end

  @doc """
  How long one `run_code` call may take, in milliseconds.

  This is the caller's patience, not a budget the program can ask for: real
  budgets — wall clock, memory, instruction count — are provider configuration,
  validated when the provider is configured.
  """
  @spec await_timeout_ms() :: pos_integer()
  def await_timeout_ms do
    case Application.get_env(:nous, :code_run_timeout_ms, 120_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 120_000
    end
  end

  # ---------------------------------------------------------------------------

  # Slack over the await so the tool executor's own kill never races the
  # in-tool timeout, which produces the better message of the two.
  defp tool_timeout_ms, do: await_timeout_ms() + 5_000

  defp reported_language(module, config) do
    if function_exported?(module, :language, 1) do
      case Sdk.coerce_language(module.language(config)) do
        {:ok, language} ->
          language

        :error ->
          Logger.warning(
            "Code runtime #{inspect(module)} reports a language no SDK generator supports; " <>
              "rendering the SDK as JavaScript"
          )

          :javascript
      end
    else
      :javascript
    end
  end

  defp check_runtime(module, config) do
    if Code.ensure_loaded?(module) and function_exported?(module, :start_run, 2) do
      {:ok, {module, config}}
    else
      {:error,
       "configured code runtime #{inspect(module)} does not implement Nous.CodeRuntime " <>
         "(no start_run/2). Check `config :nous, :code_runtime`."}
    end
  end

  defp filter_tools(nil, tools), do: tools

  defp filter_tools(%Permissions.Policy{} = policy, tools),
    do: Permissions.filter_tools(policy, tools)

  defp binding_fun(%Tool{} = tool, true, run_ctx, dispatch) do
    fn args -> call_tool(dispatch, tool, args, run_ctx) end
  end

  defp binding_fun(%Tool{name: name}, false, _run_ctx, _dispatch) do
    fn _args ->
      {:error, error_payload(name, "tool #{inspect(name)} is denied by the permission policy")}
    end
  end

  defp call_tool(dispatch, tool, args, run_ctx) when is_map(args) do
    dispatch.(tool, stringify_keys(args), run_ctx)
  end

  # A guest that calls `tools["x"]()` sends nothing; that is an empty argument
  # object, not an error.
  defp call_tool(dispatch, tool, nil, run_ctx), do: dispatch.(tool, %{}, run_ctx)

  defp call_tool(_dispatch, tool, args, _run_ctx) do
    {:error, error_payload(tool.name, "arguments must be an object, got #{inspect(args)}")}
  end

  # Only the tool name and a message reach the program. Native content,
  # stacktraces and error structs stay on this side of the boundary.
  defp error_payload(name, message), do: %{"tool" => name, "message" => message}

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp error_message(reason), do: inspect(reason)

  # Tool arguments are string-keyed by convention. A guest sends JSON, so this
  # is a no-op for a real program; it is here for the internal caller that
  # hands over an atom-keyed map.
  defp stringify_keys(args) do
    Map.new(args, fn
      {key, value} when is_binary(key) -> {key, value}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {inspect(key), value}
    end)
  end

  # Never String.to_atom/1: the mode can come from an env var.
  defp coerce_mode!(mode) when mode in @modes, do: mode
  defp coerce_mode!("native"), do: :native
  defp coerce_mode!("code"), do: :code
  defp coerce_mode!("both"), do: :both

  defp coerce_mode!(other) do
    raise ArgumentError,
          "invalid code mode #{inspect(other)}; expected one of " <>
            Enum.map_join(@modes, ", ", &inspect/1)
  end
end

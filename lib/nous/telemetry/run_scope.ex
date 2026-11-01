defmodule Nous.Telemetry.RunScope do
  @moduledoc false
  # Run correlation for telemetry: which trace, agent run and tool call the
  # current process is working for.
  #
  # The scope is a map in the process dictionary. Readers check `self()`, then
  # walk `$callers` (`Nous.CallerLookup`), so tasks the runner fans out see the
  # run's scope without any signature carrying it. Sites that hop processes
  # without `$callers` (a bare `spawn`, a lazy stream enumerated elsewhere)
  # capture the scope and reinstall it with `with_scope/2` or `bind/1`.
  #
  # Scope keys:
  #
  #   * `:trace_id` — 32 lowercase hex chars; inherited by every nested run.
  #   * `:agent_run_id` — 16 lowercase hex chars; minted per agent run.
  #   * `:parent_agent_run_id` — the enclosing run's id, or nil.
  #   * `:tool_call_id` — the provider tool-call id being executed, or nil.
  #   * `:parent_tool_call_id` — the tool call that started this run, or nil.
  #   * `:role` — `:agent | :judge | :simulator | :reflector` (default `:agent`).
  #   * `:profile_id` — the id of the `Nous.Profile` the run's agent applies,
  #     or nil; `Nous.AgentRunner.Instrumentation.scoped/2` sets it from the
  #     agent, so it is never inherited from the parent run.
  #   * `:sub_agent_template` / `:sub_agent_index` — labels a SubAgent puts on
  #     the scope it starts a child run under. They describe that one child
  #     run: `start_run/1` reads them off the parent and does not hand them on.
  #
  # Ids are strings, never atoms. Every function here is total over whatever a
  # process dictionary may hold: a malformed value reads as "no scope".

  alias Nous.CallerLookup

  @key :"$nous_run_scope"

  @roles [:agent, :judge, :simulator, :reflector]

  # The keys `metadata/0` puts on every event.
  @correlation_keys [:trace_id, :agent_run_id, :parent_agent_run_id, :tool_call_id]

  # Labels that describe one child run; consumed by `start_run/1`.
  @run_labels [:sub_agent_template, :sub_agent_index, :profile_id]

  @type t :: %{optional(atom()) => term()}

  @doc false
  # The scope this process works under, or nil.
  @spec current() :: t() | nil
  def current do
    case CallerLookup.lookup(@key, &is_map/1) do
      scope when is_map(scope) -> scope
      _malformed_or_none -> nil
    end
  end

  @doc false
  # Run `fun` with `scope` installed in this process, restoring whatever this
  # process held before (also when `fun` raises, throws or exits). Restoring is
  # what keeps a nested run in a sequential tool from leaving its own scope on
  # the parent's process.
  @spec with_scope(t() | nil, (-> result)) :: result when result: var
  def with_scope(scope, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    put(scope)

    try do
      fun.()
    after
      put(previous)
    end
  end

  @doc false
  # `with_scope/2` over the current scope with `attrs` merged in.
  @spec merge_scope(map(), (-> result)) :: result when result: var
  def merge_scope(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    with_scope(Map.merge(current() || %{}, attrs), fun)
  end

  @doc false
  # Capture the current scope now and return a function that runs `fun` under
  # it later, in whatever process calls it. For task bodies and spawns.
  @spec bind((-> result)) :: (-> result) when result: var
  @spec bind((arg -> result)) :: (arg -> result) when arg: var, result: var
  def bind(fun) when is_function(fun, 0) do
    case current() do
      nil -> fun
      scope -> fn -> with_scope(scope, fun) end
    end
  end

  def bind(fun) when is_function(fun, 1) do
    case current() do
      nil -> fun
      scope -> fn arg -> with_scope(scope, fn -> fun.(arg) end) end
    end
  end

  @doc false
  # Correlation metadata for an event emitted now. Every key is always
  # present; a value is nil when unset.
  @spec metadata() :: map()
  def metadata, do: metadata(current())

  @doc false
  # Correlation metadata of `scope`. Total: anything that is not a map, and
  # any id that is not a binary, reads as nil.
  @spec metadata(term()) :: map()
  def metadata(scope) when is_map(scope) do
    Map.new(@correlation_keys, fn key -> {key, id(Map.get(scope, key))} end)
  end

  def metadata(_no_scope), do: Map.new(@correlation_keys, &{&1, nil})

  @doc false
  # `Map.merge(metadata(), meta)`: the event's own keys win, so an explicit
  # `tool_call_id` overrides the scope's.
  @spec merge(map()) :: map()
  def merge(meta) when is_map(meta), do: Map.merge(metadata(), meta)

  @doc false
  # The scope a new agent run executes under, derived from `parent` (the
  # current scope by default): `trace_id` inherited (minted when there is
  # none), a fresh `agent_run_id`, the parent's run and tool call as the
  # parents, `role` inherited. The one-run labels are copied from the parent
  # into the new scope; `install_scope/1` strips them before the run body
  # runs, so they reach this run's `run.start` but no grandchild.
  @spec start_run(term()) :: t()
  def start_run(parent \\ current()) do
    parent = if is_map(parent), do: parent, else: %{}

    labels =
      Map.new(@run_labels, fn key -> {key, label(key, Map.get(parent, key))} end)

    Map.merge(labels, %{
      trace_id: id(Map.get(parent, :trace_id)) || new_trace_id(),
      agent_run_id: new_agent_run_id(),
      parent_agent_run_id: id(Map.get(parent, :agent_run_id)),
      tool_call_id: nil,
      parent_tool_call_id: id(Map.get(parent, :tool_call_id)),
      role: role(Map.get(parent, :role))
    })
  end

  @doc false
  # The scope a run's body is installed under: `run` minus its one-run labels.
  @spec install_scope(t()) :: t()
  def install_scope(run) when is_map(run), do: Map.drop(run, @run_labels)

  @doc false
  # The `[:nous, :agent, :run, :start]` correlation metadata for `run`.
  @spec run_start_metadata(term()) :: map()
  def run_start_metadata(run) do
    run = if is_map(run), do: run, else: %{}

    run
    |> metadata()
    |> Map.merge(%{
      parent_tool_call_id: id(Map.get(run, :parent_tool_call_id)),
      profile_id: label(:profile_id, Map.get(run, :profile_id)),
      role: role(Map.get(run, :role)),
      sub_agent_template: label(:sub_agent_template, Map.get(run, :sub_agent_template)),
      sub_agent_index: label(:sub_agent_index, Map.get(run, :sub_agent_index))
    })
  end

  @doc false
  @spec new_trace_id() :: String.t()
  def new_trace_id, do: hex(16)

  @doc false
  @spec new_agent_run_id() :: String.t()
  def new_agent_run_id, do: hex(8)

  defp hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp put(scope) when is_map(scope), do: Process.put(@key, scope)
  defp put(_none), do: Process.delete(@key)

  defp id(value) when is_binary(value), do: value
  defp id(_other), do: nil

  defp role(role) when role in @roles, do: role
  defp role(_other), do: :agent

  defp label(:sub_agent_template, value) when is_binary(value), do: value
  defp label(:sub_agent_index, value) when is_integer(value) and value >= 0, do: value
  defp label(:profile_id, value) when is_binary(value), do: value
  defp label(_key, _other), do: nil
end

defmodule Nous.Eval.Trace.Collector do
  @moduledoc false
  # Collects the telemetry of eval samples into `Nous.Eval.Trace`s
  # (research/trace-design.md §3.2).
  #
  # One global handler ("nous-eval-trace") is attached to every event Nous
  # emits (`Nous.Telemetry.events/0`). It runs in the emitting process and
  # writes synchronously into an ETS sink owned by
  # `Nous.Eval.Trace.Collector.TableOwner`, so every event a finished process
  # emitted is in the sink when `Nous.run/3` returns, and a sample killed on
  # timeout keeps everything it emitted up to the kill. Only traces that were
  # registered are collected; for all other traffic the handler costs one map
  # read and one `:ets.member/2`.
  #
  # The handler is total: a raising telemetry handler is detached silently,
  # which would turn every later trace empty. Every clause catches, and
  # `run_sample/2` refuses to run when the handler is gone
  # (`{:error, :trace_handler_detached}`) rather than return empty traces.
  #
  # Storage details:
  #
  #   * Caps. Each trace has `max_events` and `max_bytes`. Bytes are the
  #     `:erlang.external_size/1` of the content fields (`messages`,
  #     `response`, `arguments`, `result`, `details`, `errors`, `error`,
  #     `reason`, `stacktrace`); the rest of an event is small and bounded by
  #     `max_events`. Once either cap is passed nothing more is stored for the
  #     trace: the trace is `truncated?` and `dropped` counts the lost events.
  #   * Request-message deltas. `[:nous, :agent, :model, :start]` carries the
  #     full request `messages` every iteration. When the previous request of
  #     the same `agent_run_id` is a prefix of this one, only the new suffix is
  #     stored (otherwise - compaction, redaction - the full list). Finalize
  #     re-expands, so finalized events always carry the full `messages`
  #     (`Nous.Eval.Trace.transcript/2` relies on it).
  #   * DecisionGuard dedupe. A DecisionGuard check on a hook surface emits
  #     both `[:nous, :decision_guard, :verdict]` and a `[:nous, :hook,
  #     :decision]` for its `"decision_guard:<surface>"` hook. The guard
  #     always emits the pair (`Nous.Hook.Decision` calls the guard's
  #     `on_verdict` after every evaluation), so the hook event is always
  #     dropped and the verdict kept. Deduped events are not counted as
  #     `dropped`.
  #   * Unfinished tool calls. A `[:nous, :agent, :tool_call, :start]` with no
  #     stop in the trace (a killed sample, a crashed run, a truncated tail)
  #     gets a synthesized stop at the end of the trace with
  #     `outcome: :incomplete`, the start's correlation keys and empty
  #     measurements. `Nous.Eval.Trace.tool_calls/2` already reports such a
  #     call as `:incomplete` and ignores stops whose outcome is
  #     `:incomplete`, so the call is not counted twice.
  #
  # Online sampling reuses `register/2`, `finalize/1` and `unregister/1`
  # with its own lifecycle.

  alias Nous.Eval.Trace
  alias Nous.Eval.Trace.Collector.TableOwner
  alias Nous.Eval.Trace.Event
  alias Nous.Telemetry.RunScope

  @handler_id "nous-eval-trace"

  @registry TableOwner.registry()
  @sink TableOwner.sink()
  @requests TableOwner.requests()

  @default_max_events 10_000
  @default_max_bytes 8_000_000
  @default_timeout 120_000

  @roles [:agent, :judge, :simulator, :reflector]

  @content_keys [
    :messages,
    :response,
    :arguments,
    :result,
    :details,
    :errors,
    :error,
    :reason,
    :stacktrace
  ]

  @model_start [:nous, :agent, :model, :start]
  @tool_start [:nous, :agent, :tool_call, :start]
  @tool_stop [:nous, :agent, :tool_call, :stop]
  @hook_decision [:nous, :hook, :decision]

  @incomplete_keys [
    :trace_id,
    :agent_run_id,
    :parent_agent_run_id,
    :tool_call_id,
    :agent_name,
    :tool_name,
    :iteration
  ]

  # Registry row positions (1-based, see TableOwner).
  @pos_events 5
  @pos_bytes 6
  @pos_dropped 7

  @type outcome :: {:ok, term()} | {:error, term()} | :killed

  @type sample :: %{outcome: outcome(), trace: Trace.t(), duration_ms: non_neg_integer()}

  @doc false
  def handler_id, do: @handler_id

  @doc false
  def defaults,
    do: %{
      max_events: @default_max_events,
      max_bytes: @default_max_bytes,
      timeout: @default_timeout
    }

  # ── handler ────────────────────────────────────────────────────────────────

  @doc false
  # Attach the collector's handler. Idempotent.
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           @handler_id,
           Nous.Telemetry.events(),
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec attached?() :: boolean()
  def attached? do
    [:nous]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == @handler_id))
  end

  @doc false
  # The telemetry handler. Total: never raises, whatever it is given.
  def handle_event(name, measurements, %{trace_id: trace_id} = metadata, _config)
      when is_binary(trace_id) do
    if :ets.member(@registry, trace_id) do
      collect(trace_id, name, measurements, metadata, System.monotonic_time())
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(_name, _measurements, _metadata, _config), do: :ok

  defp collect(trace_id, name, measurements, metadata, at) when is_list(name) do
    unless duplicate?(name, metadata) do
      measurements = if is_map(measurements), do: measurements, else: %{}
      {stored, extra, request} = compact(trace_id, name, metadata)
      bytes = content_bytes(stored, extra)

      [{_, _owner, max_events, max_bytes, _, _, _}] = :ets.lookup(@registry, trace_id)

      [events, total] =
        :ets.update_counter(@registry, trace_id, [{@pos_events, 1}, {@pos_bytes, bytes}])

      if events <= max_events and total <= max_bytes do
        key = {trace_id, at, :erlang.unique_integer([:monotonic])}
        :ets.insert(@sink, {key, name, measurements, stored, extra})
        remember_request(request)
      else
        :ets.update_counter(@registry, trace_id, {@pos_dropped, 1})
      end
    end
  end

  defp collect(_trace_id, _name, _measurements, _metadata, _at), do: :ok

  defp duplicate?(@hook_decision, %{hook_name: "decision_guard:" <> _}), do: true
  defp duplicate?(_name, _metadata), do: false

  # Returns `{metadata_to_store, extra, request_to_remember}`.
  defp compact(trace_id, @model_start, %{messages: messages, agent_run_id: run_id} = metadata)
       when is_list(messages) and is_binary(run_id) do
    key = {trace_id, run_id}

    with [{_, previous}] <- :ets.lookup(@requests, key),
         {:ok, suffix} <- strip_prefix(previous, messages) do
      {Map.delete(metadata, :messages), {:delta, suffix}, {key, messages}}
    else
      _ -> {metadata, nil, {key, messages}}
    end
  end

  defp compact(_trace_id, _name, metadata), do: {metadata, nil, nil}

  defp strip_prefix([], rest), do: {:ok, rest}
  defp strip_prefix([same | prefix], [same | rest]), do: strip_prefix(prefix, rest)
  defp strip_prefix(_prefix, _list), do: :error

  defp remember_request(nil), do: :ok
  defp remember_request(request), do: :ets.insert(@requests, request)

  defp content_bytes(metadata, extra) do
    fields =
      Enum.reduce(@content_keys, 0, fn key, acc ->
        case metadata do
          %{^key => value} when not is_nil(value) -> acc + :erlang.external_size(value)
          _ -> acc
        end
      end)

    case extra do
      {:delta, suffix} -> fields + :erlang.external_size(suffix)
      nil -> fields
    end
  end

  # ── registration ───────────────────────────────────────────────────────────

  @doc false
  # Start collecting `trace_id`. Options: `:max_events`, `:max_bytes`
  # (positive integers), `:owner` (the pid whose death lets the table owner
  # sweep the registration; default `self()`).
  @spec register(String.t(), keyword()) :: :ok | {:error, term()}
  def register(trace_id, opts \\ [])

  def register(trace_id, opts) when is_binary(trace_id) and trace_id != "" and is_list(opts) do
    with {:ok, max_events} <- pos_int_opt(opts, :max_events, @default_max_events),
         {:ok, max_bytes} <- pos_int_opt(opts, :max_bytes, @default_max_bytes),
         {:ok, owner} <- owner_opt(opts),
         :ok <- ensure_tables() do
      row = {trace_id, owner, max_events, max_bytes, 0, 0, 0}

      if :ets.insert_new(@registry, row), do: :ok, else: {:error, :trace_id_in_use}
    end
  end

  def register(trace_id, _opts), do: {:error, {:invalid_trace_id, trace_id}}

  @doc false
  # Stop collecting `trace_id` and discard what was collected.
  @spec unregister(String.t()) :: :ok
  def unregister(trace_id) when is_binary(trace_id) do
    :ets.delete(@registry, trace_id)
    delete_rows(trace_id)
    :ok
  end

  @doc false
  # Stop collecting `trace_id` and return its trace. The registration is
  # taken first, so an event racing the finalize is either in the trace or
  # dropped, never left behind for long (the table owner sweeps rows of
  # unregistered traces). An unknown `trace_id` (never registered, or lost
  # with a restarted table owner) yields a `truncated?` trace: its events
  # cannot be known complete.
  @spec finalize(String.t()) :: Trace.t()
  def finalize(trace_id) when is_binary(trace_id) do
    registration = :ets.take(@registry, trace_id)
    rows = :ets.select(@sink, [{{{trace_id, :_, :_}, :_, :_, :_, :_}, [], [:"$_"]}])
    delete_rows(trace_id)

    {truncated?, dropped} =
      case registration do
        [{_, _, _, _, _, _, dropped}] -> {dropped > 0, dropped}
        [] -> {true, 0}
      end

    %Trace{
      trace_id: trace_id,
      events: build_events(rows),
      truncated?: truncated?,
      dropped: dropped
    }
  end

  defp delete_rows(trace_id) do
    :ets.select_delete(@sink, [{{{trace_id, :_, :_}, :_, :_, :_, :_}, [], [true]}])
    :ets.match_delete(@requests, {{trace_id, :_}, :_})
  end

  # `rows` come from an ordered_set select, so they are already sorted by
  # `{monotonic, unique}`.
  defp build_events(rows) do
    {events, _requests} =
      Enum.map_reduce(rows, %{}, fn {{_trace_id, at, _unique}, name, measurements, metadata,
                                     extra},
                                    requests ->
        {metadata, requests} = expand(name, metadata, extra, requests)
        {{name, measurements, metadata, at}, requests}
      end)

    (events ++ incomplete_stops(events))
    |> Enum.with_index()
    |> Enum.map(fn {{name, measurements, metadata, at}, seq} ->
      %Event{name: name, measurements: measurements, metadata: metadata, at: at, seq: seq}
    end)
  end

  defp expand(@model_start, %{agent_run_id: run_id} = metadata, {:delta, suffix}, requests) do
    messages = Map.get(requests, run_id, []) ++ suffix
    {Map.put(metadata, :messages, messages), Map.put(requests, run_id, messages)}
  end

  defp expand(@model_start, %{agent_run_id: run_id, messages: messages} = metadata, nil, requests)
       when is_binary(run_id) and is_list(messages) do
    {metadata, Map.put(requests, run_id, messages)}
  end

  defp expand(_name, metadata, _extra, requests), do: {metadata, requests}

  defp incomplete_stops([]), do: []

  defp incomplete_stops(events) do
    {_, _, _, last_at} = List.last(events)

    stopped =
      for {@tool_stop, _, %{tool_call_id: id}, _} <- events,
          is_binary(id),
          into: MapSet.new(),
          do: id

    {stops, _seen} =
      events
      |> Enum.filter(fn
        {@tool_start, _, %{tool_call_id: id}, _} ->
          is_binary(id) and not MapSet.member?(stopped, id)

        _ ->
          false
      end)
      |> Enum.flat_map_reduce(MapSet.new(), fn {_, _, metadata, _}, seen ->
        if MapSet.member?(seen, metadata.tool_call_id) do
          {[], seen}
        else
          stop = metadata |> Map.take(@incomplete_keys) |> Map.put(:outcome, :incomplete)
          {[{@tool_stop, %{}, stop, last_at}], MapSet.put(seen, metadata.tool_call_id)}
        end
      end)

    stops
  end

  # ── sample lifecycle ───────────────────────────────────────────────────────

  @doc false
  # Run one sample under a fresh trace and collect it.
  #
  # Options:
  #
  #   * `:trace_id` - the trace to seed (default: a new one)
  #   * `:timeout` - ms before the sample is killed (default 120_000)
  #   * `:role` - the scope role (default `:agent`)
  #   * `:max_events` / `:max_bytes` - trace caps (defaults 10_000 / 8_000_000)
  #   * `:supervisor` - the `Task.Supervisor` to run under (default
  #     `Nous.TaskSupervisor`)
  #
  # `fun` runs in a task under `RunScope.with_scope(%{trace_id:, role:}, fun)`.
  # The outcome is `{:ok, result}` / `{:error, reason}` for a `fun` returning
  # those (any other value `v` is `{:ok, v}`), `{:error, {:exit, reason}}`
  # when it raised or exited, and `:killed` when it ran past `:timeout`; a
  # killed sample keeps the events it emitted before the kill.
  #
  # Returns `{:error, :trace_handler_detached}` without running `fun` when the
  # handler is not attached, and `{:error, reason}` for invalid options or a
  # `trace_id` already being collected.
  @spec run_sample((-> term()), keyword()) :: {:ok, sample()} | {:error, term()}
  def run_sample(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    with {:ok, opts} <- sample_opts(opts),
         :ok <- ensure_attached(),
         :ok <- register(opts.trace_id, max_events: opts.max_events, max_bytes: opts.max_bytes) do
      started = System.monotonic_time()

      outcome =
        try do
          run_task(fun, opts)
        catch
          kind, reason ->
            unregister(opts.trace_id)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      trace = finalize(opts.trace_id)

      duration_ms =
        System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

      {:ok, %{outcome: outcome, trace: trace, duration_ms: duration_ms}}
    end
  end

  defp run_task(fun, opts) do
    scope = %{trace_id: opts.trace_id, role: opts.role}

    task =
      Task.Supervisor.async_nolink(opts.supervisor, fn -> RunScope.with_scope(scope, fun) end)

    case Task.yield(task, opts.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:ok, other}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> :killed
    end
  end

  defp ensure_attached do
    if attached?(), do: :ok, else: {:error, :trace_handler_detached}
  end

  defp ensure_tables do
    if :ets.whereis(@registry) == :undefined, do: {:error, :trace_tables_missing}, else: :ok
  end

  defp sample_opts(opts) do
    with {:ok, opts} <-
           Keyword.validate(opts, [
             :trace_id,
             :timeout,
             :role,
             :max_events,
             :max_bytes,
             :supervisor
           ]),
         {:ok, timeout} <- pos_int_opt(opts, :timeout, @default_timeout),
         {:ok, max_events} <- pos_int_opt(opts, :max_events, @default_max_events),
         {:ok, max_bytes} <- pos_int_opt(opts, :max_bytes, @default_max_bytes),
         {:ok, role} <- role_opt(opts),
         {:ok, trace_id} <- trace_id_opt(opts) do
      {:ok,
       %{
         trace_id: trace_id,
         timeout: timeout,
         role: role,
         max_events: max_events,
         max_bytes: max_bytes,
         supervisor: Keyword.get(opts, :supervisor) || Nous.TaskSupervisor
       }}
    else
      {:error, unknown} when is_list(unknown) -> {:error, {:unknown_options, unknown}}
      error -> error
    end
  end

  defp pos_int_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {:invalid_option, key, other}}
    end
  end

  defp role_opt(opts) do
    case Keyword.get(opts, :role, :agent) do
      role when role in @roles -> {:ok, role}
      other -> {:error, {:invalid_option, :role, other}}
    end
  end

  defp trace_id_opt(opts) do
    case Keyword.get(opts, :trace_id) do
      nil -> {:ok, RunScope.new_trace_id()}
      id when is_binary(id) and id != "" -> {:ok, id}
      other -> {:error, {:invalid_option, :trace_id, other}}
    end
  end

  defp owner_opt(opts) do
    case Keyword.get(opts, :owner, self()) do
      pid when is_pid(pid) -> {:ok, pid}
      other -> {:error, {:invalid_option, :owner, other}}
    end
  end
end

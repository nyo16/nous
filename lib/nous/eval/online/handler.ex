defmodule Nous.Eval.Online.Handler do
  @moduledoc false
  # The request-path half of `Nous.Eval.Online`: a telemetry handler on the
  # agent run events, running in the emitting process.
  #
  # Root `run.start` (not an eval-internal role, no parent run): count it,
  # decide deterministically (`Nous.Eval.Online.Sampler`), apply the agent
  # allowlist and the filter, admit against `max_in_flight` (atomics,
  # drop-new), and register the trace with `Nous.Eval.Trace.Collector`.
  # Root `run.stop` / `run.exception` of a captured trace: mark it closed and
  # send it to the coordinator if the queue counter admits it (drop-new),
  # else discard its events.
  #
  # O(1) and non-blocking: a few atomics and ETS operations, at most one
  # `send/2`, never a `GenServer.call`. The handler is total: every clause
  # catches, because `:telemetry` silently detaches a raising handler.

  alias Nous.Eval.Online.{Counters, Sampler}
  alias Nous.Eval.Trace.Collector

  @run_start [:nous, :agent, :run, :start]
  @run_stop [:nous, :agent, :run, :stop]
  @run_exception [:nous, :agent, :run, :exception]

  @doc false
  def events, do: [@run_start, @run_stop, @run_exception]

  @doc false
  def handle_event(@run_start, measurements, metadata, config) do
    start(measurements, metadata, config)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(name, measurements, metadata, config)
      when name in [@run_stop, @run_exception] do
    stop(name, measurements, metadata, config)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(_name, _measurements, _metadata, _config), do: :ok

  # ── run start ──────────────────────────────────────────────────────────────

  defp start(measurements, %{trace_id: tid, agent_run_id: rid} = meta, config)
       when is_binary(tid) and is_binary(rid) and is_map(config) do
    if root?(meta) do
      Counters.add(config.counters, :seen_roots)

      if Sampler.below?(key(meta, config), config.threshold) and agent?(meta, config) and
           filter?(meta, config) do
        Counters.add(config.counters, :sampled)
        admit(tid, rid, measurements, meta, config)
      end
    end
  end

  defp start(_measurements, _meta, _config), do: :ok

  # Eval-internal runs (judges, simulators, reflectors - also those an
  # online scorer starts) are never sampled: online eval would otherwise
  # score its own judge calls.
  defp root?(meta),
    do:
      is_nil(Map.get(meta, :parent_agent_run_id)) and
        Map.get(meta, :role, :agent) in [:agent, nil]

  defp key(meta, %{sample_by: :session, counters: counters}) do
    case Map.get(meta, :session_id) do
      session when is_binary(session) and session != "" ->
        session

      _ ->
        Counters.add(counters, :session_key_missing)
        meta.trace_id
    end
  end

  defp key(meta, _config), do: meta.trace_id

  defp agent?(_meta, %{agents: nil}), do: true
  defp agent?(meta, %{agents: agents}), do: MapSet.member?(agents, Map.get(meta, :agent_name))

  defp filter?(_meta, %{filter: nil}), do: true

  defp filter?(meta, %{filter: filter, counters: counters}) do
    case filter.(meta) do
      true ->
        true

      false ->
        false

      _other ->
        Counters.add(counters, :filter_error)
        false
    end
  catch
    _kind, _reason ->
      Counters.add(counters, :filter_error)
      false
  end

  defp admit(tid, rid, measurements, meta, config) do
    %{counters: counters} = config

    if Counters.add_get(counters, :in_flight, 1) > config.max_in_flight do
      Counters.add(counters, :in_flight, -1)
      Counters.add(counters, :dropped_admission)
    else
      opts = [owner: config.registry, max_events: config.max_events, max_bytes: config.max_bytes]

      case Collector.register(tid, opts) do
        :ok ->
          now = System.monotonic_time(:millisecond)
          :ets.insert(config.table, {tid, rid, now, :open, now})
          Counters.add(counters, :captured)
          Collector.handle_event(@run_start, measurements, meta, nil)

        {:error, _already_collected_or_invalid} ->
          Counters.add(counters, :in_flight, -1)
      end
    end
  end

  # ── run stop ───────────────────────────────────────────────────────────────

  defp stop(name, measurements, %{trace_id: tid, agent_run_id: rid} = meta, config)
       when is_binary(tid) and is_binary(rid) and is_map(config) do
    case :ets.lookup(config.table, tid) do
      [{^tid, ^rid, _started, :open, _changed}] ->
        Collector.handle_event(name, measurements, meta, nil)
        if close(config.table, tid, rid), do: enqueue(tid, :closed, config)

      _ ->
        :ok
    end
  end

  defp stop(_name, _measurements, _meta, _config), do: :ok

  @doc false
  # Atomically moves an open trace to closed; false when it was already
  # closed (a sweep and a late stop racing).
  @spec close(:ets.tid(), String.t(), String.t()) :: boolean()
  def close(table, tid, rid) do
    now = System.monotonic_time(:millisecond)

    :ets.select_replace(table, [
      {{tid, rid, :"$1", :open, :_}, [], [{{tid, rid, :"$1", :closed, now}}]}
    ]) == 1
  end

  @doc false
  # Hands a closed trace to the coordinator, or discards it when the queue
  # is full or the coordinator is down. `kind` is `:closed | :abandoned`.
  @spec enqueue(String.t(), :closed | :abandoned, map()) :: :ok
  def enqueue(tid, kind, %{counters: counters} = config) do
    coordinator = Process.whereis(config.coordinator)

    cond do
      is_nil(coordinator) ->
        Counters.add(counters, :dropped_queue)
        discard(tid, config)

      Counters.add_get(counters, :queued, 1) > config.max_queue ->
        Counters.add(counters, :queued, -1)
        Counters.add(counters, :dropped_queue)
        discard(tid, config)

      true ->
        send(coordinator, {:job, tid, kind})
        :ok
    end
  end

  @doc false
  # Forgets a captured trace and its events.
  @spec discard(String.t(), map()) :: :ok
  def discard(tid, %{table: table, counters: counters}) do
    if :ets.take(table, tid) != [] do
      Collector.unregister(tid)
      Counters.add(counters, :in_flight, -1)
    end

    :ok
  end
end

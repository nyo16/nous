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

      {key, salt} = key(meta, config)

      if Sampler.below?(key, config.threshold, salt) and agent?(meta, config) and
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

  # `{key, salt}`: a session id is keyed with the configured salt; the trace
  # id (random already) never is.
  defp key(meta, %{sample_by: :session, counters: counters} = config) do
    case Map.get(meta, :session_id) do
      session when is_binary(session) and session != "" ->
        {session, config.sampling_salt}

      _ ->
        Counters.add(counters, :session_key_missing)
        {meta.trace_id, nil}
    end
  end

  defp key(meta, _config), do: {meta.trace_id, nil}

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
  #
  # A handed-over row is `{:queued, coordinator_pid}` until its job starts
  # (`:running`, `running/2`) and takes it: the sweep leaves both alone
  # however long the backlog is. Every row counted in `queued` is released
  # exactly once if its coordinator dies holding it:
  #
  #   * the coordinator still alive after the mark: if it dies later, its
  #     successor's `init/1` releases the row (`release_stale/2`);
  #   * already dead: the successor's `init/1` may have run before the mark,
  #     so the row is released here. Both releases are one atomic
  #     `select_replace/2` on `{:queued, pid}`, so only one of them finds the
  #     row and corrects the `queued` gauge.
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
        :ets.update_element(config.table, tid, {4, {:queued, coordinator}})
        send(coordinator, {:job, tid, kind})

        unless Process.alive?(coordinator) do
          released = release_owned(config.table, tid, coordinator)
          Counters.add(counters, :queued, -released)
        end

        :ok
    end
  end

  @doc false
  # The coordinator started the row's job: the row is no longer counted in
  # `queued`, and stays held until the job takes it.
  @spec running(:ets.tid(), String.t()) :: :ok
  def running(table, tid) do
    :ets.update_element(table, tid, {4, :running})
    :ok
  end

  @doc false
  # Rows go back to `:closed`, keeping their close time, when no
  # coordinator holds their job any more. The sweep then counts them `lost`
  # once they are older than `max_trace_age`.
  #
  # `release_stale/2`, from a coordinator's `init/1`: rows queued to any
  # other (earlier, dead) coordinator, and rows of jobs such a coordinator
  # started; returns how many were queued, for the `queued` gauge. Rows
  # queued to `owner` itself - handlers already see its registered name
  # during `init/1` - are kept.
  @spec release_stale(:ets.tid(), pid()) :: non_neg_integer()
  def release_stale(table, owner) do
    queued =
      :ets.select_replace(table, [
        {{:"$1", :"$2", :"$3", {:queued, :"$4"}, :"$5"}, [{:"=/=", :"$4", {:const, owner}}],
         [{{:"$1", :"$2", :"$3", :closed, :"$5"}}]}
      ])

    release_running_match(table, :"$1")
    queued
  end

  @doc false
  # The row of a job that ended without taking it.
  @spec release_running(:ets.tid(), String.t()) :: non_neg_integer()
  def release_running(table, tid) when is_binary(tid), do: release_running_match(table, tid)

  defp release_running_match(table, tid) do
    :ets.select_replace(table, [
      {{tid, :"$2", :"$3", :running, :"$5"}, [], [{{tid, :"$2", :"$3", :closed, :"$5"}}]}
    ])
  end

  defp release_owned(table, tid, owner) do
    :ets.select_replace(table, [
      {{tid, :"$2", :"$3", {:queued, owner}, :"$5"}, [], [{{tid, :"$2", :"$3", :closed, :"$5"}}]}
    ])
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

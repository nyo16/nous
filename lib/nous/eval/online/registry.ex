defmodule Nous.Eval.Online.Registry do
  @moduledoc false
  # Owns the state the request path writes: the ETS table of captured
  # traces (`{trace_id, root_run_id, started_ms, state, changed_ms}`, state
  # `:open | :closed | {:queued, coordinator_pid} | :running`), the
  # instance's `:atomics` counters, and the telemetry handler
  # (`Nous.Eval.Online.Handler`), attached in `init/1` and detached in
  # `terminate/2`. A row is held by a coordinator from `Handler.enqueue/3`
  # (`{:queued, pid}`) through its job's start (`:running`) until the job
  # takes it, or until the job or the coordinator ends without it
  # (`Handler.release_running/2`, `Handler.release_stale/2`).
  #
  # Periodically it:
  #
  #   * sweeps traces older than `max_trace_age`: an open one (its run never
  #     stopped - killed, cancelled, an abandoned stream) is finalized as
  #     abandoned through the normal pipeline; a closed one no coordinator
  #     holds (lost with a restarted coordinator) is discarded and counted
  #     `lost`. A held one is left alone: a backlog is slow, not lost
  #   * re-attaches the handler if `:telemetry` detached it, and the trace
  #     collector's handler with it
  #   * emits the window's coverage (`[:nous, :eval, :online, :window]` and
  #     one `[:nous, :eval, :online, :dropped]` per non-zero drop reason)

  use GenServer

  alias Nous.Eval.Online.{Counters, Handler}
  alias Nous.Eval.Trace.Collector

  @window_event [:nous, :eval, :online, :window]
  @dropped_event [:nous, :eval, :online, :dropped]
  @reattached_event [:nous, :eval, :online, :handler_reattached]

  def start_link(config),
    do: GenServer.start_link(__MODULE__, config, name: name(config.name))

  @doc false
  def name(instance_name), do: Module.concat(instance_name, Registry)

  @doc false
  def handler_id(instance_name), do: {Nous.Eval.Online, instance_name}

  @doc false
  # The handler config: everything the request path and the jobs share.
  def shared(instance_name), do: GenServer.call(name(instance_name), :shared)

  @doc false
  # Runs a sweep and a window report now.
  def tick(instance_name), do: GenServer.call(name(instance_name), :tick)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

    shared = %{
      instance: config.instance,
      table: table,
      counters: Counters.new(),
      registry: self(),
      coordinator: Nous.Eval.Online.Coordinator.name(config.name),
      threshold: config.threshold,
      sample_by: config.sample_by,
      sampling_salt: config.sampling_salt,
      agents: config.agents,
      filter: config.filter,
      max_in_flight: config.max_in_flight,
      max_queue: config.max_queue,
      max_events: config.max_events,
      max_bytes: config.max_bytes
    }

    state = %{config: config, shared: shared, handler_id: handler_id(config.name)}
    :ok = Collector.attach()
    attach(state)
    Process.send_after(self(), :sweep, config.sweep_interval)
    Process.send_after(self(), :window, config.window_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:shared, _from, state), do: {:reply, state.shared, state}

  def handle_call(:tick, _from, state) do
    sweep(state)
    window(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    Process.send_after(self(), :sweep, state.config.sweep_interval)
    {:noreply, state}
  end

  def handle_info(:window, state) do
    window(state)
    Process.send_after(self(), :window, state.config.window_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)

    state.shared.table
    |> :ets.select([{{:"$1", :_, :_, :_, :_}, [], [:"$1"]}])
    |> Enum.each(&Collector.unregister/1)

    :ok
  end

  defp attach(state) do
    # A previous incarnation killed without `terminate/2` may have left its
    # handler, bound to tables that no longer exist.
    :telemetry.detach(state.handler_id)

    :ok =
      :telemetry.attach_many(
        state.handler_id,
        Handler.events(),
        &Handler.handle_event/4,
        state.shared
      )
  end

  defp sweep(state) do
    unless attached?(state.handler_id) do
      attach(state)

      :telemetry.execute(@reattached_event, %{count: 1}, %{instance: state.config.instance})
    end

    :ok = Collector.attach()
    expire(state)
  end

  defp attached?(id) do
    [:nous, :agent, :run, :start]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == id))
  end

  defp expire(%{config: config, shared: shared}) do
    cutoff = System.monotonic_time(:millisecond) - config.max_trace_age

    expired = [{:<, :"$5", cutoff}, {:orelse, {:"=:=", :"$4", :open}, {:"=:=", :"$4", :closed}}]

    shared.table
    |> :ets.select([{{:"$1", :"$2", :"$3", :"$4", :"$5"}, expired, [{{:"$1", :"$2", :"$4"}}]}])
    |> Enum.each(fn
      {tid, rid, :open} ->
        if Handler.close(shared.table, tid, rid) do
          Counters.add(shared.counters, :abandoned)
          Handler.enqueue(tid, :abandoned, shared)
        end

      {tid, _rid, :closed} ->
        Counters.add(shared.counters, :lost)
        Handler.discard(tid, shared)
    end)
  end

  defp window(%{config: config, shared: shared}) do
    counts = Counters.take_window(shared.counters)
    meta = %{instance: config.instance, window_ms: config.window_ms}
    :telemetry.execute(@window_event, counts, meta)

    for {key, reason} <- Counters.drop_reasons(), (count = Map.fetch!(counts, key)) > 0 do
      :telemetry.execute(@dropped_event, %{count: count}, %{
        instance: config.instance,
        reason: reason
      })
    end

    :ok
  end
end

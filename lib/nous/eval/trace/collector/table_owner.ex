defmodule Nous.Eval.Trace.Collector.TableOwner do
  @moduledoc false
  # Owns the ETS tables of `Nous.Eval.Trace.Collector`, so the tables outlive
  # any one eval run, sample task or emitting process, and a sample killed on
  # timeout still has its events in the sink when the caller finalizes it.
  #
  # Tables (all public and named, written by the telemetry handler in the
  # emitting process):
  #
  #   * registry - `set`, one row per collected trace:
  #     `{trace_id, owner, max_events, max_bytes, events, bytes, dropped}`.
  #     The last three are counters bumped with `:ets.update_counter/3`.
  #   * sink - `ordered_set` keyed `{trace_id, monotonic, unique}`, rows
  #     `{key, event_name, measurements, metadata, extra}`, so one trace's
  #     events are a contiguous key range in arrival order.
  #   * requests - `ordered_set` keyed `{trace_id, agent_run_id}`: the last
  #     model request messages of each run, for request-message delta storage.
  #
  # A periodic sweep removes what a caller that died mid-sample left behind:
  # registrations whose owner is dead, and sink/request rows of traces that
  # are no longer registered (events that raced an unregister).

  use GenServer

  @registry :nous_eval_trace_registry
  @sink :nous_eval_trace_sink
  @requests :nous_eval_trace_requests

  @sweep_interval :timer.minutes(1)

  def registry, do: @registry
  def sink, do: @sink
  def requests, do: @requests

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # Run one sweep now (synchronously, in the owner).
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(_opts) do
    :ets.new(@registry, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@sink, [:ordered_set, :public, :named_table, write_concurrency: true])
    :ets.new(@requests, [:ordered_set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    do_sweep()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp do_sweep do
    dead =
      :ets.select(@registry, [{{:"$1", :"$2", :_, :_, :_, :_, :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reject(fn {_trace_id, owner} -> is_pid(owner) and Process.alive?(owner) end)

    Enum.each(dead, fn {trace_id, _owner} -> :ets.delete(@registry, trace_id) end)

    sweep_sink(:ets.first(@sink))

    :ets.select(@requests, [{{{:"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.reject(&:ets.member(@registry, &1))
    |> Enum.each(&:ets.match_delete(@requests, {{&1, :_}, :_}))
  end

  # Walks the sink one trace at a time: `{trace_id, :end, :end}` sorts after
  # every `{trace_id, integer, integer}` key and before the next trace's keys,
  # so `:ets.next/2` jumps over a whole trace without visiting its rows.
  defp sweep_sink(:"$end_of_table"), do: :ok

  defp sweep_sink({trace_id, _monotonic, _unique}) do
    unless :ets.member(@registry, trace_id) do
      :ets.select_delete(@sink, [{{{trace_id, :_, :_}, :_, :_, :_, :_}, [], [true]}])
    end

    sweep_sink(:ets.next(@sink, {trace_id, :end, :end}))
  end
end

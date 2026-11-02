defmodule Nous.Eval.Online.Coordinator do
  @moduledoc false
  # The single writer of one online instance on this node.
  #
  #   * Jobs. The request path sends `{:job, trace_id, kind}` after checking
  #     the `queued` counter, so the mailbox never holds more than
  #     `max_queue` jobs. Jobs start under the instance's `Task.Supervisor`
  #     (`max_children: max_concurrency`); `{:error, :max_children}` leaves
  #     the rest queued until a job ends.
  #   * Budget. A fixed-window ledger (`budget: [per: ...]`). A job reserves
  #     a model-graded scorer's worst case before calling it and settles
  #     the actual cost afterwards, so parallel judges cannot overshoot
  #     `max_cost` together.
  #   * Store. Samples are batched into one `Nous.Eval.Run` of task
  #     `"online:<instance>"` per flush (`batch_size` samples, or once a
  #     window), written with `store_retries` attempts `store_backoff` ms
  #     apart, then dropped and counted. The store state is owned here and
  #     nowhere else, so there is one writer per node.
  #   * Retention. `delete_runs_before/3` on the instance's task, at start
  #     and every `prune_interval`.
  #   * Export. After a batch is stored, each sample goes to the
  #     `exporter`, in a task.

  use GenServer

  require Logger

  alias Nous.Eval.Online.{Counters, Handler, Job, Registry}
  alias Nous.Eval.{Run, Sample}

  @budget_event [:nous, :eval, :online, :budget_exhausted]

  def start_link(config),
    do: GenServer.start_link(__MODULE__, config, name: name(config.name))

  @doc false
  def name(instance_name), do: Module.concat(instance_name, Coordinator)

  @doc false
  def task_sup(instance_name), do: Module.concat(instance_name, TaskSup)

  @doc false
  def scorer_sup(instance_name), do: Module.concat(instance_name, ScorerSup)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    with {:ok, store} <- init_store(config) do
      shared = Registry.shared(config.name)
      # Jobs queued to a previous incarnation died with its mailbox: their
      # rows are no longer held, so the sweep may count them lost, and they
      # leave the `queued` gauge. Rows already queued to this process (its
      # name is registered before `init/1` runs) stay held and counted.
      released = Handler.release_stale(shared.table, self())
      Counters.add(shared.counters, :queued, -released)

      state = %{
        config: config,
        shared: shared,
        store: store,
        queue: :queue.new(),
        running: %{},
        batch: [],
        waiters: [],
        ledger: %{window: nil, spent: 0.0, reserved: 0.0}
      }

      Process.send_after(self(), :flush_tick, config.window_ms)
      send(self(), :prune)
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:store_init_failed, reason}}
    end
  end

  defp init_store(%{store_module: module, store_opts: opts}) do
    case module.init(opts) do
      {:ok, state} -> {:ok, {module, state}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  # ── calls ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:reserve, rule, scorer, usd}, _from, state) do
    ledger = roll(state.ledger, state.config.budget)
    %{max_cost: max_cost} = state.config.budget

    if ledger.spent + ledger.reserved + usd > max_cost do
      :telemetry.execute(@budget_event, %{spent: ledger.spent, max_cost: max_cost}, %{
        instance: state.config.instance,
        rule: rule,
        scorer: scorer
      })

      {:reply, :exhausted, %{state | ledger: ledger}}
    else
      {:reply, :ok, %{state | ledger: %{ledger | reserved: ledger.reserved + usd}}}
    end
  end

  def handle_call(:drain, from, state) do
    state = %{state | waiters: [from | state.waiters]}
    {:noreply, maybe_release(state)}
  end

  def handle_call(:prune, _from, state) do
    {reply, state} = prune(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:settle, reserved, actual}, state) do
    ledger = roll(state.ledger, state.config.budget)

    ledger = %{
      ledger
      | reserved: max(ledger.reserved - reserved, 0.0),
        spent: ledger.spent + actual
    }

    {:noreply, %{state | ledger: ledger}}
  end

  # ── messages ───────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:job, tid, kind}, state) do
    {:noreply, pump(%{state | queue: :queue.in({tid, kind}, state.queue)})}
  end

  def handle_info({:sample, %Sample{} = sample, info}, state) do
    state = %{state | batch: [{sample, info} | state.batch]}

    state =
      if length(state.batch) >= state.config.batch_size, do: flush(state), else: state

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {tid, running} ->
        if reason not in [:normal, :shutdown], do: Counters.add(state.shared.counters, :lost)
        # A job that ended before taking its row leaves the row to the sweep.
        Handler.release_running(state.shared.table, tid)
        state = pump(%{state | running: running})
        {:noreply, maybe_release(state)}
    end
  end

  def handle_info(:flush_tick, state) do
    Process.send_after(self(), :flush_tick, state.config.window_ms)
    {:noreply, flush(state)}
  end

  def handle_info({:retry, run, attempt}, state), do: {:noreply, write(state, run, attempt)}

  def handle_info(:prune, state) do
    {_reply, state} = prune(state)
    Process.send_after(self(), :prune, state.config.prune_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush(state)
    :ok
  end

  # ── jobs ───────────────────────────────────────────────────────────────────

  defp pump(state) do
    case :queue.out(state.queue) do
      {{:value, {tid, kind}}, rest} ->
        case start_job(state, tid, kind) do
          {:ok, ref} ->
            # Not atomic with a crash of this process between the two steps;
            # only that would leave the gauge off by one.
            Counters.add(state.shared.counters, :queued, -1)
            Handler.running(state.shared.table, tid)
            pump(%{state | queue: rest, running: Map.put(state.running, ref, tid)})

          :busy ->
            state
        end

      {:empty, _} ->
        state
    end
  end

  defp start_job(state, tid, kind) do
    ctx = %{
      config: state.config,
      shared: state.shared,
      coordinator: self(),
      scorer_sup: scorer_sup(state.config.name)
    }

    case Task.Supervisor.start_child(task_sup(state.config.name), fn ->
           Job.run(ctx, tid, kind)
         end) do
      {:ok, pid} -> {:ok, Process.monitor(pid)}
      {:error, :max_children} -> :busy
    end
  end

  defp maybe_release(%{waiters: []} = state), do: state

  defp maybe_release(state) do
    if :queue.is_empty(state.queue) and map_size(state.running) == 0 do
      state = flush(state)
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  # ── budget ─────────────────────────────────────────────────────────────────

  # A new window starts with nothing spent; reservations of scorers still
  # running carry over, they settle into the window they finish in.
  defp roll(ledger, %{window_ms: window_ms}) do
    window = div(System.monotonic_time(:millisecond), window_ms)

    if ledger.window == window,
      do: ledger,
      else: %{ledger | window: window, spent: 0.0}
  end

  # ── store ──────────────────────────────────────────────────────────────────

  defp flush(%{batch: []} = state), do: state

  defp flush(state) do
    run = batch_run(state.config, Enum.reverse(state.batch))
    write(%{state | batch: []}, run, 1)
  end

  defp write(state, %Run{samples: samples} = run, attempt) do
    {module, store_state} = state.store

    case safe_put(module, store_state, run) do
      {:ok, store_state} ->
        Counters.add(state.shared.counters, :stored, length(samples))
        export(state, samples)
        %{state | store: {module, store_state}}

      {:error, _reason} when attempt < state.config.store_retries ->
        Process.send_after(
          self(),
          {:retry, run, attempt + 1},
          state.config.store_backoff * attempt
        )

        state

      {:error, _reason} ->
        Counters.add(state.shared.counters, :dropped_store, length(samples))
        state
    end
  end

  defp safe_put(module, store_state, run) do
    module.put_run(store_state, run)
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  defp batch_run(config, entries) do
    samples = Enum.map(entries, &elem(&1, 0))
    infos = Map.new(entries, fn {%Sample{trace_id: tid}, info} -> {tid, info} end)
    now = DateTime.utc_now()

    started_at =
      infos
      |> Map.values()
      |> Enum.map(fn %{"captured_at" => iso} -> elem(DateTime.from_iso8601(iso), 1) end)
      |> Enum.min(DateTime, fn -> now end)

    %Run{
      id: run_id(config, now),
      task: Nous.Eval.Online.task(config.instance),
      status: :completed,
      started_at: started_at,
      finished_at: now,
      fingerprint: fingerprint(config),
      k: 1,
      samples: samples,
      summary: %{"samples" => length(samples)},
      metadata: %{
        "online" => %{
          "instance" => config.instance,
          "node" => Atom.to_string(node()),
          "nous_version" => nous_version(),
          "samples" => infos
        }
      }
    }
  end

  # `online-<instance>-<node hash>-<utc time>-<random>`: unique per node and
  # flush, valid for every store (`Nous.Eval.Store.validate_run_id/1`).
  defp run_id(config, now) do
    node_tag =
      :crypto.hash(:sha256, Atom.to_string(node()))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    stamp = now |> DateTime.truncate(:millisecond) |> Calendar.strftime("%Y%m%dt%H%M%S%fz")
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "online-#{config.instance}-#{node_tag}-#{stamp}-#{random}"
  end

  defp fingerprint(config) do
    %{
      "online" => %{
        "sample_rate" => config.sample_rate,
        "sample_by" => Atom.to_string(config.sample_by),
        "redact" => redact_name(config.redact),
        "redactor_version" => config.redactor_version,
        "rules" =>
          Enum.map(config.rules, fn rule ->
            %{
              "name" => rule.name,
              "sample_rate" => rule.sample_rate,
              "scorers" => Enum.map(rule.scorers, & &1.id)
            }
          end)
      }
    }
  end

  defp redact_name(:drop_content), do: "drop_content"
  defp redact_name(fun) when is_function(fun), do: "function"
  defp redact_name(module), do: inspect(module)

  defp nous_version do
    case Application.spec(:nous, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp export(%{config: %{exporter: nil}}, _samples), do: :ok

  defp export(state, samples) do
    exporter = state.config.exporter

    Enum.each(samples, fn sample ->
      Task.Supervisor.start_child(scorer_sup(state.config.name), fn ->
        try do
          exporter.(sample)
        catch
          _kind, _reason -> :ok
        end
      end)
    end)
  end

  # ── retention ──────────────────────────────────────────────────────────────

  defp prune(%{config: %{retention_ms: nil}} = state), do: {{:ok, 0}, state}

  defp prune(state) do
    {module, store_state} = state.store
    cutoff = DateTime.add(DateTime.utc_now(), -state.config.retention_ms, :millisecond)

    case module.delete_runs_before(
           store_state,
           Nous.Eval.Online.task(state.config.instance),
           cutoff
         ) do
      {:ok, count, store_state} ->
        {{:ok, count}, %{state | store: {module, store_state}}}

      {:error, reason} ->
        Logger.warning("Nous.Eval.Online retention prune failed: #{inspect(reason, limit: 5)}")
        {{:error, reason}, state}
    end
  end
end

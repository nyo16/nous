# Write-owner contention measurement (perf-analysis Phase 4, finding #4).
#
# Both Nous.Persistence.ETS and Nous.Workflow.Checkpoint.ETS route writes
# through a singleton TableOwner GenServer (reads go straight to ETS). This
# measures the single-owner write ceiling under concurrency to decide whether
# partitioning the owners (a la Nous.AgentRegistry) is warranted.
#
# Each job performs one BATCH of 10_000 writes split across C concurrent
# writer tasks, so writes/sec = ips * 10_000. Compare C=1 vs C=8 vs C=64:
# if batch time stays ~flat as C grows, the owner serializes but is not a
# practical bottleneck unless real workloads approach that ceiling
# (checkpoint/context saves are per agent response / workflow step — orders
# of magnitude below it).
#
#   Run: mix run bench/persistence_write_bench.exs   (benchee is a :dev dep)

alias Nous.Persistence.ETS, as: Persistence
alias Nous.Workflow.Checkpoint.ETS, as: Checkpoint

writes = 10_000

# ~2KB payload approximating a serialized context
payload = %{
  "messages" =>
    for i <- 1..10 do
      %{"role" => "user", "content" => "message #{i}: " <> String.duplicate("x", 150)}
    end,
  "deps" => %{"counter" => 42},
  "iteration" => 7
}

persistence_batch = fn concurrency ->
  per_task = div(writes, concurrency)

  1..concurrency
  |> Enum.map(fn worker ->
    Task.async(fn ->
      for i <- 1..per_task do
        :ok = Persistence.save("bench_session_#{worker}", Map.put(payload, "seq", i))
      end
    end)
  end)
  |> Task.await_many(:infinity)
end

checkpoint_batch = fn concurrency ->
  per_task = div(writes, concurrency)

  1..concurrency
  |> Enum.map(fn worker ->
    Task.async(fn ->
      for i <- 1..per_task do
        :ok =
          Checkpoint.save(%{
            run_id: "bench_run_#{worker}",
            workflow_id: "bench_wf",
            data: Map.put(payload, "seq", i)
          })
      end
    end)
  end)
  |> Task.await_many(:infinity)
end

Benchee.run(
  %{
    "persistence 10k writes, C=1" => fn -> persistence_batch.(1) end,
    "persistence 10k writes, C=8" => fn -> persistence_batch.(8) end,
    "persistence 10k writes, C=64" => fn -> persistence_batch.(64) end,
    "checkpoint 10k writes, C=1" => fn -> checkpoint_batch.(1) end,
    "checkpoint 10k writes, C=8" => fn -> checkpoint_batch.(8) end,
    "checkpoint 10k writes, C=64" => fn -> checkpoint_batch.(64) end
  },
  warmup: 1,
  time: 3,
  print: [fast_warning: false]
)

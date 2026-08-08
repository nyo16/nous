defmodule Nous.Workflow.Engine.ParallelExecutor do
  @moduledoc false
  # Parallel fan-out/fan-in for `Nous.Workflow.Engine`. Two patterns:
  # `:parallel` nodes run named branch subgraphs concurrently; `:parallel_map`
  # nodes map over a runtime-computed list, one task per item. Both fan out via
  # `Nous.Tasks.stream/3`, matching `Nous.Plugins.SubAgent`. Internal to the
  # engine — the public entry point is `Nous.Workflow.Engine.execute/2`.
  #
  # At `Nous.TaskSupervisor`'s `:max_children` ceiling both patterns run their
  # branches/items sequentially instead of failing the node: a workflow that
  # finishes slowly is worth more than one that dies because the node was busy.
  # `Nous.Tasks.stream/3` emits the same per-item tuples on either path, so the
  # `:on_error` handling and the deterministic ordering below are untouched. The
  # one casualty is the per-branch `:timeout`, which needs a task to kill — a
  # handler that hangs then hangs the node.

  alias Nous.Workflow.{State, Node}
  alias Nous.Workflow.Engine.{Executor, StateMerger}

  require Logger

  @default_max_concurrency 5
  @default_timeout 120_000

  @doc """
  Execute a `:parallel` node — static fan-out to named branches.

  Each branch ID in `config.branches` is executed as an independent node.
  Results are merged using the configured strategy.

  ## Config Keys

  - `:branches` — list of node IDs to run in parallel (required)
  - `:merge` — merge strategy: `:deep_merge`, `:list_collect`, or function (default: `:list_collect`)
  - `:max_concurrency` — max concurrent branches (default: #{@default_max_concurrency})
  - `:timeout` — per-branch timeout in ms (default: #{@default_timeout})
  - `:on_branch_error` — `:continue_others` or `:fail_fast` (default: `:continue_others`)
  - `:result_key` — key for `:list_collect` results (default: `:parallel_results`)
  """
  @spec execute_parallel(Node.t(), State.t(), map()) ::
          {:ok, term(), State.t()} | {:error, term()}
  def execute_parallel(%Node{type: :parallel} = node, %State{} = state, graph_nodes) do
    config = node.config
    branch_ids = config.branches |> Enum.map(&to_string/1)
    max_concurrency = Map.get(config, :max_concurrency, @default_max_concurrency)
    timeout = node.timeout || @default_timeout
    merge_strategy = Map.get(config, :merge, :list_collect)
    on_error = Map.get(config, :on_branch_error, :continue_others)
    result_key = Map.get(config, :result_key, :parallel_results)

    Logger.info(
      "Parallel fan-out: #{length(branch_ids)} branches (max_concurrency: #{max_concurrency})"
    )

    results =
      branch_ids
      |> Nous.Tasks.stream(
        fn branch_id ->
          branch_node = Map.fetch!(graph_nodes, branch_id)
          {branch_id, Executor.execute(branch_node, state)}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        # Carry the input (branch_id) on crash/timeout exits so failures keep
        # their attribution instead of being recorded as "unknown".
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, {branch_id, {:ok, _result, updated_state}}} ->
          # Use the branch's updated state data as the result for merging
          {:ok, branch_id, updated_state.data}

        {:ok, {branch_id, {:error, reason}}} ->
          {:error, branch_id, reason}

        {:exit, {branch_id, reason}} ->
          {:error, branch_id, {:exit, reason}}
      end)

    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _, _} -> true
        _ -> false
      end)

    if failures != [] and on_error == :fail_fast do
      [{:error, branch_id, reason} | _] = failures
      {:error, {:parallel_branch_failed, branch_id, reason}}
    else
      # Log failures
      Enum.each(failures, fn {:error, branch_id, reason} ->
        Logger.warning("Parallel branch #{branch_id} failed: #{inspect(reason)}")
      end)

      # L-11: sort by branch_id BEFORE merging so two branches that write
      # the same key produce a deterministic result (was: order depended
      # on async_stream_nolink completion order, leading to flaky
      # last-writer-wins).
      merged_results =
        successes
        |> Enum.sort_by(fn {:ok, branch_id, _} -> branch_id end)
        |> Enum.map(fn {:ok, branch_id, result} -> {branch_id, result} end)

      merged_state =
        StateMerger.merge(merged_results, state, merge_strategy, result_key: result_key)

      # Record errors for failed branches
      merged_state =
        Enum.reduce(failures, merged_state, fn {:error, branch_id, reason}, acc ->
          State.put_error(acc, branch_id, reason)
        end)

      merged_state = State.put_result(merged_state, node.id, :parallel_complete)

      {:ok, :parallel_complete, merged_state}
    end
  end

  @doc """
  Execute a `:parallel_map` node — dynamic fan-out over runtime data.

  The `items` function extracts a list from the current state. Each item
  is processed by the `handler` function in parallel.

  ## Config Keys

  - `:items` — function `(state -> list)` producing items at runtime (required)
  - `:handler` — function `(item, state -> result)` processing each item (required)
  - `:max_concurrency` — max concurrent tasks (default: #{@default_max_concurrency})
  - `:timeout` — per-item timeout in ms (default: #{@default_timeout})
  - `:on_error` — `:collect` or `:fail_fast` (default: `:collect`)
  - `:result_key` — key to store results under in `state.data` (default: `:map_results`)
  """
  @spec execute_parallel_map(Node.t(), State.t()) ::
          {:ok, term(), State.t()} | {:error, term()}
  def execute_parallel_map(%Node{type: :parallel_map} = node, %State{} = state) do
    config = node.config
    items_fn = Map.fetch!(config, :items)
    handler_fn = Map.fetch!(config, :handler)
    max_concurrency = Map.get(config, :max_concurrency, @default_max_concurrency)
    timeout = node.timeout || @default_timeout
    on_error = Map.get(config, :on_error, :collect)
    result_key = Map.get(config, :result_key, :map_results)

    items = items_fn.(state)

    Logger.info("Parallel map: #{length(items)} items (max_concurrency: #{max_concurrency})")

    if items == [] do
      updated_state =
        state
        |> State.update_data(&Map.put(&1, result_key, []))
        |> State.put_result(node.id, [])

      {:ok, [], updated_state}
    else
      results =
        items
        |> Enum.with_index()
        |> Nous.Tasks.stream(
          fn {item, index} ->
            {index, safely_run_handler(handler_fn, item, state)}
          end,
          max_concurrency: max_concurrency,
          timeout: timeout,
          on_timeout: :kill_task,
          zip_input_on_exit: true
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {index, {:ok, result}}}, {succ, fail} ->
            {[{index, result} | succ], fail}

          {:ok, {index, {:error, reason}}}, {succ, fail} ->
            {succ, [{index, reason} | fail]}

          # zip_input_on_exit gives back {input, reason}; the input is the
          # {item, index} tuple, so we recover the failed item's index.
          {:exit, {{_item, index}, reason}}, {succ, fail} ->
            {succ, [{index, {:exit, reason}} | fail]}
        end)

      {successes, all_failures} = results

      if all_failures != [] and on_error == :fail_fast do
        {:error, {:parallel_map_failed, "#{length(all_failures)} items failed"}}
      else
        finish_parallel_map(node, state, result_key, successes, all_failures)
      end
    end
  end

  defp finish_parallel_map(node, state, result_key, successes, failures) do
    # Collect successful results in original order
    successful_results =
      successes
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, result} -> result end)

    updated_state =
      state
      |> State.update_data(&Map.put(&1, result_key, successful_results))
      |> State.put_result(node.id, successful_results)

    # Record errors keyed by the failing item's index for attribution.
    updated_state =
      Enum.reduce(failures, updated_state, fn {index, reason}, acc ->
        State.put_error(acc, "#{node.id}_item_#{index}", reason)
      end)

    {:ok, successful_results, updated_state}
  end

  # Distinguish three handler outcomes:
  # 1. raised exception      -> {:error, {exception, stacktrace}}   (collected as failure)
  # 2. returned {:error, _}  -> {:error, reason}                    (collected as failure)
  # 3. returned {:ok, val}   -> {:ok, val}                          (collected as success)
  # 4. returned anything else -> {:ok, value}                       (treated as success)
  #
  # Previously the handler return value was unconditionally wrapped in :ok,
  # so {:error, _} returns silently landed in successful_results as the
  # literal tuple - :fail_fast never tripped on them and downstream nodes
  # consumed the error tuple as if it were valid output.
  defp safely_run_handler(handler_fn, item, state) do
    try do
      case handler_fn.(item, state) do
        {:ok, value} -> {:ok, value}
        {:error, _} = err -> err
        other -> {:ok, other}
      end
    rescue
      e -> {:error, {e, __STACKTRACE__}}
    end
  end
end

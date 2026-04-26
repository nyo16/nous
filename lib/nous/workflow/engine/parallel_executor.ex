defmodule Nous.Workflow.Engine.ParallelExecutor do
  @moduledoc """
  Parallel fan-out/fan-in execution for workflow nodes.

  Handles two parallelism patterns:

  - **Static parallel** (`:parallel` nodes) — runs named branches concurrently,
    each branch is a subgraph starting from a known node ID.
  - **Dynamic parallel** (`:parallel_map` nodes) — maps over a runtime-computed
    list, spawning one task per item.

  Uses `Task.Supervisor.async_stream_nolink/4` on `Nous.TaskSupervisor`,
  matching the pattern from `Nous.Plugins.SubAgent`.
  """

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
      Nous.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        branch_ids,
        fn branch_id ->
          branch_node = Map.fetch!(graph_nodes, branch_id)
          {branch_id, Executor.execute(branch_node, state)}
        end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {branch_id, {:ok, _result, updated_state}}} ->
          # Use the branch's updated state data as the result for merging
          {:ok, branch_id, updated_state.data}

        {:ok, {branch_id, {:error, reason}}} ->
          {:error, branch_id, reason}

        {:exit, reason} ->
          {:error, "unknown", {:exit, reason}}
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

      # Merge successful results
      merged_results = Enum.map(successes, fn {:ok, branch_id, result} -> {branch_id, result} end)

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
        Nous.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          Enum.with_index(items),
          fn {item, index} ->
            {index, safely_run_handler(handler_fn, item, state)}
          end,
          max_concurrency: max_concurrency,
          timeout: timeout,
          on_timeout: :kill_task
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {index, {:ok, result}}}, {succ, fail} ->
            {[{index, result} | succ], fail}

          {:ok, {index, {:error, reason}}}, {succ, fail} ->
            {succ, [{index, reason} | fail]}

          {:exit, reason}, {succ, fail} ->
            {succ, [{:exit, reason} | fail]}
        end)

      {successes, all_failures} = results

      if all_failures != [] and on_error == :fail_fast do
        {:error, {:parallel_map_failed, "#{length(all_failures)} items failed"}}
      else
        # Collect successful results in original order
        successful_results =
          successes
          |> Enum.sort_by(fn {index, _} -> index end)
          |> Enum.map(fn {_index, result} -> result end)

        updated_state =
          state
          |> State.update_data(&Map.put(&1, result_key, successful_results))
          |> State.put_result(node.id, successful_results)

        # Record errors
        updated_state =
          Enum.reduce(all_failures, updated_state, fn
            {_index, reason}, acc ->
              State.put_error(acc, "#{node.id}_item", reason)
          end)

        {:ok, successful_results, updated_state}
      end
    end
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

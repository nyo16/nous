defmodule Nous.Workflow.Engine do
  @moduledoc """
  Core workflow execution engine.

  A recursive function module (not a GenServer) that processes nodes
  according to the compiled graph topology, threading state through
  each step. Follows the same pattern as `Nous.AgentRunner`.

  ## Execution Model

  Executes nodes in topological order, following edges. Supports:
  - Sequential edges (always followed)
  - Conditional edges (followed when predicate matches)
  - Branch nodes (routing to one of multiple paths)
  - Cycles (with max-iteration guards)

  ## Error Handling

  Each node has an `error_strategy`:
  - `:fail_fast` — halt immediately
  - `{:retry, max, delay_ms}` — retry with delay
  - `:skip` — record error, continue
  - `{:fallback, node_id}` — route to fallback node

  ## Hooks

  Workflow hooks intercept execution at key points:
  - `:workflow_start` / `:workflow_end` — lifecycle events
  - `:pre_node` — before each node (can pause/block)
  - `:post_node` — after each node (can modify state)

  ## Pause/Resume

  Workflows can be paused via:
  - A `:pre_node` hook returning `{:pause, reason}`
  - An external signal via `:atomics` pause_ref
  - A `:human_checkpoint` node
  """

  alias Nous.Workflow.{Graph, State, Compiler, Trace}
  alias Nous.Workflow.Engine.Executor
  alias Nous.Workflow.Telemetry, as: WTelemetry

  require Logger

  @max_cycle_iterations 10

  @doc """
  Execute a compiled workflow from its entry node.

  ## Options

  - `:max_iterations` — max cycle iterations per node (default: #{@max_cycle_iterations})
  - `:deps` — dependencies passed to agents/tools
  - `:callbacks` — callback functions for agent steps
  - `:notify_pid` — PID to receive progress notifications
  - `:hooks` — list of `Nous.Hook` structs for workflow lifecycle events
  - `:pause_ref` — `:atomics` ref for on-demand pause signaling

  ## Returns

  - `{:ok, final_state}` — workflow completed successfully
  - `{:suspended, state, checkpoint}` — workflow paused
  - `{:error, reason}` — workflow failed
  """
  @spec execute(Compiler.compiled(), map(), keyword()) ::
          {:ok, State.t()} | {:suspended, State.t(), map()} | {:error, term()}
  def execute(%{graph: graph, topo_order: topo_order} = compiled, initial_data \\ %{}, opts \\ []) do
    state = build_initial_state(initial_data, opts)
    max_iterations = Keyword.get(opts, :max_iterations, @max_cycle_iterations)
    hooks = Keyword.get(opts, :hooks, [])
    pause_ref = Keyword.get(opts, :pause_ref)
    trace_enabled = Keyword.get(opts, :trace, false)
    on_node_complete = Keyword.get(opts, :on_node_complete)
    scratch_enabled = Keyword.get(opts, :scratch, false)

    trace = if trace_enabled, do: Trace.new(), else: nil
    scratch = if scratch_enabled, do: Nous.Workflow.Scratch.new(), else: nil

    run_ctx = %{
      graph: graph,
      compiled: compiled,
      max_iterations: max_iterations,
      visit_counts: %{},
      hooks: hooks,
      pause_ref: pause_ref,
      trace: trace,
      on_node_complete: on_node_complete,
      scratch: scratch
    }

    start_time = System.monotonic_time()
    Logger.info("Starting workflow execution: #{graph.id} (#{Graph.node_count(graph)} nodes)")
    WTelemetry.workflow_start(graph.id, graph.name, Graph.node_count(graph))
    run_hooks(hooks, :workflow_start, %{workflow_id: graph.id, state: state})

    result =
      if graph.allows_cycles do
        execute_edge_following(run_ctx, graph.entry_node, state)
      else
        execute_loop(run_ctx, topo_order, state)
      end

    # Track whether the workflow suspended; suspended workflows MUST keep
    # their scratch table around for resume. Every other terminal outcome
    # (success, error) must release it, otherwise long-running supervisors
    # that retry on failure leak ETS tables until the BEAM OOMs.
    suspended? = match?({:suspended, _, _, _}, result) or match?({:suspended, _, _}, result)

    final_result =
      case result do
        {:ok, final_state, final_ctx} ->
          nodes_executed =
            if final_ctx.trace,
              do: Trace.node_count(final_ctx.trace),
              else: map_size(final_state.node_results)

          WTelemetry.workflow_stop(graph.id, start_time, :completed, nodes_executed)

          run_hooks(hooks, :workflow_end, %{
            workflow_id: graph.id,
            state: final_state,
            status: :completed
          })

          final_state = maybe_attach_trace(final_state, final_ctx.trace)
          {:ok, final_state}

        {:suspended, susp_state, checkpoint, susp_ctx} ->
          WTelemetry.workflow_stop(
            graph.id,
            start_time,
            :suspended,
            map_size(susp_state.node_results)
          )

          run_hooks(hooks, :workflow_end, %{
            workflow_id: graph.id,
            state: susp_state,
            status: :suspended
          })

          susp_state = maybe_attach_trace(susp_state, susp_ctx.trace)
          {:suspended, susp_state, checkpoint}

        {:error, reason, err_ctx} ->
          WTelemetry.workflow_exception(graph.id, start_time, reason)
          # M-11: pass the failure-time state to the :workflow_end hook
          # rather than the initial state. Falls back to initial state if
          # the error was raised before any node ran.
          end_state = Map.get(err_ctx, :failure_state, state)

          run_hooks(hooks, :workflow_end, %{
            workflow_id: graph.id,
            state: end_state,
            status: :failed
          })

          {:error, reason}

        # Legacy returns without ctx (from edge-following)
        {:ok, final_state} ->
          WTelemetry.workflow_stop(
            graph.id,
            start_time,
            :completed,
            map_size(final_state.node_results)
          )

          run_hooks(hooks, :workflow_end, %{
            workflow_id: graph.id,
            state: final_state,
            status: :completed
          })

          {:ok, final_state}

        {:suspended, susp_state, checkpoint} ->
          WTelemetry.workflow_stop(
            graph.id,
            start_time,
            :suspended,
            map_size(susp_state.node_results)
          )

          run_hooks(hooks, :workflow_end, %{
            workflow_id: graph.id,
            state: susp_state,
            status: :suspended
          })

          {:suspended, susp_state, checkpoint}

        {:error, _} = error ->
          WTelemetry.workflow_exception(graph.id, start_time, error)
          run_hooks(hooks, :workflow_end, %{workflow_id: graph.id, state: state, status: :failed})
          error
      end

    unless suspended?, do: maybe_cleanup_scratch(%{scratch: scratch})

    final_result
  end

  # ---------------------------------------------------------------------------
  # Edge-following execution (for graphs with cycles)
  # ---------------------------------------------------------------------------

  defp execute_edge_following(run_ctx, node_id, state) do
    node = Map.fetch!(run_ctx.graph.nodes, node_id)

    # Check visit count for cycle guard
    visit_count = Map.get(run_ctx.visit_counts, node_id, 0)

    if visit_count >= run_ctx.max_iterations do
      Logger.warning("Node #{node_id} hit max iteration limit (#{run_ctx.max_iterations})")
      # Hitting max_iterations is a real failure - quality-gate loops that
      # saturate did NOT pass the gate. Returning {:ok, state} here silently
      # produced "passing" output that hadn't actually passed.
      # The outer execute/3 case will fire the workflow_exception telemetry.
      {:error, {:max_iterations_exceeded, node_id, run_ctx.max_iterations}}
    else
      run_ctx = %{run_ctx | visit_counts: Map.update(run_ctx.visit_counts, node_id, 1, &(&1 + 1))}

      # Check for on-demand pause signal
      if paused?(run_ctx.pause_ref) do
        {:suspended, state, %{node_id: node_id, run_ctx: run_ctx}}
      else
        case run_pre_node_hooks(run_ctx.hooks, node_id, node.type, state) do
          :allow ->
            execute_edge_node(run_ctx, node, state)

          {:pause, reason} ->
            Logger.info("Workflow paused before node #{node_id}: #{inspect(reason)}")
            {:suspended, state, %{node_id: node_id, run_ctx: run_ctx, reason: reason}}

          {:deny, hook_name} ->
            Logger.warning(
              "Workflow node #{node_id} denied by hook #{hook_name}; aborting workflow"
            )

            {:error, {:hook_denied, hook_name, node_id}}

          {:modify, new_state} ->
            execute_edge_node(run_ctx, node, new_state)
        end
      end
    end
  end

  defp execute_edge_node(run_ctx, node, state) do
    Logger.debug("Executing node: #{node.id} (#{node.type})")

    case execute_with_error_strategy(node, state, run_ctx.graph.nodes) do
      {:ok, result, updated_state} ->
        updated_state = run_post_node_hooks(run_ctx.hooks, node.id, result, updated_state)

        # Follow outgoing edges to determine next node
        case resolve_next_node(run_ctx.graph, node, updated_state) do
          nil ->
            Logger.info("Workflow execution complete (reached terminal node #{node.id})")
            {:ok, updated_state}

          next_id ->
            execute_edge_following(run_ctx, next_id, updated_state)
        end

      {:error, {:suspend, checkpoint_node_id}} ->
        Logger.info("Workflow suspended at human checkpoint: #{checkpoint_node_id}")
        {:suspended, state, %{node_id: checkpoint_node_id, run_ctx: run_ctx}}

      {:error, reason} ->
        Logger.error("Workflow failed at node #{node.id}: #{inspect(reason)}")
        {:error, {node.id, reason}}
    end
  end

  defp resolve_next_node(graph, node, state) do
    out_edges = Map.get(graph.out_edges, node.id, [])

    if out_edges == [] do
      nil
    else
      # For branch nodes (and all nodes with conditional edges), evaluate conditions
      chosen =
        Enum.find(out_edges, fn edge ->
          edge.type == :conditional and edge.condition.(state)
        end) ||
          Enum.find(out_edges, fn edge -> edge.type == :default end) ||
          Enum.find(out_edges, fn edge -> edge.type == :sequential end)

      case chosen do
        nil -> nil
        edge -> edge.to_id
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Topo-order execution loop (for DAGs without cycles)
  # ---------------------------------------------------------------------------

  defp execute_loop(run_ctx, [], state) do
    Logger.info("Workflow execution complete")
    {:ok, state, run_ctx}
  end

  defp execute_loop(run_ctx, [node_id | rest], state) do
    node = Map.fetch!(run_ctx.graph.nodes, node_id)

    # Check visit count for cycle guard
    visit_count = Map.get(run_ctx.visit_counts, node_id, 0)

    if visit_count >= run_ctx.max_iterations do
      Logger.warning("Node #{node_id} hit max iteration limit (#{run_ctx.max_iterations})")
      # Same rationale as in execute_edge_following: silent success would let
      # quality-gate loops produce results that did not pass the gate.
      {:error, {:max_iterations_exceeded, node_id, run_ctx.max_iterations}, run_ctx}
    else
      run_ctx = %{run_ctx | visit_counts: Map.update(run_ctx.visit_counts, node_id, 1, &(&1 + 1))}

      # Check for on-demand pause signal
      if paused?(run_ctx.pause_ref) do
        checkpoint = %{node_id: node_id, remaining: [node_id | rest], run_ctx: run_ctx}
        {:suspended, state, checkpoint, run_ctx}
      else
        # Run pre_node hooks
        case run_pre_node_hooks(run_ctx.hooks, node_id, node.type, state) do
          :allow ->
            execute_node(run_ctx, node, rest, state)

          {:pause, reason} ->
            Logger.info("Workflow paused before node #{node_id}: #{inspect(reason)}")

            checkpoint = %{
              node_id: node_id,
              remaining: [node_id | rest],
              run_ctx: run_ctx,
              reason: reason
            }

            {:suspended, state, checkpoint, run_ctx}

          {:deny, hook_name} ->
            Logger.warning(
              "Workflow node #{node_id} denied by hook #{hook_name}; aborting workflow"
            )

            {:error, {:hook_denied, hook_name, node_id}, run_ctx}

          {:modify, new_state} ->
            execute_node(run_ctx, node, rest, new_state)
        end
      end
    end
  end

  defp execute_node(run_ctx, node, rest, state) do
    Logger.debug("Executing node: #{node.id} (#{node.type})")
    node_start_time = System.monotonic_time()
    WTelemetry.node_start(run_ctx.graph.id, node.id, node.type)

    case execute_with_error_strategy(node, state, run_ctx.graph.nodes) do
      {:ok, result, updated_state} ->
        WTelemetry.node_stop(run_ctx.graph.id, node.id, node.type, node_start_time, true)
        duration = System.monotonic_time() - node_start_time

        run_ctx =
          if run_ctx.trace do
            %{
              run_ctx
              | trace: Trace.record(run_ctx.trace, node.id, node.type, duration, :completed)
            }
          else
            run_ctx
          end

        # Run post_node hooks
        updated_state = run_post_node_hooks(run_ctx.hooks, node.id, result, updated_state)

        # Run on_node_complete callback (may mutate graph)
        run_ctx = run_on_node_complete(run_ctx, node, updated_state)

        # Determine next path
        next_nodes =
          case node.type do
            :branch ->
              resolve_branch(run_ctx.graph, node.id, updated_state, rest)

            :parallel ->
              branch_ids = node.config.branches |> Enum.map(&to_string/1) |> MapSet.new()
              Enum.reject(rest, &MapSet.member?(branch_ids, &1))

            _ ->
              rest
          end

        execute_loop(run_ctx, next_nodes, updated_state)

      {:error, {:suspend, checkpoint_node_id}} ->
        WTelemetry.node_stop(run_ctx.graph.id, node.id, node.type, node_start_time, false)
        duration = System.monotonic_time() - node_start_time

        run_ctx =
          if run_ctx.trace do
            %{
              run_ctx
              | trace: Trace.record(run_ctx.trace, node.id, node.type, duration, :suspended)
            }
          else
            run_ctx
          end

        Logger.info("Workflow suspended at human checkpoint: #{checkpoint_node_id}")
        checkpoint = %{node_id: checkpoint_node_id, remaining: [node.id | rest], run_ctx: run_ctx}
        {:suspended, state, checkpoint, run_ctx}

      {:error, reason} ->
        WTelemetry.node_exception(run_ctx.graph.id, node.id, node.type, node_start_time, reason)
        duration = System.monotonic_time() - node_start_time

        run_ctx =
          if run_ctx.trace do
            %{
              run_ctx
              | trace: Trace.record(run_ctx.trace, node.id, node.type, duration, :failed, reason)
            }
          else
            run_ctx
          end

        Logger.error("Workflow failed at node #{node.id}: #{inspect(reason)}")
        # Capture failure-time state on run_ctx so the outer execute/3 case
        # can pass it to the :workflow_end hook payload instead of the
        # initial state (M-11). Operators inspecting why a workflow failed
        # need to see what was in state at the moment of failure, not what
        # was passed in.
        run_ctx = Map.put(run_ctx, :failure_state, state)
        {:error, {node.id, reason}, run_ctx}
    end
  end

  # ---------------------------------------------------------------------------
  # Error strategy handling
  # ---------------------------------------------------------------------------

  defp execute_with_error_strategy(%{error_strategy: :fail_fast} = node, state, graph_nodes) do
    run_executor(node, state, graph_nodes)
  end

  defp execute_with_error_strategy(%{error_strategy: :skip} = node, state, graph_nodes) do
    case run_executor(node, state, graph_nodes) do
      {:ok, result, updated_state} ->
        {:ok, result, updated_state}

      {:error, reason} ->
        Logger.warning("Node #{node.id} failed (skipping): #{inspect(reason)}")
        updated_state = State.put_error(state, node.id, reason)
        {:ok, :skipped, updated_state}
    end
  end

  defp execute_with_error_strategy(
         %{error_strategy: {:retry, max, delay_ms}} = node,
         state,
         graph_nodes
       ) do
    retry_loop(node, state, max, delay_ms, 0, graph_nodes)
  end

  defp execute_with_error_strategy(
         %{error_strategy: {:fallback, fallback_id}} = node,
         state,
         graph_nodes
       ) do
    case run_executor(node, state, graph_nodes) do
      {:ok, result, updated_state} ->
        {:ok, result, updated_state}

      {:error, reason} ->
        # Graph node ids are stringified internally (Graph.add_node), so the
        # atom referenced from error_strategy must be normalized before lookup.
        fallback_key = to_string(fallback_id)

        Logger.warning(
          "Node #{node.id} failed (#{inspect(reason)}), executing fallback: #{fallback_key}"
        )

        case Map.get(graph_nodes, fallback_key) do
          nil ->
            Logger.error(
              "Fallback node #{fallback_key} not found in graph for failed node #{node.id}"
            )

            {:error, {:fallback_not_found, fallback_key, node.id}}

          fallback_node ->
            # Run the fallback node and substitute its result for the failed node's.
            # Record the original failure on state so observability sees both events.
            state_with_err = State.put_error(state, node.id, reason)

            case run_executor(fallback_node, state_with_err, graph_nodes) do
              {:ok, fallback_result, updated_state} ->
                {:ok, fallback_result, updated_state}

              {:error, fallback_reason} ->
                Logger.error(
                  "Fallback node #{fallback_key} also failed: #{inspect(fallback_reason)}"
                )

                {:error, {:fallback_failed, fallback_key, fallback_reason}}
            end
        end
    end
  end

  defp retry_loop(node, state, max, delay_ms, attempt, graph_nodes) do
    case run_executor(node, state, graph_nodes) do
      {:ok, result, updated_state} ->
        {:ok, result, updated_state}

      {:error, reason} when attempt < max ->
        Logger.warning(
          "Node #{node.id} failed (attempt #{attempt + 1}/#{max}): #{inspect(reason)}, retrying in #{delay_ms}ms"
        )

        Process.sleep(delay_ms)
        retry_loop(node, state, max, delay_ms, attempt + 1, graph_nodes)

      {:error, reason} ->
        Logger.error("Node #{node.id} failed after #{max} retries: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_executor(node, state, graph_nodes) do
    Executor.execute(node, state, graph_nodes)
  end

  # ---------------------------------------------------------------------------
  # Branch resolution
  # ---------------------------------------------------------------------------

  defp resolve_branch(graph, node_id, state, remaining_topo) do
    out_edges = Map.get(graph.out_edges, node_id, [])

    # Find the first matching conditional edge, or the default/sequential edge
    chosen_edge =
      Enum.find(out_edges, fn edge -> edge.type == :conditional and edge.condition.(state) end) ||
        Enum.find(out_edges, fn edge -> edge.type == :default end) ||
        Enum.find(out_edges, fn edge -> edge.type == :sequential end)

    case chosen_edge do
      nil ->
        Logger.warning("Branch node #{node_id} has no matching edge, continuing with topo order")
        remaining_topo

      edge ->
        target_id = edge.to_id

        # Compute all nodes reachable from the chosen target
        reachable = bfs_reachable(graph, target_id)
        remaining_set = MapSet.new(remaining_topo)

        if MapSet.member?(remaining_set, target_id) do
          # Target is ahead in topo order — filter to only reachable nodes
          Enum.filter(remaining_topo, &MapSet.member?(reachable, &1))
        else
          # Target is behind (cycle back) — rebuild execution from target forward
          rebuild_from(graph, target_id, reachable)
        end
    end
  end

  defp rebuild_from(graph, target_id, reachable) do
    # For cycle-back, build a new execution sequence from the target
    # using a simple BFS order starting from target, filtered to reachable nodes
    bfs_order(graph, target_id, reachable)
  end

  defp bfs_order(graph, start_id, allowed_set) do
    bfs_order_loop(graph, [start_id], [], MapSet.new([start_id]), allowed_set)
  end

  defp bfs_order_loop(_graph, [], order, _visited, _allowed), do: Enum.reverse(order)

  defp bfs_order_loop(graph, queue, order, visited, allowed) do
    next =
      Enum.flat_map(queue, fn node_id ->
        Graph.successors(graph, node_id)
      end)
      |> Enum.filter(&(MapSet.member?(allowed, &1) and not MapSet.member?(visited, &1)))
      |> Enum.uniq()

    bfs_order_loop(
      graph,
      next,
      Enum.reverse(queue) ++ order,
      MapSet.union(visited, MapSet.new(next)),
      allowed
    )
  end

  defp bfs_reachable(graph, start_id) do
    bfs_loop(graph, [start_id], MapSet.new([start_id]))
  end

  defp bfs_loop(_graph, [], visited), do: visited

  defp bfs_loop(graph, queue, visited) do
    next =
      Enum.flat_map(queue, fn node_id ->
        Graph.successors(graph, node_id)
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    bfs_loop(graph, next, MapSet.union(visited, MapSet.new(next)))
  end

  # ---------------------------------------------------------------------------
  # Hooks
  # ---------------------------------------------------------------------------

  defp run_hooks(hooks, event, payload) do
    hooks
    |> Enum.filter(&(&1.event == event))
    |> Enum.sort_by(& &1.priority)
    |> Enum.each(fn hook ->
      try do
        hook.handler.(event, payload)
      rescue
        e -> Logger.warning("Hook failed for #{event}: #{inspect(e)}")
      end
    end)
  end

  defp run_pre_node_hooks(hooks, node_id, node_type, state) do
    payload = %{node_id: node_id, node_type: node_type, state: state}

    hooks
    |> Enum.filter(&(&1.event == :pre_node))
    |> Enum.sort_by(& &1.priority)
    |> Enum.reduce_while(:allow, fn hook, _acc ->
      try do
        case hook.handler.(:pre_node, payload) do
          :allow -> {:cont, :allow}
          # :deny is a HARD stop, not a pause. Previously :deny was mapped
          # to {:pause, _} so policy-hook denials silently suspended a
          # checkpoint forever instead of failing the workflow.
          :deny -> {:halt, {:deny, hook.name || "unnamed"}}
          {:pause, reason} -> {:halt, {:pause, reason}}
          {:modify, new_state} -> {:halt, {:modify, new_state}}
          _ -> {:cont, :allow}
        end
      rescue
        e ->
          Logger.warning("Pre-node hook failed: #{inspect(e)}")
          {:cont, :allow}
      end
    end)
  end

  defp run_post_node_hooks(hooks, node_id, result, state) do
    payload = %{node_id: node_id, result: result, state: state}

    hooks
    |> Enum.filter(&(&1.event == :post_node))
    |> Enum.sort_by(& &1.priority)
    |> Enum.reduce(state, fn hook, current_state ->
      try do
        case hook.handler.(:post_node, %{payload | state: current_state}) do
          {:modify, new_state} -> new_state
          _ -> current_state
        end
      rescue
        e ->
          Logger.warning("Post-node hook failed: #{inspect(e)}")
          current_state
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Pause support
  # ---------------------------------------------------------------------------

  defp paused?(nil), do: false

  defp paused?(pause_ref) do
    :atomics.get(pause_ref, 1) == 1
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_initial_state(initial_data, opts) when is_map(initial_data) do
    state = State.new(initial_data)

    metadata =
      state.metadata
      |> Map.put(:deps, Keyword.get(opts, :deps, %{}))
      |> Map.put(:callbacks, Keyword.get(opts, :callbacks, %{}))
      |> Map.put(:notify_pid, Keyword.get(opts, :notify_pid))

    %{state | metadata: metadata}
  end

  defp maybe_attach_trace(state, nil), do: state

  defp maybe_attach_trace(state, trace) do
    %{state | metadata: Map.put(state.metadata, :trace, trace)}
  end

  defp maybe_cleanup_scratch(%{scratch: nil}), do: :ok

  defp maybe_cleanup_scratch(%{scratch: scratch}) do
    Nous.Workflow.Scratch.cleanup(scratch)
  end

  defp run_on_node_complete(%{on_node_complete: nil} = run_ctx, _node, _state), do: run_ctx

  defp run_on_node_complete(%{on_node_complete: callback} = run_ctx, node, state) do
    try do
      case callback.(node, state, run_ctx.graph) do
        :continue ->
          run_ctx

        {:modify, new_graph} ->
          Logger.info("Graph modified by on_node_complete after node #{node.id}")
          %{run_ctx | graph: new_graph}
      end
    rescue
      e ->
        Logger.warning("on_node_complete callback failed: #{inspect(e)}")
        run_ctx
    end
  end
end

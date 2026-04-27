defmodule Nous.Workflow.Compiler do
  # See Nous.Workflow.Engine for the same MapSet-capture-opacity rationale.
  # bfs_loop/3 and the reachability/parallel-branch unions exhibit the
  # same false-positive pattern; specs don't fix it (verified).
  @dialyzer :no_opaque

  @moduledoc """
  Validates and compiles workflow graphs for execution.

  Uses Kahn's algorithm for topological sort, which gives three things
  in a single O(V+E) pass:

  1. **Topological order** — valid execution sequence
  2. **Cycle detection** — remaining nodes after sort form cycle(s)
  3. **Parallel levels** — nodes in the same round are independent

  ## Compilation Result

  Returns a `{:ok, compiled}` map with:

  - `:graph` — the validated graph
  - `:topo_order` — topological ordering of node IDs
  - `:levels` — list of lists, each level can execute in parallel
  - `:terminal_nodes` — nodes with no outgoing edges
  - `:fan_in_nodes` — nodes with multiple incoming edges

  ## Examples

      {:ok, compiled} = Nous.Workflow.Compiler.compile(graph)
      compiled.topo_order
      #=> ["plan", "search", "synthesize", "report"]
  """

  alias Nous.Workflow.Graph

  @type compiled :: %{
          graph: Graph.t(),
          topo_order: [Graph.node_id()],
          levels: [[Graph.node_id()]],
          terminal_nodes: [Graph.node_id()],
          fan_in_nodes: [Graph.node_id()],
          cycle_nodes: MapSet.t()
        }

  @doc """
  Compile and validate a workflow graph.

  Returns `{:ok, compiled}` or `{:error, errors}` where errors is a list
  of validation error tuples.
  """
  @spec compile(Graph.t()) :: {:ok, compiled()} | {:error, [term()]}
  def compile(%Graph{} = graph) do
    with :ok <- validate_structure(graph),
         :ok <- validate_nodes(graph),
         result when elem(result, 0) == :ok <- topological_sort(graph) do
      {topo_order, levels, cycle_meta} =
        case result do
          {:ok, order, lvls, meta} -> {order, lvls, meta}
          {:ok, order, lvls} -> {order, lvls, %{cycle_nodes: MapSet.new()}}
        end

      # Remove parallel branch targets and fallback targets from topo order
      # — they're executed by ParallelExecutor / the fallback path, not the
      # main engine loop. Otherwise a fallback-only node with no incoming
      # edges would also run on its own and double-execute.
      excluded =
        graph
        |> collect_parallel_branches()
        |> MapSet.union(collect_fallback_only_targets(graph))

      filtered_order = Enum.reject(topo_order, &MapSet.member?(excluded, &1))

      filtered_levels =
        levels
        |> Enum.map(fn level -> Enum.reject(level, &MapSet.member?(excluded, &1)) end)
        |> Enum.reject(&(&1 == []))

      {:ok,
       %{
         graph: graph,
         topo_order: filtered_order,
         levels: filtered_levels,
         terminal_nodes: Graph.terminal_nodes(graph),
         fan_in_nodes: find_fan_in_nodes(graph),
         cycle_nodes: cycle_meta.cycle_nodes
       }}
    end
  end

  @doc """
  Validate a graph without computing topological sort.
  """
  @spec validate(Graph.t()) :: :ok | {:error, [term()]}
  def validate(%Graph{} = graph) do
    with :ok <- validate_structure(graph),
         :ok <- validate_nodes(graph),
         {:ok, _order, _levels} <- topological_sort(graph) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Structural validation
  # ---------------------------------------------------------------------------

  defp validate_structure(%Graph{} = graph) do
    errors =
      []
      |> check_empty_graph(graph)
      |> check_entry_node(graph)
      |> check_edge_references(graph)
      |> check_reachability(graph)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp check_empty_graph(errors, %Graph{nodes: nodes}) when map_size(nodes) == 0 do
    [{:empty_graph, "graph has no nodes"} | errors]
  end

  defp check_empty_graph(errors, _graph), do: errors

  defp check_entry_node(errors, %Graph{entry_node: nil, nodes: nodes}) when map_size(nodes) > 0 do
    [{:no_entry_node, "graph has nodes but no entry node"} | errors]
  end

  defp check_entry_node(errors, %Graph{entry_node: entry, nodes: nodes})
       when entry != nil and not is_map_key(nodes, entry) do
    [{:invalid_entry_node, "entry node #{inspect(entry)} does not exist"} | errors]
  end

  defp check_entry_node(errors, _graph), do: errors

  defp check_edge_references(errors, %Graph{} = graph) do
    all_edges = all_edges(graph)
    node_ids = Map.keys(graph.nodes) |> MapSet.new()

    Enum.reduce(all_edges, errors, fn edge, acc ->
      cond do
        edge.from_id not in node_ids ->
          [
            {:dangling_edge, "edge references non-existent source node #{inspect(edge.from_id)}"}
            | acc
          ]

        edge.to_id not in node_ids ->
          [
            {:dangling_edge, "edge references non-existent target node #{inspect(edge.to_id)}"}
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp check_reachability(errors, %Graph{entry_node: nil}), do: errors

  defp check_reachability(errors, %Graph{} = graph) do
    # Reachable = entry-node BFS over edges, plus any nodes referenced from
    # error_strategy: {:fallback, id} (which are NOT connected by a regular
    # edge but are still legitimately reachable when their primary fails),
    # plus parallel branch targets.
    reachable =
      graph
      |> bfs_reachable(graph.entry_node)
      |> MapSet.union(collect_fallback_targets(graph))
      |> MapSet.union(collect_parallel_branches(graph))

    all_ids = MapSet.new(Map.keys(graph.nodes))
    unreachable = MapSet.difference(all_ids, reachable)

    if MapSet.size(unreachable) == 0 do
      errors
    else
      ids = MapSet.to_list(unreachable) |> Enum.sort()

      [
        {:unreachable_nodes,
         "nodes #{inspect(ids)} are not reachable from entry node #{inspect(graph.entry_node)}"}
        | errors
      ]
    end
  end

  # Nodes referenced as fallbacks via error_strategy: {:fallback, id}.
  @spec collect_fallback_targets(Graph.t()) :: MapSet.t(Graph.node_id())
  defp collect_fallback_targets(%Graph{} = graph) do
    Enum.reduce(graph.nodes, MapSet.new(), fn
      {_id, %{error_strategy: {:fallback, fallback_id}}}, acc ->
        MapSet.put(acc, to_string(fallback_id))

      _, acc ->
        acc
    end)
  end

  # Fallback targets that have NO regular incoming edges, i.e. nodes that
  # exist solely to be invoked via the fallback path. These are excluded
  # from the topo order so they don't double-execute. (A node that is both
  # a downstream consumer AND a fallback target stays in topo order.)
  @spec collect_fallback_only_targets(Graph.t()) :: MapSet.t(Graph.node_id())
  defp collect_fallback_only_targets(%Graph{} = graph) do
    fallback_ids = collect_fallback_targets(graph)

    fallback_ids
    |> Enum.filter(fn id -> Map.get(graph.in_edges, id, []) == [] end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Node validation
  # ---------------------------------------------------------------------------

  defp validate_nodes(%Graph{} = graph) do
    errors =
      Enum.reduce(graph.nodes, [], fn {id, node}, acc ->
        validate_node_config(id, node, graph) ++ acc
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_node_config(id, %{type: :agent_step, config: config}, _graph) do
    if Map.has_key?(config, :agent) do
      []
    else
      [{:missing_config, "node #{inspect(id)} (:agent_step) requires :agent in config"}]
    end
  end

  defp validate_node_config(id, %{type: :tool_step, config: config}, _graph) do
    if Map.has_key?(config, :tool) do
      []
    else
      [{:missing_config, "node #{inspect(id)} (:tool_step) requires :tool in config"}]
    end
  end

  defp validate_node_config(id, %{type: :transform, config: config}, _graph) do
    if Map.has_key?(config, :transform_fn) and is_function(config.transform_fn, 1) do
      []
    else
      [
        {:missing_config,
         "node #{inspect(id)} (:transform) requires :transform_fn (arity 1) in config"}
      ]
    end
  end

  defp validate_node_config(id, %{type: :parallel, config: config}, graph) do
    errors = []

    errors =
      if Map.has_key?(config, :branches) and is_list(config.branches) do
        # Verify all branch targets exist
        Enum.reduce(config.branches, errors, fn branch_id, acc ->
          branch_str = to_string(branch_id)

          if Map.has_key?(graph.nodes, branch_str) do
            acc
          else
            [
              {:missing_config,
               "node #{inspect(id)} (:parallel) branch #{inspect(branch_id)} does not exist"}
              | acc
            ]
          end
        end)
      else
        [
          {:missing_config, "node #{inspect(id)} (:parallel) requires :branches list in config"}
          | errors
        ]
      end

    errors
  end

  defp validate_node_config(id, %{type: :parallel_map, config: config}, _graph) do
    errors = []

    errors =
      if Map.has_key?(config, :items) and is_function(config.items, 1) do
        errors
      else
        [
          {:missing_config,
           "node #{inspect(id)} (:parallel_map) requires :items (arity 1) in config"}
          | errors
        ]
      end

    errors =
      if Map.has_key?(config, :handler) and is_function(config.handler, 2) do
        errors
      else
        [
          {:missing_config,
           "node #{inspect(id)} (:parallel_map) requires :handler (arity 2) in config"}
          | errors
        ]
      end

    errors
  end

  defp validate_node_config(_id, %{type: type}, _graph)
       when type in [:branch, :human_checkpoint, :subworkflow] do
    []
  end

  # ---------------------------------------------------------------------------
  # Kahn's algorithm — topological sort with parallel levels
  # ---------------------------------------------------------------------------

  @doc """
  Perform topological sort using Kahn's algorithm.

  Returns `{:ok, topo_order, levels}` where `levels` is a list of lists —
  each level contains nodes that can execute in parallel.

  Returns `{:error, [{:cycle_detected, message}]}` if cycles are found
  and the graph does not allow them.
  """
  @spec topological_sort(Graph.t()) ::
          {:ok, [Graph.node_id()], [[Graph.node_id()]]}
          | {:ok, [Graph.node_id()], [[Graph.node_id()]], map()}
          | {:error, [term()]}
  def topological_sort(%Graph{} = graph) do
    # Compute in-degrees
    in_degrees =
      Map.new(graph.nodes, fn {id, _} ->
        {id, graph.in_edges |> Map.get(id, []) |> length()}
      end)

    # Find initial ready set (in-degree == 0)
    initial_ready =
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.sort()

    kahns_loop(graph, in_degrees, initial_ready, [], [])
  end

  defp kahns_loop(graph, in_degrees, [], topo_order, levels) do
    {topo_order, levels} = {Enum.reverse(topo_order), Enum.reverse(levels)}

    # Check for unprocessed nodes — these form cycle(s)
    total = map_size(graph.nodes)
    processed = length(topo_order)

    if processed == total do
      {:ok, topo_order, levels}
    else
      cycle_nodes =
        in_degrees
        |> Enum.filter(fn {_id, deg} -> deg > 0 end)
        |> Enum.map(fn {id, _} -> id end)
        |> Enum.sort()

      if graph.allows_cycles do
        # Include cycle nodes at the end — engine will handle iteration limits
        {:ok, topo_order ++ cycle_nodes, levels ++ [cycle_nodes],
         %{cycle_nodes: MapSet.new(cycle_nodes)}}
      else
        {:error,
         [
           {:cycle_detected,
            "graph contains cycle(s) involving nodes: #{inspect(cycle_nodes)}. " <>
              "Set allows_cycles: true if this is intentional."}
         ]}
      end
    end
  end

  defp kahns_loop(graph, in_degrees, ready, topo_order, levels) do
    # All ready nodes form one parallel level
    level = Enum.sort(ready)

    # Process all ready nodes: decrement successors' in-degrees
    {new_in_degrees, new_ready} =
      Enum.reduce(level, {in_degrees, []}, fn node_id, {degrees, next_ready} ->
        successors =
          graph.out_edges
          |> Map.get(node_id, [])
          |> Enum.map(& &1.to_id)

        Enum.reduce(successors, {degrees, next_ready}, fn succ_id, {deg, nr} ->
          new_deg = Map.update!(deg, succ_id, &(&1 - 1))

          if new_deg[succ_id] == 0 do
            {new_deg, [succ_id | nr]}
          else
            {new_deg, nr}
          end
        end)
      end)

    new_topo = Enum.reverse(level) ++ topo_order

    kahns_loop(graph, new_in_degrees, new_ready, new_topo, [level | levels])
  end

  # ---------------------------------------------------------------------------
  # Graph traversal helpers
  # ---------------------------------------------------------------------------

  @spec bfs_reachable(Graph.t(), Graph.node_id()) :: MapSet.t(Graph.node_id())
  defp bfs_reachable(%Graph{} = graph, start_id) do
    bfs_loop(graph, [start_id], MapSet.new([start_id]))
  end

  @spec bfs_loop(Graph.t(), [Graph.node_id()], MapSet.t(Graph.node_id())) ::
          MapSet.t(Graph.node_id())
  defp bfs_loop(_graph, [], visited), do: visited

  defp bfs_loop(graph, queue, visited) do
    next =
      Enum.flat_map(queue, fn node_id ->
        # Follow edges + parallel branch references from config
        edge_successors = Graph.successors(graph, node_id)
        config_successors = config_references(graph, node_id)
        edge_successors ++ config_successors
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    bfs_loop(graph, next, MapSet.union(visited, MapSet.new(next)))
  end

  # Extract node IDs referenced in config (e.g., :parallel branches)
  defp config_references(graph, node_id) do
    case Map.get(graph.nodes, node_id) do
      %{type: :parallel, config: %{branches: branches}} ->
        Enum.map(branches, &to_string/1)

      _ ->
        []
    end
  end

  defp all_edges(%Graph{out_edges: out_edges}) do
    out_edges
    |> Map.values()
    |> List.flatten()
  end

  @spec collect_parallel_branches(Graph.t()) :: MapSet.t(Graph.node_id())
  defp collect_parallel_branches(%Graph{} = graph) do
    Enum.reduce(graph.nodes, MapSet.new(), fn
      {_id, %{type: :parallel, config: %{branches: branches}}}, acc ->
        MapSet.union(acc, MapSet.new(branches, &to_string/1))

      _, acc ->
        acc
    end)
  end

  defp find_fan_in_nodes(%Graph{} = graph) do
    Enum.filter(Map.keys(graph.nodes), fn id ->
      graph.in_edges |> Map.get(id, []) |> length() > 1
    end)
  end
end

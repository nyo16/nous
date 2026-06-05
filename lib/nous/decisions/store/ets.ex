defmodule Nous.Decisions.Store.ETS do
  @moduledoc """
  ETS-backed decision graph store.

  Uses two unnamed ETS tables (one for nodes, one for edges) so multiple
  instances can coexist. Graph queries use in-memory BFS traversal.

  ## Ownership & lifetime

  Like `Nous.KnowledgeBase.Store.ETS`, this store is **intentionally
  run-scoped**: `init/1` hands the table references back in `state`, the caller
  threads them through `ctx` for the session, and the tables are reclaimed when
  the owning process exits. There is no supervised owner and no cross-run
  persistence — that is the design, not a leak. The tables are `:public` so the
  several processes that share a session's `state` (agent loop + tool tasks) can
  all write; access is gated by possession of the table reference, which stays
  inside `ctx`. Reach for a serializing owner process if you need cross-write
  atomicity or a lifetime longer than the session.

  ## Quick Start

      {:ok, state} = Nous.Decisions.Store.ETS.init([])
      node = Nous.Decisions.Node.new(%{type: :goal, label: "Ship v1.0"})
      {:ok, state} = Nous.Decisions.Store.ETS.add_node(state, node)

  """

  @behaviour Nous.Decisions.Store

  alias Nous.Decisions.{Node, Edge}

  @impl true
  @doc """
  Create two ETS tables for nodes and edges.

  ## Options

  None currently supported.
  """
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    nodes = :ets.new(:decision_nodes, [:set, :public])
    edges = :ets.new(:decision_edges, [:set, :public])
    {:ok, %{nodes: nodes, edges: edges}}
  end

  @impl true
  @spec add_node(map(), Node.t()) :: {:ok, map()}
  def add_node(%{nodes: nodes} = state, %Node{} = node) do
    :ets.insert(nodes, {node.id, node})
    {:ok, state}
  end

  @impl true
  @spec update_node(map(), String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def update_node(%{nodes: nodes} = state, id, updates) do
    case get_node(state, id) do
      {:ok, node} ->
        now = DateTime.utc_now()
        updated = struct(node, Map.put(updates, :updated_at, now))
        :ets.insert(nodes, {id, updated})
        {:ok, state}

      error ->
        error
    end
  end

  @impl true
  @spec get_node(map(), String.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def get_node(%{nodes: nodes}, id) do
    case :ets.lookup(nodes, id) do
      [{^id, node}] -> {:ok, node}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  @spec delete_node(map(), String.t()) :: {:ok, map()}
  def delete_node(%{nodes: nodes, edges: edges} = state, id) do
    :ets.delete(nodes, id)

    # Remove edges that reference this node
    edges
    |> all_edges()
    |> Enum.each(fn edge ->
      if edge.from_id == id || edge.to_id == id do
        :ets.delete(edges, edge.id)
      end
    end)

    {:ok, state}
  end

  @impl true
  @spec add_edge(map(), Edge.t()) :: {:ok, map()}
  def add_edge(%{edges: edges} = state, %Edge{} = edge) do
    :ets.insert(edges, {edge.id, edge})
    {:ok, state}
  end

  @impl true
  @spec get_edges(map(), String.t(), :outgoing | :incoming) :: {:ok, [Edge.t()]}
  def get_edges(%{edges: edges}, node_id, direction) do
    results =
      edges
      |> all_edges()
      |> Enum.filter(fn edge ->
        case direction do
          :outgoing -> edge.from_id == node_id
          :incoming -> edge.to_id == node_id
        end
      end)

    {:ok, results}
  end

  @impl true
  @spec query(map(), atom(), keyword()) :: {:ok, [Node.t()]}
  def query(state, :active_goals, _opts) do
    results =
      state.nodes
      |> all_nodes()
      |> Enum.filter(fn node -> node.type == :goal && node.status == :active end)

    {:ok, results}
  end

  def query(state, :recent_decisions, opts) do
    limit = Keyword.get(opts, :limit, 10)

    results =
      state.nodes
      |> all_nodes()
      |> Enum.filter(fn node -> node.type == :decision end)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:ok, results}
  end

  def query(state, :path_between, opts) do
    from_id = Keyword.fetch!(opts, :from_id)
    to_id = Keyword.fetch!(opts, :to_id)
    {:ok, bfs_path(state, from_id, to_id)}
  end

  def query(state, :descendants, opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    {:ok, bfs_reachable(state, node_id, :outgoing)}
  end

  def query(state, :ancestors, opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    {:ok, bfs_reachable(state, node_id, :incoming)}
  end

  def query(_state, _query_type, _opts) do
    {:ok, []}
  end

  # -- Private helpers --

  defp all_nodes(table) do
    :ets.tab2list(table) |> Enum.map(fn {_id, node} -> node end)
  end

  defp all_edges(table) do
    :ets.tab2list(table) |> Enum.map(fn {_id, edge} -> edge end)
  end

  # BFS to find a path between two nodes, returning nodes along the path.
  # Build the edge adjacency index ONCE per traversal (was: a full edge-table
  # scan per visited node, giving O(V*E)).
  defp bfs_path(state, from_id, to_id) do
    case get_node(state, from_id) do
      {:ok, start_node} ->
        adj = build_adjacency(state)
        do_bfs_path(state, adj, [[start_node]], to_id, MapSet.new([from_id]))

      {:error, :not_found} ->
        []
    end
  end

  defp do_bfs_path(_state, _adj, [], _to_id, _visited), do: []

  defp do_bfs_path(state, adj, [current_path | rest], to_id, visited) do
    current_node = hd(current_path)

    if current_node.id == to_id do
      Enum.reverse(current_path)
    else
      edges = edges_for(adj, current_node.id, :outgoing)

      {new_paths, new_visited} =
        Enum.reduce(edges, {[], visited}, fn edge, {paths, vis} ->
          if MapSet.member?(vis, edge.to_id) do
            {paths, vis}
          else
            case get_node(state, edge.to_id) do
              {:ok, next_node} ->
                {[[next_node | current_path] | paths], MapSet.put(vis, edge.to_id)}

              {:error, :not_found} ->
                {paths, vis}
            end
          end
        end)

      do_bfs_path(state, adj, rest ++ Enum.reverse(new_paths), to_id, new_visited)
    end
  end

  # BFS to find all reachable nodes in a given direction.
  defp bfs_reachable(state, start_id, direction) do
    adj = build_adjacency(state)
    do_bfs_reachable(state, adj, [start_id], direction, MapSet.new([start_id]), [])
  end

  defp do_bfs_reachable(_state, _adj, [], _direction, _visited, acc), do: Enum.reverse(acc)

  defp do_bfs_reachable(state, adj, [current_id | rest], direction, visited, acc) do
    edges = edges_for(adj, current_id, direction)

    neighbor_ids =
      Enum.map(edges, fn edge ->
        case direction do
          :outgoing -> edge.to_id
          :incoming -> edge.from_id
        end
      end)

    {new_queue, new_visited, new_acc} =
      Enum.reduce(neighbor_ids, {rest, visited, acc}, fn nid, {q, vis, a} ->
        if MapSet.member?(vis, nid) do
          {q, vis, a}
        else
          case get_node(state, nid) do
            {:ok, node} ->
              {q ++ [nid], MapSet.put(vis, nid), [node | a]}

            {:error, :not_found} ->
              {q, vis, a}
          end
        end
      end)

    do_bfs_reachable(state, adj, new_queue, direction, new_visited, new_acc)
  end

  # Index every edge once into outgoing (by from_id) and incoming (by to_id)
  # adjacency maps so a traversal is O(V+E) instead of O(V*E).
  defp build_adjacency(%{edges: edges}) do
    all = all_edges(edges)

    %{
      outgoing: Enum.group_by(all, & &1.from_id),
      incoming: Enum.group_by(all, & &1.to_id)
    }
  end

  defp edges_for(adjacency, node_id, direction) do
    adjacency |> Map.fetch!(direction) |> Map.get(node_id, [])
  end
end

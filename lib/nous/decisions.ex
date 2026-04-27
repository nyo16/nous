defmodule Nous.Decisions do
  @moduledoc """
  Top-level module for the Nous Decision Graph system.

  Provides a directed graph for tracking agent goals, decisions, options,
  actions, and outcomes. The graph persists the reasoning process and enables
  agents to revisit, supersede, or build on prior decisions.

  ## Quick Start

      # Minimal setup (ETS store)
      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Decisions],
        deps: %{decisions_config: %{store: Nous.Decisions.Store.ETS}}
      )

  ## Architecture

  Three layers, all plain modules and structs (no GenServer):

  - **Data Layer** -- `Node` (struct), `Edge` (struct), `Store` (behaviour + backends)
  - **Query Layer** -- Graph traversal via store `query/3` callbacks
  - **Integration** -- `Plugins.Decisions` (plugin), decision tools, `ContextBuilder`

  ## Store Backends

  | Backend | Graph Queries | Deps |
  |---------|--------------|------|
  | `Store.ETS` | BFS traversal | None |
  | `Store.DuckDB` | DuckPGQ path matching | `duckdbex` |
  """

  alias Nous.Decisions.{Node, Edge}

  # ---------------------------------------------------------------------------
  # Core operations
  # ---------------------------------------------------------------------------

  @doc """
  Add a node to the decision graph.

  ## Examples

      node = Node.new(%{type: :goal, label: "Implement auth"})
      {:ok, state} = Nous.Decisions.add_node(Store.ETS, state, node)

  """
  @spec add_node(module(), term(), Node.t()) :: {:ok, term()} | {:error, term()}
  def add_node(store_mod, state, %Node{} = node) do
    store_mod.add_node(state, node)
  end

  @doc """
  Add an edge connecting two nodes.

  ## Examples

      edge = Edge.new(%{from_id: goal.id, to_id: decision.id, edge_type: :leads_to})
      {:ok, state} = Nous.Decisions.add_edge(Store.ETS, state, edge)

  """
  @spec add_edge(module(), term(), Edge.t()) :: {:ok, term()} | {:error, term()}
  def add_edge(store_mod, state, %Edge{} = edge) do
    store_mod.add_edge(state, edge)
  end

  @doc """
  Update fields on an existing node.

  ## Examples

      {:ok, state} = Nous.Decisions.update_node(Store.ETS, state, node_id, %{status: :completed})

  """
  @spec update_node(module(), term(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def update_node(store_mod, state, id, updates) do
    store_mod.update_node(state, id, updates)
  end

  @doc """
  Fetch a single node by ID.

  ## Examples

      {:ok, node} = Nous.Decisions.get_node(Store.ETS, state, node_id)

  """
  @spec get_node(module(), term(), String.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def get_node(store_mod, state, id) do
    store_mod.get_node(state, id)
  end

  @doc """
  Supersede a node with a new one.

  Marks the old node as `:superseded` and adds a `:supersedes` edge
  from the new node to the old node.

  > #### Best-effort, not atomic {: .warning}
  >
  > This function performs two backend writes (`update_node` then
  > `add_edge`). If `update_node` succeeds but `add_edge` fails (network
  > blip, lock contention, NIF failure), the old node is left marked
  > `:superseded` with no edge connecting the new and old. There is no
  > automatic rollback. The Store behaviour does not currently expose a
  > transaction primitive; once it does, this should be wrapped in one.

  ## Options

    * `rationale` - reason for superseding (stored on the old node)

  ## Examples

      {:ok, state} = Nous.Decisions.supersede(Store.ETS, state, old_id, new_id, "Better approach found")

  """
  @spec supersede(module(), term(), String.t(), String.t(), String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def supersede(store_mod, state, old_id, new_id, rationale \\ nil) do
    updates = %{status: :superseded}
    updates = if rationale, do: Map.put(updates, :rationale, rationale), else: updates

    with {:ok, state} <- store_mod.update_node(state, old_id, updates) do
      edge =
        Edge.new(%{
          from_id: new_id,
          to_id: old_id,
          edge_type: :supersedes,
          metadata: %{rationale: rationale}
        })

      store_mod.add_edge(state, edge)
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Get all active goal nodes.

  ## Examples

      {:ok, goals} = Nous.Decisions.active_goals(Store.ETS, state)

  """
  @spec active_goals(module(), term()) :: {:ok, [Node.t()]}
  def active_goals(store_mod, state) do
    store_mod.query(state, :active_goals, [])
  end

  @doc """
  Get recent decision nodes, sorted by creation time descending.

  ## Options

    * `:limit` - maximum number of decisions (default: 10)

  ## Examples

      {:ok, decisions} = Nous.Decisions.recent_decisions(Store.ETS, state, limit: 5)

  """
  @spec recent_decisions(module(), term(), keyword()) :: {:ok, [Node.t()]}
  def recent_decisions(store_mod, state, opts \\ []) do
    store_mod.query(state, :recent_decisions, opts)
  end

  @doc """
  Find a path between two nodes.

  Returns the nodes along the shortest path, or an empty list if
  no path exists.

  ## Examples

      {:ok, path} = Nous.Decisions.path_between(Store.ETS, state, from_id, to_id)

  """
  @spec path_between(module(), term(), String.t(), String.t()) :: {:ok, [Node.t()]}
  def path_between(store_mod, state, from_id, to_id) do
    store_mod.query(state, :path_between, from_id: from_id, to_id: to_id)
  end

  @doc """
  Get all descendant nodes reachable from a given node.

  ## Examples

      {:ok, descendants} = Nous.Decisions.descendants(Store.ETS, state, node_id)

  """
  @spec descendants(module(), term(), String.t()) :: {:ok, [Node.t()]}
  def descendants(store_mod, state, node_id) do
    store_mod.query(state, :descendants, node_id: node_id)
  end

  @doc """
  Get all ancestor nodes that can reach a given node.

  ## Examples

      {:ok, ancestors} = Nous.Decisions.ancestors(Store.ETS, state, node_id)

  """
  @spec ancestors(module(), term(), String.t()) :: {:ok, [Node.t()]}
  def ancestors(store_mod, state, node_id) do
    store_mod.query(state, :ancestors, node_id: node_id)
  end

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  @doc """
  Validate a decisions configuration map.

  Returns `{:ok, config}` with defaults applied, or `{:error, reason}`.

  ## Required Keys

    * `:store` - Store backend module (e.g., `Nous.Decisions.Store.ETS`)

  ## Optional Keys

    * `:store_opts` - Options passed to `store.init/1` (default: `[]`)
    * `:decision_limit` - Max recent decisions in context (default: 5)
    * `:auto_inject` - Inject decision context into system prompt (default: true)
    * `:inject_strategy` - `:first_only` (default) or `:every_iteration`

  ## Examples

      {:ok, config} = Nous.Decisions.validate_config(%{store: Nous.Decisions.Store.ETS})
      {:error, reason} = Nous.Decisions.validate_config(%{})

  """
  @spec validate_config(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_config(config) when is_map(config) do
    cond do
      !config[:store] ->
        {:error, ":store is required in decisions_config"}

      true ->
        {:ok,
         config
         |> Map.put_new(:auto_inject, true)
         |> Map.put_new(:inject_strategy, :first_only)
         |> Map.put_new(:decision_limit, 5)}
    end
  end
end

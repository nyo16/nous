defmodule Nous.Decisions.Store do
  @moduledoc """
  Storage behaviour for decision graph backends.

  Defines the interface that all decision graph storage backends must implement.
  Backends manage nodes and edges that form a directed graph of agent decisions.

  ## Architecture

  The store is stateless from the module's perspective -- all state is passed
  through as an opaque `state` term returned by `init/1` and threaded through
  subsequent calls. This allows multiple independent graphs to coexist.

  ## Backends

  | Backend | Graph Queries | Deps |
  |---------|--------------|------|
  | `Store.ETS` | BFS traversal | None |
  | `Store.DuckDB` | DuckPGQ path matching | `duckdbex` |

  ## Query Types

  All backends must support these query types via `query/3`:

  - `:active_goals` -- nodes where type == :goal and status == :active
  - `:recent_decisions` -- decision nodes sorted by created_at desc (accepts `:limit`)
  - `:path_between` -- path from one node to another (accepts `:from_id`, `:to_id`)
  - `:descendants` -- all reachable nodes from a given node (accepts `:node_id`)
  - `:ancestors` -- all nodes that can reach a given node (accepts `:node_id`)
  """

  alias Nous.Decisions.{Node, Edge}

  @doc """
  Initialize the store, returning opaque state.

  ## Options

  Backend-specific. See individual backend modules for details.

  ## Returns

  - `{:ok, state}` on success
  - `{:error, reason}` on failure
  """
  @callback init(opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Add a node to the graph.

  ## Returns

  - `{:ok, state}` on success (state may be updated)
  - `{:error, reason}` if the node cannot be added (e.g., duplicate ID)
  """
  @callback add_node(state :: term(), node :: Node.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Update fields on an existing node.

  The `updates` map contains only the fields to change. The implementation
  must also set `updated_at` to the current time.

  ## Returns

  - `{:ok, state}` on success
  - `{:error, :not_found}` if the node does not exist
  """
  @callback update_node(state :: term(), id :: String.t(), updates :: map()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Fetch a single node by ID.

  ## Returns

  - `{:ok, node}` if found
  - `{:error, :not_found}` if no node with that ID exists
  """
  @callback get_node(state :: term(), id :: String.t()) :: {:ok, Node.t()} | {:error, :not_found}

  @doc """
  Delete a node by ID.

  Implementations should also remove edges that reference the deleted node.

  ## Returns

  - `{:ok, state}` on success
  - `{:error, reason}` on failure
  """
  @callback delete_node(state :: term(), id :: String.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Add an edge connecting two nodes.

  ## Returns

  - `{:ok, state}` on success
  - `{:error, reason}` on failure
  """
  @callback add_edge(state :: term(), edge :: Edge.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Get edges connected to a node.

  ## Direction

  - `:outgoing` -- edges where `from_id` matches the given node ID
  - `:incoming` -- edges where `to_id` matches the given node ID

  ## Returns

  - `{:ok, edges}` -- always succeeds, returning an empty list if none found
  """
  @callback get_edges(state :: term(), node_id :: String.t(), direction :: :outgoing | :incoming) ::
              {:ok, [Edge.t()]}

  @doc """
  Run a named query against the graph.

  ## Query Types

  - `:active_goals` -- returns active goal nodes. Options: none.
  - `:recent_decisions` -- returns decision nodes sorted by recency. Options: `:limit`.
  - `:path_between` -- returns nodes on a path between two nodes. Options: `:from_id`, `:to_id`.
  - `:descendants` -- returns all nodes reachable from a node. Options: `:node_id`.
  - `:ancestors` -- returns all nodes that can reach a node. Options: `:node_id`.

  ## Returns

  - `{:ok, nodes}` -- always succeeds, returning an empty list if no results
  """
  @callback query(state :: term(), query_type :: atom(), opts :: keyword()) ::
              {:ok, [Node.t()]}
end

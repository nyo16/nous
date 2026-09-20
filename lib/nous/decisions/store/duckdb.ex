if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Decisions.Store.DuckDB do
    @moduledoc """
    DuckDB-backed decision graph store.

    Nodes and edges live in two DuckDB tables; path, ancestor and descendant
    queries are recursive CTEs over the edge table (plain SQL — no DuckPGQ or
    other extension to install, so the store works on a stock `duckdbex`).
    Traversals are bounded (10 hops for a path, 100 for ancestors/descendants)
    and cycle-safe via a visited-path check.

    ## Options

      * `:path` - database file path (default: `":memory:"`)

    ## Quick Start

        {:ok, state} = Nous.Decisions.Store.DuckDB.init([])
        node = Nous.Decisions.Node.new(%{type: :goal, label: "Ship v1.0"})
        {:ok, state} = Nous.Decisions.Store.DuckDB.add_node(state, node)

    """

    @behaviour Nous.Decisions.Store

    alias Nous.Decisions.{Node, Edge}

    @create_nodes """
    CREATE TABLE IF NOT EXISTS decision_nodes (
      id VARCHAR PRIMARY KEY,
      node_type VARCHAR NOT NULL,
      label VARCHAR NOT NULL,
      status VARCHAR NOT NULL DEFAULT 'active',
      confidence DOUBLE,
      rationale VARCHAR,
      metadata_json VARCHAR DEFAULT '{}',
      created_at VARCHAR NOT NULL,
      updated_at VARCHAR NOT NULL
    )
    """

    @create_edges """
    CREATE TABLE IF NOT EXISTS decision_edges (
      id VARCHAR PRIMARY KEY,
      from_id VARCHAR NOT NULL,
      to_id VARCHAR NOT NULL,
      edge_type VARCHAR NOT NULL,
      metadata_json VARCHAR DEFAULT '{}',
      created_at VARCHAR NOT NULL
    )
    """

    @impl true
    @spec init(keyword()) :: {:ok, map()} | {:error, term()}
    def init(opts) do
      path = Keyword.get(opts, :path, ":memory:")

      with {:ok, db} <- Duckdbex.open(path),
           {:ok, conn} <- Duckdbex.connection(db),
           {:ok, _} <- Duckdbex.query(conn, @create_nodes),
           {:ok, _} <- Duckdbex.query(conn, @create_edges) do
        {:ok, %{db: db, conn: conn}}
      end
    end

    @impl true
    @spec add_node(map(), Node.t()) :: {:ok, map()} | {:error, term()}
    def add_node(%{conn: conn} = state, %Node{} = node) do
      sql = """
      INSERT INTO decision_nodes (id, node_type, label, status, confidence, rationale, metadata_json, created_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """

      params = [
        node.id,
        to_string(node.type),
        node.label,
        to_string(node.status),
        node.confidence,
        node.rationale,
        JSON.encode!(node.metadata || %{}),
        datetime_to_iso(node.created_at),
        datetime_to_iso(node.updated_at)
      ]

      case Duckdbex.query(conn, sql, params) do
        {:ok, _} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    @spec update_node(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
    def update_node(%{conn: conn} = state, id, updates) when is_map(updates) do
      case get_node(state, id) do
        {:ok, node} ->
          now = DateTime.utc_now()
          updates = Map.put(updates, :updated_at, now)
          updated = struct(node, updates)

          {set_clauses, params} =
            updates
            |> Enum.with_index(1)
            |> Enum.map(fn {{key, _val}, idx} ->
              col = field_to_column(key)
              value = encode_field(key, Map.get(updated, key))
              {"#{col} = $#{idx}", value}
            end)
            |> Enum.unzip()

          sql =
            "UPDATE decision_nodes SET #{Enum.join(set_clauses, ", ")} WHERE id = $#{length(params) + 1}"

          params = params ++ [id]

          case Duckdbex.query(conn, sql, params) do
            {:ok, _} -> {:ok, state}
            {:error, reason} -> {:error, reason}
          end

        error ->
          error
      end
    end

    @impl true
    @spec get_node(map(), String.t()) :: {:ok, Node.t()} | {:error, :not_found}
    def get_node(%{conn: conn}, id) do
      sql = "SELECT * FROM decision_nodes WHERE id = $1"

      with {:ok, result} <- Duckdbex.query(conn, sql, [id]) do
        case Duckdbex.fetch_all(result) do
          [row] ->
            columns = Duckdbex.columns(result)
            {:ok, row_to_node(columns, row)}

          [] ->
            {:error, :not_found}
        end
      end
    end

    @impl true
    @spec delete_node(map(), String.t()) :: {:ok, map()} | {:error, term()}
    def delete_node(%{conn: conn} = state, id) do
      # Delete edges first, then the node
      with {:ok, _} <-
             Duckdbex.query(conn, "DELETE FROM decision_edges WHERE from_id = $1 OR to_id = $1", [
               id
             ]),
           {:ok, _} <- Duckdbex.query(conn, "DELETE FROM decision_nodes WHERE id = $1", [id]) do
        {:ok, state}
      end
    end

    @impl true
    @spec add_edge(map(), Edge.t()) :: {:ok, map()} | {:error, term()}
    def add_edge(%{conn: conn} = state, %Edge{} = edge) do
      sql = """
      INSERT INTO decision_edges (id, from_id, to_id, edge_type, metadata_json, created_at)
      VALUES ($1, $2, $3, $4, $5, $6)
      """

      params = [
        edge.id,
        edge.from_id,
        edge.to_id,
        to_string(edge.edge_type),
        JSON.encode!(edge.metadata || %{}),
        datetime_to_iso(edge.created_at)
      ]

      case Duckdbex.query(conn, sql, params) do
        {:ok, _} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    @spec get_edges(map(), String.t(), :outgoing | :incoming) :: {:ok, [Edge.t()]}
    def get_edges(%{conn: conn}, node_id, direction) do
      {sql, params} =
        case direction do
          :outgoing ->
            {"SELECT * FROM decision_edges WHERE from_id = $1", [node_id]}

          :incoming ->
            {"SELECT * FROM decision_edges WHERE to_id = $1", [node_id]}
        end

      case Duckdbex.query(conn, sql, params) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)
          {:ok, Enum.map(rows, &row_to_edge(columns, &1))}

        {:error, _reason} ->
          {:ok, []}
      end
    end

    # Traversal bounds. The recursive CTEs carry the visited-vertex list so a
    # cycle cannot extend a walk twice through the same node.
    @max_path_hops 10
    @max_traversal_hops 100

    @impl true
    @spec query(map(), atom(), keyword()) :: {:ok, [Node.t()]}
    def query(%{conn: conn}, :active_goals, _opts) do
      sql = "SELECT * FROM decision_nodes WHERE node_type = 'goal' AND status = 'active'"

      case Duckdbex.query(conn, sql) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)
          {:ok, Enum.map(rows, &row_to_node(columns, &1))}

        {:error, _} ->
          {:ok, []}
      end
    end

    def query(%{conn: conn}, :recent_decisions, opts) do
      limit = Keyword.get(opts, :limit, 10)

      sql =
        "SELECT * FROM decision_nodes WHERE node_type = 'decision' ORDER BY created_at DESC LIMIT $1"

      case Duckdbex.query(conn, sql, [limit]) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)
          {:ok, Enum.map(rows, &row_to_node(columns, &1))}

        {:error, _} ->
          {:ok, []}
      end
    end

    # Shortest path (by hop count) from $1 to $2, at most @max_path_hops hops.
    # `$1::VARCHAR` is required: DuckDB cannot infer a bare parameter's type in
    # a recursive anchor and refuses the statement.

    def query(%{conn: conn} = state, :path_between, opts) do
      from_id = Keyword.fetch!(opts, :from_id)
      to_id = Keyword.fetch!(opts, :to_id)

      sql = """
      WITH RECURSIVE walk(node_id, path, hops) AS (
        SELECT $1::VARCHAR, [$1::VARCHAR], 0
        UNION ALL
        SELECT e.to_id, list_append(w.path, e.to_id), w.hops + 1
        FROM walk w JOIN decision_edges e ON e.from_id = w.node_id
        WHERE w.hops < #{@max_path_hops}
          AND NOT list_contains(w.path, e.to_id)
      )
      SELECT path FROM walk WHERE node_id = $2 AND hops > 0
      ORDER BY hops LIMIT 1
      """

      case Duckdbex.query(conn, sql, [from_id, to_id]) do
        {:ok, result} ->
          case Duckdbex.fetch_all(result) do
            [[vertex_ids]] -> {:ok, fetch_nodes_by_ids(state, vertex_ids)}
            [] -> {:ok, []}
          end

        {:error, _} ->
          {:ok, []}
      end
    end

    def query(state, :descendants, opts) do
      reachable(state, Keyword.fetch!(opts, :node_id), :outgoing)
    end

    def query(state, :ancestors, opts) do
      reachable(state, Keyword.fetch!(opts, :node_id), :incoming)
    end

    def query(_state, _query_type, _opts) do
      {:ok, []}
    end

    # Every node reachable from $1 by following edges in `direction`, up to
    # @max_traversal_hops away. The path list is the cycle guard; distinct
    # ids are collapsed in SQL so the per-id hydration below runs once each.
    defp reachable(%{conn: conn} = state, node_id, direction) do
      {follow, next} =
        case direction do
          :outgoing -> {"e.from_id", "e.to_id"}
          :incoming -> {"e.to_id", "e.from_id"}
        end

      sql = """
      WITH RECURSIVE walk(node_id, path, hops) AS (
        SELECT $1::VARCHAR, [$1::VARCHAR], 0
        UNION ALL
        SELECT #{next}, list_append(w.path, #{next}), w.hops + 1
        FROM walk w JOIN decision_edges e ON #{follow} = w.node_id
        WHERE w.hops < #{@max_traversal_hops}
          AND NOT list_contains(w.path, #{next})
      )
      SELECT DISTINCT node_id FROM walk WHERE hops > 0 AND node_id <> $1
      """

      case Duckdbex.query(conn, sql, [node_id]) do
        {:ok, result} ->
          ids = result |> Duckdbex.fetch_all() |> Enum.map(fn [id] -> id end)
          {:ok, fetch_nodes_by_ids(state, ids)}

        {:error, _} ->
          {:ok, []}
      end
    end

    # -- Private helpers --

    defp fetch_nodes_by_ids(%{conn: conn}, ids) when is_list(ids) do
      Enum.flat_map(ids, fn id ->
        sql = "SELECT * FROM decision_nodes WHERE id = $1"

        case Duckdbex.query(conn, sql, [id]) do
          {:ok, result} ->
            columns = Duckdbex.columns(result)

            Duckdbex.fetch_all(result)
            |> Enum.map(&row_to_node(columns, &1))

          {:error, _} ->
            []
        end
      end)
    end

    defp row_to_node(columns, row) do
      map = columns |> Enum.zip(row) |> Map.new()

      %Node{
        id: map["id"],
        type: node_type(map["node_type"]),
        label: map["label"],
        status: node_status(map["status"]),
        confidence: map["confidence"],
        rationale: map["rationale"],
        metadata: decode_json(map["metadata_json"]),
        created_at: parse_datetime(map["created_at"]),
        updated_at: parse_datetime(map["updated_at"])
      }
    end

    defp row_to_edge(columns, row) do
      map = columns |> Enum.zip(row) |> Map.new()

      %Edge{
        id: map["id"],
        from_id: map["from_id"],
        to_id: map["to_id"],
        edge_type: edge_type(map["edge_type"]),
        metadata: decode_json(map["metadata_json"]),
        created_at: parse_datetime(map["created_at"])
      }
    end

    # Stored rows are not trusted input: decode each enum column through the
    # literal set its struct declares (`Nous.Decisions.Node.node_type/0`,
    # `status/0`, `Nous.Decisions.Edge.edge_type/0`), never
    # `String.to_existing_atom/1`. Unknown values fall back to the least
    # consequential member — `:observation` / `:rejected` / `:leads_to` — so
    # a corrupted row can neither crash the read nor become a live decision.
    defp node_type("goal"), do: :goal
    defp node_type("decision"), do: :decision
    defp node_type("option"), do: :option
    defp node_type("action"), do: :action
    defp node_type("outcome"), do: :outcome
    defp node_type("observation"), do: :observation
    defp node_type("revisit"), do: :revisit
    defp node_type(_other), do: :observation

    defp node_status("active"), do: :active
    defp node_status("completed"), do: :completed
    defp node_status("superseded"), do: :superseded
    defp node_status("rejected"), do: :rejected
    defp node_status(_other), do: :rejected

    defp edge_type("leads_to"), do: :leads_to
    defp edge_type("chosen"), do: :chosen
    defp edge_type("rejected"), do: :rejected
    defp edge_type("requires"), do: :requires
    defp edge_type("blocks"), do: :blocks
    defp edge_type("enables"), do: :enables
    defp edge_type("supersedes"), do: :supersedes
    defp edge_type(_other), do: :leads_to

    defp field_to_column(:type), do: "node_type"
    defp field_to_column(:metadata), do: "metadata_json"
    defp field_to_column(field), do: to_string(field)

    defp encode_field(:metadata, val), do: JSON.encode!(val || %{})
    defp encode_field(:type, val), do: to_string(val)
    defp encode_field(:status, val), do: to_string(val)

    defp encode_field(key, val)
         when key in [:created_at, :updated_at],
         do: datetime_to_iso(val)

    defp encode_field(_key, val), do: val

    defp decode_json(nil), do: %{}
    defp decode_json(str) when is_binary(str), do: decode_json_atoms(str)

    # Decision metadata is user-supplied; never crash on unknown keys.
    defp decode_json_atoms(str) when is_binary(str),
      do: str |> JSON.decode!() |> Nous.Util.atomize_keys()

    defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp datetime_to_iso(nil), do: DateTime.to_iso8601(DateTime.utc_now())

    defp parse_datetime(nil), do: nil

    defp parse_datetime(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _} -> dt
        _ -> nil
      end
    end
  end
else
  defmodule Nous.Decisions.Store.DuckDB do
    @moduledoc """
    DuckDB-backed decision graph store (stub).

    Add `{:duckdbex, "~> 0.5"}` to your dependencies to enable this store.
    """

    @behaviour Nous.Decisions.Store

    @dialyzer {:nowarn_function,
               init: 1,
               add_node: 2,
               update_node: 3,
               get_node: 2,
               delete_node: 2,
               add_edge: 2,
               get_edges: 3,
               query: 3}

    @error {:error,
            "Duckdbex is not available. Add {:duckdbex, \"~> 0.5\"} to your dependencies."}

    @impl true
    def init(_opts), do: @error

    @impl true
    def add_node(_state, _node), do: @error

    @impl true
    def update_node(_state, _id, _updates), do: @error

    @impl true
    def get_node(_state, _id), do: @error

    @impl true
    def delete_node(_state, _id), do: @error

    @impl true
    def add_edge(_state, _edge), do: @error

    @impl true
    def get_edges(_state, _node_id, _direction), do: @error

    @impl true
    def query(_state, _query_type, _opts), do: @error
  end
end

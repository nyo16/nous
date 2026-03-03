if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Decisions.Store.DuckDB do
    @moduledoc """
    DuckDB-backed decision graph store using DuckPGQ for graph queries.

    Uses DuckDB tables for nodes and edges, with a DuckPGQ property graph
    overlay for efficient path traversal, ancestor, and descendant queries.

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

    @create_graph """
    CREATE OR REPLACE PROPERTY GRAPH decisions
      VERTEX TABLES (decision_nodes)
      EDGE TABLES (
        decision_edges SOURCE KEY (from_id) REFERENCES decision_nodes (id)
                       DESTINATION KEY (to_id) REFERENCES decision_nodes (id)
      )
    """

    @impl true
    @spec init(keyword()) :: {:ok, map()} | {:error, term()}
    def init(opts) do
      path = Keyword.get(opts, :path, ":memory:")

      with {:ok, db} <- Duckdbex.open(path),
           {:ok, conn} <- Duckdbex.connection(db),
           {:ok, _} <- Duckdbex.query(conn, @create_nodes),
           {:ok, _} <- Duckdbex.query(conn, @create_edges),
           {:ok, _} <- Duckdbex.query(conn, @create_graph) do
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
        Jason.encode!(node.metadata || %{}),
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
        Jason.encode!(edge.metadata || %{}),
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

    def query(%{conn: conn} = state, :path_between, opts) do
      from_id = Keyword.fetch!(opts, :from_id)
      to_id = Keyword.fetch!(opts, :to_id)

      sql = """
      FROM GRAPH_TABLE (decisions
        MATCH p = (a:decision_nodes WHERE a.id = $1)-[e:decision_edges]->{1,10}(b:decision_nodes WHERE b.id = $2)
        COLUMNS (a.id AS src_id, b.id AS dst_id, path_length(p) AS path_len,
                 vertices(p) AS path_vertices)
      )
      ORDER BY path_len
      LIMIT 1
      """

      case Duckdbex.query(conn, sql, [from_id, to_id]) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)

          case rows do
            [row] ->
              vertex_idx = Enum.find_index(columns, &(&1 == "path_vertices"))
              vertex_ids = Enum.at(row, vertex_idx) || []
              nodes = fetch_nodes_by_ids(state, vertex_ids)
              {:ok, nodes}

            [] ->
              {:ok, []}
          end

        {:error, _} ->
          {:ok, []}
      end
    end

    def query(%{conn: conn} = state, :descendants, opts) do
      node_id = Keyword.fetch!(opts, :node_id)

      sql = """
      FROM GRAPH_TABLE (decisions
        MATCH (a:decision_nodes WHERE a.id = $1)-[e:decision_edges]->{1,100}(b:decision_nodes)
        COLUMNS (b.id AS descendant_id)
      )
      """

      case Duckdbex.query(conn, sql, [node_id]) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)
          id_idx = Enum.find_index(columns, &(&1 == "descendant_id"))

          ids =
            rows
            |> Enum.map(&Enum.at(&1, id_idx))
            |> Enum.uniq()

          {:ok, fetch_nodes_by_ids(state, ids)}

        {:error, _} ->
          {:ok, []}
      end
    end

    def query(%{conn: conn} = state, :ancestors, opts) do
      node_id = Keyword.fetch!(opts, :node_id)

      sql = """
      FROM GRAPH_TABLE (decisions
        MATCH (a:decision_nodes)-[e:decision_edges]->{1,100}(b:decision_nodes WHERE b.id = $1)
        COLUMNS (a.id AS ancestor_id)
      )
      """

      case Duckdbex.query(conn, sql, [node_id]) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)
          id_idx = Enum.find_index(columns, &(&1 == "ancestor_id"))

          ids =
            rows
            |> Enum.map(&Enum.at(&1, id_idx))
            |> Enum.uniq()

          {:ok, fetch_nodes_by_ids(state, ids)}

        {:error, _} ->
          {:ok, []}
      end
    end

    def query(_state, _query_type, _opts) do
      {:ok, []}
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
        type: String.to_existing_atom(map["node_type"]),
        label: map["label"],
        status: String.to_existing_atom(map["status"]),
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
        edge_type: String.to_existing_atom(map["edge_type"]),
        metadata: decode_json(map["metadata_json"]),
        created_at: parse_datetime(map["created_at"])
      }
    end

    defp field_to_column(:type), do: "node_type"
    defp field_to_column(:metadata), do: "metadata_json"
    defp field_to_column(field), do: to_string(field)

    defp encode_field(:metadata, val), do: Jason.encode!(val || %{})
    defp encode_field(:type, val), do: to_string(val)
    defp encode_field(:status, val), do: to_string(val)

    defp encode_field(key, val)
         when key in [:created_at, :updated_at],
         do: datetime_to_iso(val)

    defp encode_field(_key, val), do: val

    defp decode_json(nil), do: %{}
    defp decode_json(str) when is_binary(str), do: Jason.decode!(str, keys: :atoms)

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

    Add `{:duckdbex, "~> 0.3"}` to your dependencies to enable this store.
    """

    @behaviour Nous.Decisions.Store

    @error {:error,
            "Duckdbex is not available. Add {:duckdbex, \"~> 0.3\"} to your dependencies."}

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

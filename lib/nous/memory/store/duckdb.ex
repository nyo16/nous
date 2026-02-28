if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Memory.Store.DuckDB do
    @moduledoc """
    DuckDB-backed memory store using Duckdbex.

    Uses native DuckDB array columns for embeddings and `list_cosine_similarity`
    for vector search. Text search uses ILIKE as a fallback.

    ## Options

      * `:path` - database file path (default: `":memory:"`)
    """

    @behaviour Nous.Memory.Store

    alias Nous.Memory.Entry

    @create_memories """
    CREATE TABLE IF NOT EXISTS memories (
      id VARCHAR PRIMARY KEY,
      content VARCHAR NOT NULL,
      type VARCHAR NOT NULL DEFAULT 'semantic',
      importance DOUBLE NOT NULL DEFAULT 0.5,
      evergreen BOOLEAN NOT NULL DEFAULT false,
      embedding DOUBLE[],
      agent_id VARCHAR,
      session_id VARCHAR,
      user_id VARCHAR,
      namespace VARCHAR,
      metadata_json VARCHAR DEFAULT '{}',
      access_count INTEGER NOT NULL DEFAULT 0,
      created_at VARCHAR NOT NULL,
      updated_at VARCHAR NOT NULL,
      last_accessed_at VARCHAR NOT NULL
    )
    """

    @impl true
    def init(opts) do
      path = Keyword.get(opts, :path, ":memory:")

      with {:ok, db} <- Duckdbex.open(path),
           {:ok, conn} <- Duckdbex.connection(db),
           {:ok, _} <- Duckdbex.query(conn, @create_memories) do
        # Try to load FTS extension but don't fail if unavailable
        _ = Duckdbex.query(conn, "INSTALL fts")
        _ = Duckdbex.query(conn, "LOAD fts")

        {:ok, %{db: db, conn: conn}}
      end
    end

    @impl true
    def store(%{conn: conn} = state, %Entry{} = entry) do
      sql = """
      INSERT INTO memories (id, content, type, importance, evergreen, embedding,
        agent_id, session_id, user_id, namespace, metadata_json, access_count,
        created_at, updated_at, last_accessed_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
      """

      params = [
        entry.id,
        entry.content,
        to_string(entry.type),
        entry.importance,
        entry.evergreen,
        entry.embedding,
        entry.agent_id,
        entry.session_id,
        entry.user_id,
        entry.namespace,
        Jason.encode!(entry.metadata || %{}),
        entry.access_count,
        datetime_to_iso(entry.created_at),
        datetime_to_iso(entry.updated_at),
        datetime_to_iso(entry.last_accessed_at)
      ]

      case Duckdbex.query(conn, sql, params) do
        {:ok, _} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def fetch(%{conn: conn}, id) do
      sql = "SELECT * FROM memories WHERE id = $1"

      with {:ok, result} <- Duckdbex.query(conn, sql, [id]) do
        case Duckdbex.fetch_all(result) do
          [row] ->
            columns = Duckdbex.columns(result)
            {:ok, row_to_entry(columns, row)}

          [] ->
            {:error, :not_found}
        end
      end
    end

    @impl true
    def delete(%{conn: conn} = state, id) do
      sql = "DELETE FROM memories WHERE id = $1"

      case Duckdbex.query(conn, sql, [id]) do
        {:ok, _} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def update(%{conn: conn} = state, id, updates) when is_map(updates) do
      case fetch(state, id) do
        {:ok, entry} ->
          now = DateTime.utc_now()
          updates = Map.put(updates, :updated_at, now)
          updated = struct(entry, updates)

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
            "UPDATE memories SET #{Enum.join(set_clauses, ", ")} WHERE id = $#{length(params) + 1}"

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
    def search_text(%{conn: conn} = _state, query, opts) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)

      {scope_sql, scope_params, next_idx} = build_scope_clause(scope, 1)

      # Use ILIKE for basic text search
      search_clause = "WHERE content ILIKE '%' || $#{next_idx} || '%'"
      scope_and = if scope_sql == "", do: "", else: " AND " <> scope_sql

      sql = """
      SELECT * FROM memories
      #{search_clause}#{scope_and}
      LIMIT $#{next_idx + 1}
      """

      params = scope_params ++ [query, limit]

      case Duckdbex.query(conn, sql, params) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)

          entries_with_scores =
            rows
            |> Enum.map(fn row ->
              entry = row_to_entry(columns, row)
              # Basic relevance: case-insensitive match score
              score = text_relevance_score(entry.content, query)
              {entry, score}
            end)
            |> Enum.sort_by(fn {_entry, score} -> score end, :desc)

          {:ok, entries_with_scores}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def search_vector(%{conn: conn} = _state, embedding, opts) when is_list(embedding) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)
      min_score = Keyword.get(opts, :min_score, 0.0)

      {scope_sql, scope_params, next_idx} = build_scope_clause(scope, 1)

      embedding_clause = "WHERE embedding IS NOT NULL"
      scope_and = if scope_sql == "", do: "", else: " AND " <> scope_sql

      sql = """
      SELECT *, list_cosine_similarity(embedding, $#{next_idx}::DOUBLE[]) AS score
      FROM memories
      #{embedding_clause}#{scope_and}
      ORDER BY score DESC
      LIMIT $#{next_idx + 1}
      """

      params = scope_params ++ [embedding, limit]

      case Duckdbex.query(conn, sql, params) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)

          entries_with_scores =
            rows
            |> Enum.map(fn row ->
              score_idx = Enum.find_index(columns, &(&1 == "score"))
              score = Enum.at(row, score_idx) || 0.0
              entry = row_to_entry(columns, row)
              {entry, score}
            end)
            |> Enum.filter(fn {_entry, score} -> score >= min_score end)

          {:ok, entries_with_scores}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def list(%{conn: conn} = _state, opts) do
      scope = Keyword.get(opts, :scope, %{})
      {scope_sql, scope_params, _next_idx} = build_scope_clause(scope, 1)

      where = if scope_sql == "", do: "", else: "WHERE " <> scope_sql
      sql = "SELECT * FROM memories #{where}"

      case Duckdbex.query(conn, sql, scope_params) do
        {:ok, result} ->
          columns = Duckdbex.columns(result)
          rows = Duckdbex.fetch_all(result)
          {:ok, Enum.map(rows, &row_to_entry(columns, &1))}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # -- Private helpers --

    defp row_to_entry(columns, row) do
      map =
        columns
        |> Enum.zip(row)
        |> Map.new()

      %Entry{
        id: map["id"],
        content: map["content"],
        type: String.to_existing_atom(map["type"]),
        importance: map["importance"] || 0.5,
        evergreen: to_bool(map["evergreen"]),
        embedding: map["embedding"],
        agent_id: map["agent_id"],
        session_id: map["session_id"],
        user_id: map["user_id"],
        namespace: map["namespace"],
        metadata: decode_json(map["metadata_json"]),
        access_count: map["access_count"] || 0,
        created_at: parse_datetime(map["created_at"]),
        updated_at: parse_datetime(map["updated_at"]),
        last_accessed_at: parse_datetime(map["last_accessed_at"])
      }
    end

    defp build_scope_clause(scope, start_idx) when map_size(scope) == 0,
      do: {"", [], start_idx}

    defp build_scope_clause(scope, start_idx) do
      {clauses, params, next_idx} =
        scope
        |> Enum.reduce({[], [], start_idx}, fn {key, value}, {cls, pms, idx} ->
          col = field_to_column(key)
          {cls ++ ["#{col} = $#{idx}"], pms ++ [value], idx + 1}
        end)

      {Enum.join(clauses, " AND "), params, next_idx}
    end

    defp field_to_column(:metadata), do: "metadata_json"
    defp field_to_column(field), do: to_string(field)

    defp encode_field(:embedding, val), do: val
    defp encode_field(:metadata, val), do: Jason.encode!(val || %{})
    defp encode_field(:evergreen, val), do: val
    defp encode_field(:type, val), do: to_string(val)

    defp encode_field(key, val)
         when key in [:created_at, :updated_at, :last_accessed_at],
         do: datetime_to_iso(val)

    defp encode_field(_key, val), do: val

    defp decode_json(nil), do: %{}
    defp decode_json(str) when is_binary(str), do: Jason.decode!(str, keys: :atoms)

    defp to_bool(true), do: true
    defp to_bool(false), do: false
    defp to_bool(1), do: true
    defp to_bool(0), do: false
    defp to_bool(nil), do: false

    defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp datetime_to_iso(nil), do: DateTime.to_iso8601(DateTime.utc_now())

    defp parse_datetime(nil), do: nil

    defp parse_datetime(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _} -> dt
        _ -> nil
      end
    end

    defp text_relevance_score(content, query) do
      content_lower = String.downcase(content)
      query_lower = String.downcase(query)

      # Count occurrences and normalize by content length
      parts = String.split(content_lower, query_lower)
      count = length(parts) - 1

      if count > 0 do
        # Score based on frequency relative to content length
        min(1.0, count / max(1, String.length(content_lower) / String.length(query_lower) / 10))
      else
        0.0
      end
    end
  end
else
  defmodule Nous.Memory.Store.DuckDB do
    @moduledoc """
    DuckDB-backed memory store (stub).

    Add `{:duckdbex, "~> 0.3"}` to your dependencies to enable this store.
    """

    @behaviour Nous.Memory.Store

    @error {:error,
            "Duckdbex is not available. Add {:duckdbex, \"~> 0.3\"} to your dependencies."}

    @impl true
    def init(_opts), do: @error

    @impl true
    def store(_state, _entry), do: @error

    @impl true
    def fetch(_state, _id), do: @error

    @impl true
    def delete(_state, _id), do: @error

    @impl true
    def update(_state, _id, _updates), do: @error

    @impl true
    def search_text(_state, _query, _opts), do: @error

    @impl true
    def search_vector(_state, _embedding, _opts), do: @error

    @impl true
    def list(_state, _opts), do: @error
  end
end

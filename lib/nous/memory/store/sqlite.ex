if Code.ensure_loaded?(Exqlite) do
  defmodule Nous.Memory.Store.SQLite do
    @moduledoc """
    SQLite-backed memory store using Exqlite.

    Uses FTS5 for full-text search and stores embeddings as JSON-encoded blobs.
    Vector search is implemented via in-Elixir cosine similarity computation.

    ## Options

      * `:path` - database file path (default: `":memory:"`)
    """

    @behaviour Nous.Memory.Store

    alias Nous.Memory.Entry

    @create_memories """
    CREATE TABLE IF NOT EXISTS memories (
      id TEXT PRIMARY KEY,
      content TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'semantic',
      importance REAL NOT NULL DEFAULT 0.5,
      evergreen INTEGER NOT NULL DEFAULT 0,
      embedding BLOB,
      agent_id TEXT,
      session_id TEXT,
      user_id TEXT,
      namespace TEXT,
      metadata_json TEXT DEFAULT '{}',
      access_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      last_accessed_at TEXT NOT NULL
    )
    """

    @create_fts """
    CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
      id UNINDEXED, content, tokenize='porter unicode61'
    )
    """

    @create_idx_agent "CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(agent_id)"
    @create_idx_user "CREATE INDEX IF NOT EXISTS idx_memories_user ON memories(user_id)"
    @create_idx_session "CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id)"

    @impl true
    def init(opts) do
      path = Keyword.get(opts, :path, ":memory:")

      with {:ok, conn} <- Exqlite.Sqlite3.open(path),
           :ok <- Exqlite.Sqlite3.execute(conn, @create_memories),
           :ok <- Exqlite.Sqlite3.execute(conn, @create_fts),
           :ok <- Exqlite.Sqlite3.execute(conn, @create_idx_agent),
           :ok <- Exqlite.Sqlite3.execute(conn, @create_idx_user),
           :ok <- Exqlite.Sqlite3.execute(conn, @create_idx_session) do
        {:ok, conn}
      end
    end

    @impl true
    def store(conn, %Entry{} = entry) do
      sql = """
      INSERT INTO memories (id, content, type, importance, evergreen, embedding,
        agent_id, session_id, user_id, namespace, metadata_json, access_count,
        created_at, updated_at, last_accessed_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
      """

      fts_sql = "INSERT INTO memories_fts (id, content) VALUES (?1, ?2)"

      params = [
        entry.id,
        entry.content,
        to_string(entry.type),
        entry.importance,
        bool_to_int(entry.evergreen),
        encode_embedding(entry.embedding),
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

      with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
           :ok <- bind_and_step(conn, stmt, params),
           {:ok, fts_stmt} <- Exqlite.Sqlite3.prepare(conn, fts_sql),
           :ok <- bind_and_step(conn, fts_stmt, [entry.id, entry.content]) do
        {:ok, conn}
      end
    end

    @impl true
    def fetch(conn, id) do
      sql = "SELECT * FROM memories WHERE id = ?1"

      with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
           :ok <- Exqlite.Sqlite3.bind(conn, stmt, [id]) do
        case Exqlite.Sqlite3.step(conn, stmt) do
          {:row, row} ->
            columns = Exqlite.Sqlite3.columns(conn, stmt)
            Exqlite.Sqlite3.release(conn, stmt)
            {:ok, row_to_entry(columns, row)}

          :done ->
            Exqlite.Sqlite3.release(conn, stmt)
            {:error, :not_found}
        end
      end
    end

    @impl true
    def delete(conn, id) do
      mem_sql = "DELETE FROM memories WHERE id = ?1"
      fts_sql = "DELETE FROM memories_fts WHERE id = ?1"

      with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, mem_sql),
           :ok <- bind_and_step(conn, stmt, [id]),
           {:ok, fts_stmt} <- Exqlite.Sqlite3.prepare(conn, fts_sql),
           :ok <- bind_and_step(conn, fts_stmt, [id]) do
        {:ok, conn}
      end
    end

    @impl true
    def update(conn, id, updates) when is_map(updates) do
      case fetch(conn, id) do
        {:ok, entry} ->
          now = DateTime.utc_now()
          updates = Map.put(updates, :updated_at, now)
          updated = struct(entry, updates)

          set_clauses =
            updates
            |> Map.keys()
            |> Enum.map(&field_to_column/1)
            |> Enum.with_index(1)
            |> Enum.map(fn {col, idx} -> "#{col} = ?#{idx}" end)
            |> Enum.join(", ")

          params =
            updates
            |> Map.keys()
            |> Enum.map(fn key -> encode_field(key, Map.get(updated, key)) end)

          sql = "UPDATE memories SET #{set_clauses} WHERE id = ?#{map_size(updates) + 1}"
          params = params ++ [id]

          with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
               :ok <- bind_and_step(conn, stmt, params) do
            if Map.has_key?(updates, :content) do
              update_fts(conn, id, updated.content)
            end

            {:ok, conn}
          end

        error ->
          error
      end
    end

    @impl true
    def search_text(conn, query, opts) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)

      {scope_sql, scope_params} = build_scope_clause(scope, 1)

      sql = """
      SELECT m.*, bm25(memories_fts) AS rank
      FROM memories_fts f
      JOIN memories m ON m.id = f.id
      WHERE memories_fts MATCH ?#{map_size(scope) + 1}
      #{scope_sql |> String.replace("WHERE", "AND")}
      ORDER BY rank
      LIMIT ?#{map_size(scope) + 2}
      """

      # Escape FTS5 special characters by wrapping each term in double quotes
      escaped_query =
        query
        |> String.split(~r/\s+/, trim: true)
        |> Enum.map(&"\"#{&1}\"")
        |> Enum.join(" ")

      params = scope_params ++ [escaped_query, limit]

      case query_all(conn, sql, params) do
        {:ok, rows, columns} ->
          # bm25 returns negative values (closer to 0 = better match)
          # Normalize to 0..1 range where 1 is best
          entries_with_scores =
            rows
            |> Enum.map(fn row ->
              rank_idx = Enum.find_index(columns, &(&1 == "rank"))
              rank = Enum.at(row, rank_idx)
              entry = row_to_entry(columns, row)
              {entry, normalize_bm25(rank)}
            end)

          {:ok, entries_with_scores}

        error ->
          error
      end
    end

    @impl true
    def search_vector(conn, embedding, opts) when is_list(embedding) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)
      min_score = Keyword.get(opts, :min_score, 0.0)

      {scope_sql, scope_params} = build_scope_clause(scope, 0)

      sql = """
      SELECT * FROM memories
      WHERE embedding IS NOT NULL
      #{scope_sql |> String.replace("WHERE", "AND")}
      """

      case query_all(conn, sql, scope_params) do
        {:ok, rows, columns} ->
          results =
            rows
            |> Enum.map(fn row ->
              entry = row_to_entry(columns, row)
              score = cosine_similarity(embedding, entry.embedding || [])
              {entry, score}
            end)
            |> Enum.filter(fn {_entry, score} -> score >= min_score end)
            |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
            |> Enum.take(limit)

          {:ok, results}

        error ->
          error
      end
    end

    @impl true
    def list(conn, opts) do
      scope = Keyword.get(opts, :scope, %{})
      {scope_sql, scope_params} = build_scope_clause(scope, 0)

      sql = "SELECT * FROM memories #{scope_sql}"

      case query_all(conn, sql, scope_params) do
        {:ok, rows, columns} ->
          {:ok, Enum.map(rows, &row_to_entry(columns, &1))}

        error ->
          error
      end
    end

    # -- Private helpers --

    defp bind_and_step(conn, stmt, params) do
      with :ok <- Exqlite.Sqlite3.bind(conn, stmt, params) do
        case Exqlite.Sqlite3.step(conn, stmt) do
          :done ->
            Exqlite.Sqlite3.release(conn, stmt)
            :ok

          {:row, _} ->
            Exqlite.Sqlite3.release(conn, stmt)
            :ok

          {:error, _} = error ->
            Exqlite.Sqlite3.release(conn, stmt)
            error
        end
      end
    end

    defp query_all(conn, sql, params) do
      with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
           :ok <- Exqlite.Sqlite3.bind(conn, stmt, params) do
        columns = Exqlite.Sqlite3.columns(conn, stmt)
        rows = fetch_rows(conn, stmt, [])
        Exqlite.Sqlite3.release(conn, stmt)
        {:ok, rows, columns}
      end
    end

    defp fetch_rows(conn, stmt, acc) do
      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, row} -> fetch_rows(conn, stmt, [row | acc])
        :done -> Enum.reverse(acc)
      end
    end

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
        evergreen: int_to_bool(map["evergreen"]),
        embedding: decode_embedding(map["embedding"]),
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

    defp build_scope_clause(scope, param_offset) when map_size(scope) == 0,
      do: {"", List.duplicate(nil, 0) |> then(fn _ -> [] end)}

    defp build_scope_clause(scope, param_offset) do
      {clauses, params} =
        scope
        |> Enum.with_index(param_offset + 1)
        |> Enum.map(fn {{key, value}, idx} ->
          col = field_to_column(key)
          {"#{col} = ?#{idx}", value}
        end)
        |> Enum.unzip()

      sql = "WHERE " <> Enum.join(clauses, " AND ")
      {sql, params}
    end

    defp update_fts(conn, id, new_content) do
      del_sql = "DELETE FROM memories_fts WHERE id = ?1"
      ins_sql = "INSERT INTO memories_fts (id, content) VALUES (?1, ?2)"

      with {:ok, del_stmt} <- Exqlite.Sqlite3.prepare(conn, del_sql),
           :ok <- bind_and_step(conn, del_stmt, [id]),
           {:ok, ins_stmt} <- Exqlite.Sqlite3.prepare(conn, ins_sql),
           :ok <- bind_and_step(conn, ins_stmt, [id, new_content]) do
        :ok
      end
    end

    defp field_to_column(:metadata), do: "metadata_json"
    defp field_to_column(field), do: to_string(field)

    defp encode_field(:embedding, val), do: encode_embedding(val)
    defp encode_field(:metadata, val), do: Jason.encode!(val || %{})
    defp encode_field(:evergreen, val), do: bool_to_int(val)
    defp encode_field(:type, val), do: to_string(val)

    defp encode_field(key, val)
         when key in [:created_at, :updated_at, :last_accessed_at],
         do: datetime_to_iso(val)

    defp encode_field(_key, val), do: val

    defp encode_embedding(nil), do: nil
    defp encode_embedding(list) when is_list(list), do: Jason.encode!(list)

    defp decode_embedding(nil), do: nil
    defp decode_embedding(blob) when is_binary(blob), do: Jason.decode!(blob)

    defp decode_json(nil), do: %{}
    defp decode_json(str) when is_binary(str), do: Jason.decode!(str, keys: :atoms)

    defp bool_to_int(true), do: 1
    defp bool_to_int(false), do: 0
    defp bool_to_int(nil), do: 0

    defp int_to_bool(1), do: true
    defp int_to_bool(0), do: false
    defp int_to_bool(nil), do: false

    defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp datetime_to_iso(nil), do: DateTime.to_iso8601(DateTime.utc_now())

    defp parse_datetime(nil), do: nil

    defp parse_datetime(str) when is_binary(str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _} -> dt
        _ -> nil
      end
    end

    defp normalize_bm25(rank) when is_number(rank) do
      # bm25() returns negative values; closer to 0 = better
      # Convert to 0..1 scale: score = 1 / (1 + abs(rank))
      1.0 / (1.0 + abs(rank))
    end

    defp normalize_bm25(_), do: 0.0

    defp cosine_similarity([], _), do: 0.0
    defp cosine_similarity(_, []), do: 0.0

    defp cosine_similarity(a, b) when length(a) != length(b), do: 0.0

    defp cosine_similarity(a, b) do
      dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
      mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
      mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

      if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
    end
  end
else
  defmodule Nous.Memory.Store.SQLite do
    @moduledoc """
    SQLite-backed memory store (stub).

    Add `{:exqlite, "~> 0.27"}` to your dependencies to enable this store.
    """

    @behaviour Nous.Memory.Store

    @error {:error, "Exqlite is not available. Add {:exqlite, \"~> 0.27\"} to your dependencies."}

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

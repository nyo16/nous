# PostgreSQL Memory Store — End-to-End Example
#
# Demonstrates building a PostgreSQL-backed memory store using Postgrex
# with full-text search (tsvector) and vector similarity (pgvector).
#
# This is a REFERENCE IMPLEMENTATION — adapt for production use.
# It implements the Nous.Memory.Store behaviour so you can plug it
# directly into Nous agents via the Memory plugin.
#
# Requirements:
#   - PostgreSQL 14+ with the pgvector extension installed
#   - Add {:postgrex, "~> 0.19"} to your deps
#   - A running PostgreSQL instance (see connection config below)
#
# Run with: mix run examples/memory/postgresql_full.exs
#
# This example:
#   1. Implements a Nous.Memory.Store behaviour backend for PostgreSQL
#   2. Creates tables with tsvector + pgvector columns
#   3. Stores memories with embeddings
#   4. Demonstrates BM25-style text search via ts_rank
#   5. Demonstrates vector similarity search via pgvector
#   6. Shows hybrid search combining both
#   7. Integrates with a Nous agent via the Memory plugin

alias Nous.Memory.{Entry, Search}

# ============================================================================
# Section 1: PostgresStore — Nous.Memory.Store implementation
# ============================================================================

defmodule PostgresStore do
  @moduledoc """
  PostgreSQL-backed memory store using Postgrex.

  Supports:
    - Full-text search via tsvector / ts_rank (BM25-like ranking)
    - Vector similarity search via pgvector (<=> cosine distance)
    - Scoped queries by agent_id, user_id, session_id, namespace

  State is the Postgrex connection pid.
  """

  @behaviour Nous.Memory.Store

  alias Nous.Memory.Entry

  @embedding_dimension 384

  # ------------------------------------------------------------------
  # Table creation SQL
  # ------------------------------------------------------------------

  @create_extension "CREATE EXTENSION IF NOT EXISTS vector"

  @create_table """
  CREATE TABLE IF NOT EXISTS memories (
    id            TEXT PRIMARY KEY,
    content       TEXT NOT NULL,
    type          TEXT NOT NULL DEFAULT 'semantic',
    importance    DOUBLE PRECISION NOT NULL DEFAULT 0.5,
    evergreen     BOOLEAN NOT NULL DEFAULT false,
    embedding     vector(#{@embedding_dimension}),
    agent_id      TEXT,
    session_id    TEXT,
    user_id       TEXT,
    namespace     TEXT,
    metadata      JSONB NOT NULL DEFAULT '{}',
    access_count  INTEGER NOT NULL DEFAULT 0,
    content_tsv   tsvector GENERATED ALWAYS AS (
                    to_tsvector('english', content)
                  ) STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_accessed_at TIMESTAMPTZ NOT NULL DEFAULT now()
  )
  """

  # Indexes for fast search
  @create_gin_index """
  CREATE INDEX IF NOT EXISTS idx_memories_content_tsv
  ON memories USING GIN (content_tsv)
  """

  @create_ivfflat_index """
  CREATE INDEX IF NOT EXISTS idx_memories_embedding
  ON memories USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100)
  """

  @create_scope_indexes [
    "CREATE INDEX IF NOT EXISTS idx_memories_agent_id ON memories (agent_id)",
    "CREATE INDEX IF NOT EXISTS idx_memories_user_id ON memories (user_id)",
    "CREATE INDEX IF NOT EXISTS idx_memories_session_id ON memories (session_id)"
  ]

  # ------------------------------------------------------------------
  # init/1 — connect and create tables
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    # opts should contain Postgrex connection options:
    #   hostname, database, username, password, port, etc.
    conn_opts =
      Keyword.merge(
        [hostname: "localhost", database: "nous_memory", port: 5432],
        opts
      )

    with {:ok, conn} <- Postgrex.start_link(conn_opts),
         :ok <- setup_schema(conn) do
      {:ok, conn}
    end
  end

  defp setup_schema(conn) do
    # Create pgvector extension (requires superuser or extension already available)
    Postgrex.query!(conn, @create_extension, [])
    Postgrex.query!(conn, @create_table, [])
    Postgrex.query!(conn, @create_gin_index, [])

    # IVFFlat index requires rows to exist; create it only if table has data.
    # For a fresh table, skip or use HNSW instead.
    # Postgrex.query!(conn, @create_ivfflat_index, [])

    for sql <- @create_scope_indexes do
      Postgrex.query!(conn, sql, [])
    end

    :ok
  end

  # ------------------------------------------------------------------
  # store/2 — insert a memory entry
  # ------------------------------------------------------------------

  @impl true
  def store(conn, %Entry{} = entry) do
    sql = """
    INSERT INTO memories
      (id, content, type, importance, evergreen, embedding,
       agent_id, session_id, user_id, namespace, metadata,
       access_count, created_at, updated_at, last_accessed_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
    ON CONFLICT (id) DO UPDATE SET
      content = EXCLUDED.content,
      updated_at = EXCLUDED.updated_at
    """

    params = [
      entry.id,
      entry.content,
      to_string(entry.type),
      entry.importance,
      entry.evergreen,
      encode_vector(entry.embedding),
      entry.agent_id,
      entry.session_id,
      entry.user_id,
      entry.namespace,
      entry.metadata || %{},
      entry.access_count,
      entry.created_at,
      entry.updated_at,
      entry.last_accessed_at
    ]

    case Postgrex.query(conn, sql, params) do
      {:ok, _} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # fetch/2 — get a single entry by ID
  # ------------------------------------------------------------------

  @impl true
  def fetch(conn, id) do
    sql = "SELECT * FROM memories WHERE id = $1"

    case Postgrex.query(conn, sql, [id]) do
      {:ok, %{rows: [row], columns: cols}} -> {:ok, row_to_entry(cols, row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # delete/2 — remove an entry
  # ------------------------------------------------------------------

  @impl true
  def delete(conn, id) do
    sql = "DELETE FROM memories WHERE id = $1"

    case Postgrex.query(conn, sql, [id]) do
      {:ok, _} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # update/3 — update fields on an existing entry
  # ------------------------------------------------------------------

  @impl true
  def update(conn, id, updates) when is_map(updates) do
    updates = Map.put(updates, :updated_at, DateTime.utc_now())

    {set_clauses, params} =
      updates
      |> Enum.with_index(1)
      |> Enum.map(fn {{key, value}, idx} ->
        col = field_to_column(key)
        {"#{col} = $#{idx}", encode_field(key, value)}
      end)
      |> Enum.unzip()

    sql =
      "UPDATE memories SET #{Enum.join(set_clauses, ", ")} WHERE id = $#{length(params) + 1}"

    case Postgrex.query(conn, sql, params ++ [id]) do
      {:ok, %{num_rows: 1}} -> {:ok, conn}
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # search_text/3 — full-text search using tsvector + ts_rank
  # ------------------------------------------------------------------

  @impl true
  def search_text(conn, query, opts) do
    scope = Keyword.get(opts, :scope, %{})
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    {scope_clause, scope_params, next_idx} = build_scope_clause(scope, 1)

    # plainto_tsquery handles natural language queries safely
    sql = """
    SELECT *,
           ts_rank_cd(content_tsv, plainto_tsquery('english', $#{next_idx})) AS rank
    FROM memories
    WHERE content_tsv @@ plainto_tsquery('english', $#{next_idx})
    #{scope_clause}
    ORDER BY rank DESC
    LIMIT $#{next_idx + 1}
    """

    params = scope_params ++ [query, limit]

    case Postgrex.query(conn, sql, params) do
      {:ok, %{rows: rows, columns: cols}} ->
        rank_idx = Enum.find_index(cols, &(&1 == "rank"))

        results =
          rows
          |> Enum.map(fn row ->
            rank = Enum.at(row, rank_idx)
            entry = row_to_entry(cols, row)
            # ts_rank_cd returns values in [0, ~1]; normalize for consistency
            score = normalize_ts_rank(rank)
            {entry, score}
          end)
          |> Enum.filter(fn {_e, score} -> score >= min_score end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # search_vector/3 — cosine similarity via pgvector
  # ------------------------------------------------------------------

  @impl true
  def search_vector(conn, embedding, opts) when is_list(embedding) do
    scope = Keyword.get(opts, :scope, %{})
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    {scope_clause, scope_params, next_idx} = build_scope_clause(scope, 1)

    # pgvector <=> operator returns cosine DISTANCE (0 = identical).
    # Convert to similarity: 1 - distance.
    sql = """
    SELECT *,
           1 - (embedding <=> $#{next_idx}::vector) AS similarity
    FROM memories
    WHERE embedding IS NOT NULL
    #{scope_clause}
    ORDER BY embedding <=> $#{next_idx}::vector
    LIMIT $#{next_idx + 1}
    """

    vec_param = encode_vector(embedding)
    params = scope_params ++ [vec_param, limit]

    case Postgrex.query(conn, sql, params) do
      {:ok, %{rows: rows, columns: cols}} ->
        sim_idx = Enum.find_index(cols, &(&1 == "similarity"))

        results =
          rows
          |> Enum.map(fn row ->
            similarity = Enum.at(row, sim_idx)
            entry = row_to_entry(cols, row)
            {entry, similarity}
          end)
          |> Enum.filter(fn {_e, score} -> score >= min_score end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # list/2 — list all entries, optionally scoped
  # ------------------------------------------------------------------

  @impl true
  def list(conn, opts) do
    scope = Keyword.get(opts, :scope, %{})
    {scope_clause, scope_params, _next_idx} = build_scope_clause(scope, 1)

    where = if scope_clause == "", do: "", else: "WHERE 1=1 #{scope_clause}"
    sql = "SELECT * FROM memories #{where} ORDER BY created_at DESC"

    case Postgrex.query(conn, sql, scope_params) do
      {:ok, %{rows: rows, columns: cols}} ->
        {:ok, Enum.map(rows, &row_to_entry(cols, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # Hybrid search helper (not part of the behaviour, but useful)
  # ------------------------------------------------------------------

  @doc """
  Hybrid search combining full-text and vector similarity using
  Reciprocal Rank Fusion (RRF). Returns the top-k results.
  """
  def hybrid_search(conn, query, embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    k = 60

    with {:ok, text_results} <- search_text(conn, query, opts),
         {:ok, vec_results} <- search_vector(conn, embedding, opts) do
      # Build RRF scores
      text_rrf =
        text_results
        |> Enum.with_index(1)
        |> Enum.map(fn {{entry, _score}, rank} -> {entry.id, entry, 1.0 / (k + rank)} end)

      vec_rrf =
        vec_results
        |> Enum.with_index(1)
        |> Enum.map(fn {{entry, _score}, rank} -> {entry.id, entry, 1.0 / (k + rank)} end)

      # Merge by entry ID, summing RRF scores
      merged =
        (text_rrf ++ vec_rrf)
        |> Enum.group_by(fn {id, _entry, _score} -> id end)
        |> Enum.map(fn {_id, group} ->
          {_id, entry, _score} = hd(group)
          total_score = Enum.reduce(group, 0.0, fn {_, _, s}, acc -> acc + s end)
          {entry, total_score}
        end)
        |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
        |> Enum.take(limit)

      {:ok, merged}
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp row_to_entry(columns, row) do
    map = Enum.zip(columns, row) |> Map.new()

    %Entry{
      id: map["id"],
      content: map["content"],
      type: safe_to_atom(map["type"]),
      importance: map["importance"] || 0.5,
      evergreen: map["evergreen"] || false,
      embedding: decode_vector(map["embedding"]),
      agent_id: map["agent_id"],
      session_id: map["session_id"],
      user_id: map["user_id"],
      namespace: map["namespace"],
      metadata: map["metadata"] || %{},
      access_count: map["access_count"] || 0,
      created_at: map["created_at"],
      updated_at: map["updated_at"],
      last_accessed_at: map["last_accessed_at"]
    }
  end

  defp build_scope_clause(scope, start_idx) when map_size(scope) == 0 do
    {"", [], start_idx}
  end

  defp build_scope_clause(scope, start_idx) do
    {clauses, params, next_idx} =
      Enum.reduce(scope, {[], [], start_idx}, fn {key, value}, {cls, prms, idx} ->
        col = field_to_column(key)
        {cls ++ ["AND #{col} = $#{idx}"], prms ++ [value], idx + 1}
      end)

    {Enum.join(clauses, " "), params, next_idx}
  end

  defp field_to_column(:metadata), do: "metadata"
  defp field_to_column(field), do: to_string(field)

  defp encode_field(:embedding, val), do: encode_vector(val)
  defp encode_field(:metadata, val), do: val || %{}
  defp encode_field(:type, val), do: to_string(val)
  defp encode_field(_key, val), do: val

  # pgvector expects a string like "[1.0,2.0,3.0]" or a Pgvector struct.
  # Using the string format for simplicity (works with plain Postgrex).
  defp encode_vector(nil), do: nil

  defp encode_vector(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &to_string/1) <> "]"
  end

  defp encode_vector(other), do: other

  defp decode_vector(nil), do: nil

  defp decode_vector(%Postgrex.Extensions.Vector{data: data}) when is_list(data) do
    data
  end

  defp decode_vector(str) when is_binary(str) do
    str
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.to_float/1)
  rescue
    _ -> nil
  end

  defp decode_vector(_), do: nil

  defp normalize_ts_rank(rank) when is_number(rank) and rank > 0 do
    # ts_rank_cd returns small positive floats; scale to 0..1
    min(rank * 10.0, 1.0)
  end

  defp normalize_ts_rank(_), do: 0.0

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> String.to_atom(str)
  end

  defp safe_to_atom(other), do: other
end

# ============================================================================
# Section 2: End-to-end demonstration
# ============================================================================

IO.puts("=== PostgreSQL Memory Store — End-to-End Demo ===\n")

# ------------------------------------------------------------------
# Connect and initialize
# ------------------------------------------------------------------

# Adjust these to match your local PostgreSQL setup.
# You can also set the DATABASE_URL environment variable.
conn_opts = [
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "nous_memory"),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres")
]

IO.puts(
  "Connecting to PostgreSQL at #{conn_opts[:hostname]}:#{conn_opts[:port]}/#{conn_opts[:database]}"
)

{:ok, conn} = PostgresStore.init(conn_opts)
IO.puts("Connected and schema created.\n")

# ------------------------------------------------------------------
# Store memories
# ------------------------------------------------------------------

IO.puts("--- Storing memories ---\n")

memories = [
  Entry.new(%{
    content: "User prefers Elixir and functional programming paradigms",
    importance: 0.9,
    type: :semantic,
    agent_id: "assistant",
    embedding: for(_ <- 1..384, do: :rand.normal())
  }),
  Entry.new(%{
    content: "Project deadline is April 15th for the API v2 release",
    importance: 0.95,
    type: :episodic,
    agent_id: "assistant",
    embedding: for(_ <- 1..384, do: :rand.normal())
  }),
  Entry.new(%{
    content: "Always run mix format and mix test before committing code",
    importance: 0.8,
    type: :procedural,
    evergreen: true,
    agent_id: "assistant",
    embedding: for(_ <- 1..384, do: :rand.normal())
  }),
  Entry.new(%{
    content: "The PostgreSQL database schema has 27 tables across 4 schemas",
    importance: 0.6,
    type: :semantic,
    agent_id: "researcher",
    embedding: for(_ <- 1..384, do: :rand.normal())
  }),
  Entry.new(%{
    content: "User asked about GenServer patterns for connection pooling",
    importance: 0.5,
    type: :episodic,
    agent_id: "assistant",
    embedding: for(_ <- 1..384, do: :rand.normal())
  })
]

conn =
  Enum.reduce(memories, conn, fn entry, c ->
    {:ok, c} = PostgresStore.store(c, entry)
    IO.puts("  Stored: #{entry.content}")
    c
  end)

IO.puts("\nStored #{length(memories)} memories.\n")

# ------------------------------------------------------------------
# Text search (tsvector + ts_rank)
# ------------------------------------------------------------------

IO.puts("--- Text search (tsvector) ---\n")

text_queries = ["Elixir programming", "deadline release", "GenServer pooling"]

for query <- text_queries do
  {:ok, results} = PostgresStore.search_text(conn, query, limit: 3)
  IO.puts("  Query: \"#{query}\"")

  case results do
    [] ->
      IO.puts("    (no matches)")

    results ->
      for {entry, score} <- results do
        IO.puts("    [#{Float.round(score, 4)}] #{entry.content}")
      end
  end

  IO.puts("")
end

# ------------------------------------------------------------------
# Vector similarity search (pgvector)
# ------------------------------------------------------------------

IO.puts("--- Vector search (pgvector cosine similarity) ---\n")

# In production, generate the query embedding from the same model
# used to embed the memories. Here we use a random vector for demo.
query_embedding = for(_ <- 1..384, do: :rand.normal())

{:ok, vec_results} = PostgresStore.search_vector(conn, query_embedding, limit: 3)

IO.puts("  Top 3 by vector similarity:")

for {entry, score} <- vec_results do
  IO.puts("    [#{Float.round(score, 4)}] #{entry.content}")
end

IO.puts("")

# ------------------------------------------------------------------
# Hybrid search (RRF fusion of text + vector)
# ------------------------------------------------------------------

IO.puts("--- Hybrid search (text + vector with RRF) ---\n")

{:ok, hybrid_results} =
  PostgresStore.hybrid_search(conn, "Elixir code practices", query_embedding, limit: 3)

IO.puts("  Hybrid results for \"Elixir code practices\":")

for {entry, score} <- hybrid_results do
  IO.puts("    [#{Float.round(score, 4)}] #{entry.content}")
end

IO.puts("")

# ------------------------------------------------------------------
# Scoped search
# ------------------------------------------------------------------

IO.puts("--- Scoped search (agent_id: researcher) ---\n")

{:ok, scoped} =
  PostgresStore.search_text(conn, "database schema",
    scope: %{agent_id: "researcher"},
    limit: 5
  )

for {entry, score} <- scoped do
  IO.puts("  [#{Float.round(score, 4)}] (#{entry.agent_id}) #{entry.content}")
end

IO.puts("")

# ------------------------------------------------------------------
# Fetch, update, delete
# ------------------------------------------------------------------

IO.puts("--- Fetch, update, delete ---\n")

first_id = hd(memories).id

{:ok, fetched} = PostgresStore.fetch(conn, first_id)
IO.puts("  Fetched: #{fetched.content}")

{:ok, _conn} = PostgresStore.update(conn, first_id, %{importance: 1.0})
{:ok, updated} = PostgresStore.fetch(conn, first_id)
IO.puts("  Updated importance: #{updated.importance}")

{:ok, conn} = PostgresStore.delete(conn, first_id)
IO.puts("  Deleted entry #{first_id}")

{:ok, remaining} = PostgresStore.list(conn, [])
IO.puts("  Remaining entries: #{length(remaining)}\n")

# ------------------------------------------------------------------
# Integration with Nous agent via Memory plugin
# ------------------------------------------------------------------

IO.puts("--- Agent integration ---\n")

IO.puts("""
  # To use PostgresStore with a Nous agent:

  agent = Nous.new("lmstudio:qwen3",
    plugins: [Nous.Plugins.Memory],
    deps: %{
      memory_config: %{
        store: PostgresStore,
        store_opts: [
          hostname: "localhost",
          database: "nous_memory",
          username: "postgres",
          password: "postgres"
        ],
        agent_id: "my-agent",
        auto_inject: true,
        inject_limit: 5,

        # Optional: add an embedding provider for semantic search
        # embedding: Nous.Memory.Embedding.OpenAI,
        # embedding_opts: %{api_key: System.get_env("OPENAI_API_KEY")}
      }
    }
  )

  # The agent now has remember/recall/forget tools and will
  # automatically inject relevant memories into each conversation.
""")

# ------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------

Postgrex.query!(conn, "DROP TABLE IF EXISTS memories", [])
IO.puts("Cleaned up. Done!")

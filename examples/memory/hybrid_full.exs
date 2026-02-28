# Hybrid Memory Store — Muninn + Zvec
#
# Combines Tantivy-based BM25 text search (Muninn) with
# HNSW vector similarity search (Zvec) for maximum retrieval quality.
# Requires: {:muninn, "~> 0.4"}, {:zvec, "~> 0.2"}
#
# Run: mix run examples/memory/hybrid_full.exs

alias Nous.Memory.{Entry, Store, Search}

index_path = Path.join(System.tmp_dir!(), "nous_muninn_example")
vectors_path = Path.join(System.tmp_dir!(), "nous_zvec_example")

IO.puts("Initializing hybrid store...")

{:ok, store} =
  Store.Hybrid.init(
    muninn_config: %{index_path: index_path},
    zvec_config: %{collection_path: vectors_path, embedding_dimension: 384}
  )

# Store memories (with mock embeddings for demo)
memories = [
  {"User prefers Elixir over Ruby", :semantic, 0.8},
  {"Deployed the new API endpoint yesterday", :episodic, 0.5},
  {"Always run mix test before pushing", :procedural, 0.9},
  {"The database schema has 42 tables", :semantic, 0.6}
]

store =
  Enum.reduce(memories, store, fn {content, type, importance}, s ->
    # In production you'd use a real embedding provider
    mock_embedding = for _ <- 1..384, do: :rand.uniform()

    entry =
      Entry.new(%{
        content: content,
        type: type,
        importance: importance,
        embedding: mock_embedding
      })

    {:ok, s} = Store.Hybrid.store(s, entry)
    s
  end)

IO.puts("Stored #{length(memories)} memories with embeddings\n")

# Text search (via Muninn/Tantivy BM25)
IO.puts("Text search: 'Elixir programming'")
{:ok, text_results} = Store.Hybrid.search_text(store, "Elixir programming", limit: 3)

for {entry, score} <- text_results do
  IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
end

# Vector search (via Zvec HNSW)
IO.puts("\nVector search: (using random query vector)")
query_vec = for _ <- 1..384, do: :rand.uniform()
{:ok, vec_results} = Store.Hybrid.search_vector(store, query_vec, limit: 3)

for {entry, score} <- vec_results do
  IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
end

IO.puts("\nDone!")

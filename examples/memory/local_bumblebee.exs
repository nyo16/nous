# Local Semantic Search — Bumblebee + ETS
#
# Uses Bumblebee for local on-device embeddings (no API keys needed).
# Requires: {:bumblebee, "~> 0.6"}, {:exla, "~> 0.9"}
#
# Run: mix run examples/memory/local_bumblebee.exs
# Note: First run downloads the model (~1.2GB), subsequent runs use cache.

alias Nous.Memory.{Entry, Store, Search, Embedding}

IO.puts("Initializing Bumblebee embedding model (first run downloads ~1.2GB)...")

# Test embedding generation
{:ok, embedding} = Embedding.Bumblebee.embed("test query")
IO.puts("Embedding dimension: #{length(embedding)}")

# Initialize store
{:ok, store} = Store.ETS.init([])

# Store memories with embeddings
memories = [
  "User's favorite programming language is Elixir",
  "The production database is PostgreSQL 16 on AWS RDS",
  "Always use structured logging with Logger metadata",
  "The CI pipeline runs on GitHub Actions with Elixir 1.16",
  "User prefers functional programming over OOP"
]

store =
  Enum.reduce(memories, store, fn content, s ->
    {:ok, emb} = Embedding.Bumblebee.embed(content)
    entry = Entry.new(%{content: content, embedding: emb, importance: 0.7})
    {:ok, s} = Store.ETS.store(s, entry)
    s
  end)

IO.puts("\nStored #{length(memories)} memories with embeddings\n")

# Semantic search — these queries don't share exact words with memories
queries = [
  "What language does the user like?",
  "Where is the database hosted?",
  "How should I write logs?"
]

for query <- queries do
  {:ok, results} = Search.search(Store.ETS, store, query, Embedding.Bumblebee, limit: 3)

  IO.puts("Query: \"#{query}\"")

  for {entry, score} <- results do
    IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
  end

  IO.puts("")
end

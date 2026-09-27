# Local Semantic Search — Bumblebee + ETS
#
# Uses Bumblebee for local on-device embeddings (no API keys needed), through
# the example provider in `examples/memory/bumblebee_embedding.ex` — a
# `Nous.Memory.Embedding` implementation that lives outside Nous, the same way
# yours would.
#
# Requires: {:bumblebee, "~> 0.6"}, {:exla, "~> 0.9"} in your deps.
#
# Run: mix run examples/memory/local_bumblebee.exs
# Note: First run downloads the model (~1.2GB), subsequent runs use cache.

unless Code.ensure_loaded?(Bumblebee) do
  IO.puts("""
  Skipping: Bumblebee is not available.

  Add these to your app's deps (they are deliberately NOT declared by Nous —
  Nx/EXLA are too heavy for a library dependency):

      {:bumblebee, "~> 0.6"},
      {:exla, "~> 0.9"},

  then run `mix deps.get` and re-run this script.
  """)

  System.halt(0)
end

Code.require_file("bumblebee_embedding.ex", __DIR__)

alias MyApp.Memory.Embedding.Bumblebee
alias Nous.Memory.{Entry, Store, Search}

# The provider's two processes — in an app these go in your supervision tree.
{:ok, _} = Registry.start_link(keys: :unique, name: Bumblebee.Registry)
{:ok, _} = Bumblebee.ServingSupervisor.start_link([])

IO.puts("Initializing Bumblebee embedding model (first run downloads ~1.2GB)...")

{:ok, embedding} = Bumblebee.embed("test query")
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
    {:ok, emb} = Bumblebee.embed(content)
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
  {:ok, results} = Search.search(Store.ETS, store, query, Bumblebee, limit: 3)

  IO.puts("Query: \"#{query}\"")

  for {entry, score} <- results do
    IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
  end

  IO.puts("")
end

# DuckDB Memory Store
#
# Uses DuckDB with FTS and vector similarity search.
# Requires: {:duckdbex, "~> 0.5"}
#
# Run: mix run examples/memory/duckdb_full.exs

alias Nous.Memory.{Entry, Store, Search}

db_path = Path.join(System.tmp_dir!(), "nous_memory_example.duckdb")
File.rm(db_path)

IO.puts("Opening DuckDB database at #{db_path}")

store =
  case Store.DuckDB.init(path: db_path) do
    {:ok, store} ->
      store

    {:error, reason} ->
      IO.puts("""

      Skipping: #{reason}

      duckdbex is an optional dependency of Nous — declared in Nous's own
      mix.exs so it builds and tests here, but not pulled into your app unless
      you add it. In your app's mix.exs:

          {:duckdbex, "~> 0.5"},

      then run `mix deps.get`.
      """)

      System.halt(0)
  end

# Store memories
entries = [
  Entry.new(%{content: "The user's name is Alice", importance: 0.9}),
  Entry.new(%{content: "Alice works at Acme Corp on the data team", importance: 0.8}),
  Entry.new(%{
    content: "Preferred communication style: concise and technical",
    importance: 0.7,
    evergreen: true
  }),
  Entry.new(%{
    content: "Last discussed topic: Elixir GenServer patterns",
    importance: 0.5,
    type: :episodic
  })
]

store =
  Enum.reduce(entries, store, fn entry, s ->
    {:ok, s} = Store.DuckDB.store(s, entry)
    s
  end)

IO.puts("Stored #{length(entries)} memories\n")

# Search
queries = ["Who is the user?", "communication preferences", "what did we discuss?"]

for query <- queries do
  {:ok, results} = Search.search(Store.DuckDB, store, query)
  IO.puts("Query: \"#{query}\"")

  for {entry, score} <- results do
    IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
  end

  IO.puts("")
end

File.rm(db_path)
IO.puts("Done!")

# Basic Memory System — ETS Store
#
# The simplest memory setup. Uses ETS for storage and Jaro distance
# for text matching. No external deps needed.
#
# Run: mix run examples/memory/basic_ets.exs

alias Nous.Memory.{Entry, Store, Search}

# Initialize the ETS store
{:ok, store} = Store.ETS.init([])

# Store some memories
entries = [
  Entry.new(%{content: "User prefers dark mode", type: :semantic, importance: 0.9}),
  Entry.new(%{
    content: "Project uses Phoenix LiveView with Tailwind CSS",
    type: :semantic,
    importance: 0.7
  }),
  Entry.new(%{
    content: "Had a meeting about database migration on Monday",
    type: :episodic,
    importance: 0.5
  }),
  Entry.new(%{
    content: "To deploy: run mix release then docker build",
    type: :procedural,
    importance: 0.8,
    evergreen: true
  })
]

store =
  Enum.reduce(entries, store, fn entry, s ->
    {:ok, s} = Store.ETS.store(s, entry)
    s
  end)

IO.puts("Stored #{length(entries)} memories\n")

# Search for memories
queries = ["dark mode preferences", "how to deploy", "Phoenix project"]

for query <- queries do
  {:ok, results} = Search.search(Store.ETS, store, query)

  IO.puts("Query: \"#{query}\"")

  for {entry, score} <- Enum.take(results, 3) do
    IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
  end

  IO.puts("")
end

# List all memories
{:ok, all} = Store.ETS.list(store, [])
IO.puts("Total memories in store: #{length(all)}")

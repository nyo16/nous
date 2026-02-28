# SQLite Memory Store
#
# Uses SQLite with FTS5 for full-text search. Single file, embedded database.
# Requires: {:exqlite, "~> 0.27"}
#
# Run: mix run examples/memory/sqlite_full.exs

alias Nous.Memory.{Entry, Store, Search}

db_path = Path.join(System.tmp_dir!(), "nous_memory_example.db")
# Start fresh
File.rm(db_path)

IO.puts("Opening SQLite database at #{db_path}")
{:ok, store} = Store.SQLite.init(path: db_path)

# Store memories
entries = [
  Entry.new(%{
    content: "User prefers dark mode in VS Code",
    importance: 0.8,
    agent_id: "assistant"
  }),
  Entry.new(%{
    content: "Project deadline is March 15th",
    importance: 0.9,
    type: :episodic,
    agent_id: "assistant"
  }),
  Entry.new(%{
    content: "Use mix format before committing",
    importance: 0.7,
    type: :procedural,
    evergreen: true,
    agent_id: "assistant"
  }),
  Entry.new(%{
    content: "The API rate limit is 100 requests per minute",
    importance: 0.6,
    agent_id: "researcher"
  })
]

store =
  Enum.reduce(entries, store, fn entry, s ->
    {:ok, s} = Store.SQLite.store(s, entry)
    s
  end)

IO.puts("Stored #{length(entries)} memories\n")

# Text search (uses FTS5 BM25)
{:ok, results} = Search.search(Store.SQLite, store, "dark mode")
IO.puts("Search: 'dark mode'")

for {entry, score} <- results do
  IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
end

# Scoped search — only assistant's memories
IO.puts("\nScoped search (agent_id: assistant): 'deadline'")

{:ok, results} =
  Search.search(Store.SQLite, store, "deadline", nil, scope: %{agent_id: "assistant"})

for {entry, score} <- results do
  IO.puts("  [#{Float.round(score, 3)}] #{entry.content}")
end

# Clean up
File.rm(db_path)
IO.puts("\nDone! Database cleaned up.")

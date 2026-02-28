# Cross-Agent Memory Sharing
#
# Demonstrates how multiple agents can share a memory store
# while maintaining isolated views via scoping.
#
# Run: mix run examples/memory/cross_agent.exs

alias Nous.Memory.{Entry, Store, Search}

{:ok, store} = Store.ETS.init([])

# Agent A stores its memories
agent_a_memories = [
  Entry.new(%{
    content: "User prefers dark mode",
    agent_id: "agent_a",
    user_id: "user_1",
    importance: 0.8
  }),
  Entry.new(%{
    content: "User's timezone is PST",
    agent_id: "agent_a",
    user_id: "user_1",
    importance: 0.6
  })
]

store =
  Enum.reduce(agent_a_memories, store, fn entry, s ->
    {:ok, s} = Store.ETS.store(s, entry)
    s
  end)

# Agent B stores its memories
agent_b_memories = [
  Entry.new(%{
    content: "User asked about Phoenix deployment",
    agent_id: "agent_b",
    user_id: "user_1",
    importance: 0.7
  }),
  Entry.new(%{
    content: "Recommended using fly.io for hosting",
    agent_id: "agent_b",
    user_id: "user_1",
    importance: 0.5
  })
]

store =
  Enum.reduce(agent_b_memories, store, fn entry, s ->
    {:ok, s} = Store.ETS.store(s, entry)
    s
  end)

IO.puts("Agent A stored #{length(agent_a_memories)} memories")
IO.puts("Agent B stored #{length(agent_b_memories)} memories\n")

# Agent A searches its own memories (scoped to agent_a)
IO.puts("Agent A searching own memories for 'user preferences':")

{:ok, results} =
  Search.search(Store.ETS, store, "user preferences", nil, scope: %{agent_id: "agent_a"})

for {entry, score} <- results do
  IO.puts("  [#{Float.round(score, 3)}] (#{entry.agent_id}) #{entry.content}")
end

# Agent B searches globally (cross-agent)
IO.puts("\nAgent B searching ALL memories for 'user' (global scope):")
{:ok, results} = Search.search(Store.ETS, store, "user", nil, scope: :global)

for {entry, score} <- results do
  IO.puts("  [#{Float.round(score, 3)}] (#{entry.agent_id}) #{entry.content}")
end

# User-scoped search (all agents, one user)
IO.puts("\nUser-scoped search for 'deployment' (user_id: user_1):")
{:ok, results} = Search.search(Store.ETS, store, "deployment", nil, scope: %{user_id: "user_1"})

for {entry, score} <- results do
  IO.puts("  [#{Float.round(score, 3)}] (#{entry.agent_id}) #{entry.content}")
end

IO.puts("\nDone!")

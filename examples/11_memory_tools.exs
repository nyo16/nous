#!/usr/bin/env elixir

# Nous AI - Memory Tools Example
# Enable agents to remember information across turns

IO.puts("=== Nous AI - Memory Tools Demo ===\n")

alias Nous.Tools.MemoryTools

# Example 1: Basic memory with context storage (short-term)
IO.puts("--- Example 1: Short-term Memory (Context-based) ---")

agent =
  Nous.new("lmstudio:qwen3",
    instructions: """
    You are a helpful assistant with memory capabilities.
    Use the memory tools to remember important information the user shares.
    When recalling information, search your memories first.
    """,
    tools: MemoryTools.all()
  )

# First interaction - store information
IO.puts("\nUser: My name is Alice and I prefer dark mode.")
{:ok, result1} = Nous.run(agent, "My name is Alice and I prefer dark mode.")
IO.puts("Assistant: #{result1.output}")

# Second interaction - recall information
IO.puts("\nUser: What's my name?")
{:ok, result2} = Nous.run(agent, "What's my name?", context: result1.context)
IO.puts("Assistant: #{result2.output}")

# Check stored memories
IO.puts("\n[Stored memories: #{length(result2.context.deps[:memories] || [])}]")

# Example 2: Using tags for organization
IO.puts("\n--- Example 2: Tags for Organization ---")

agent2 =
  Nous.new("lmstudio:qwen3",
    instructions: """
    You are an assistant that helps organize information.
    Use tags to categorize memories:
    - "preference" for user preferences
    - "task" for tasks and todos
    - "fact" for facts about the user
    Always use appropriate tags when storing memories.
    """,
    tools: MemoryTools.all()
  )

{:ok, r1} =
  Nous.run(
    agent2,
    "Remember these: I like coffee, I need to call mom, and my birthday is March 15"
  )

IO.puts("Stored: #{r1.output}")

# Recall specific category
{:ok, r2} = Nous.run(agent2, "What preferences do I have stored?", context: r1.context)
IO.puts("Preferences: #{r2.output}")

# Example 3: Long-term memory with Manager
IO.puts("\n--- Example 3: Long-term Memory (Persistent) ---")

# Start a memory manager for persistent storage
{:ok, manager} = Nous.Memory.Manager.start_link(agent_id: "persistent_assistant")

agent3 =
  Nous.new("lmstudio:qwen3",
    instructions: """
    You are an assistant with persistent memory.
    Information you remember will be saved even after the session ends.
    """,
    tools: MemoryTools.all()
  )

# Store with manager
{:ok, r3} =
  Nous.run(agent3, "Remember that my favorite color is blue", deps: %{memory_manager: manager})

IO.puts("Stored: #{r3.output}")

# Verify it's persisted
{:ok, memories} = Nous.Memory.Manager.list(manager)
IO.puts("Persistent memories: #{length(memories)}")

Enum.each(memories, fn m ->
  IO.puts("  - #{m.content} (tags: #{inspect(m.tags)})")
end)

# Example 4: Importance levels
IO.puts("\n--- Example 4: Importance Levels ---")

agent4 =
  Nous.new("lmstudio:qwen3",
    instructions: """
    You are an assistant that categorizes information by importance:
    - "critical" - Security info, medical info, emergencies
    - "high" - Important dates, key contacts
    - "medium" - Preferences, regular tasks
    - "low" - Trivia, casual mentions
    Set appropriate importance when storing memories.
    """,
    tools: MemoryTools.all()
  )

{:ok, r4} =
  Nous.run(agent4, """
  Remember these things:
  1. My emergency contact is 911
  2. I have a meeting tomorrow at 3pm
  3. I like pineapple on pizza
  """)

IO.puts("Stored: #{r4.output}")

# List memories by importance
memories = r4.context.deps[:memories] || []
by_importance = Enum.group_by(memories, & &1.importance)

IO.puts("\nMemories by importance:")

Enum.each([:critical, :high, :medium, :low], fn level ->
  count = length(Map.get(by_importance, level, []))
  if count > 0, do: IO.puts("  #{level}: #{count}")
end)

# Example 5: Search and recall
IO.puts("\n--- Example 5: Search and Recall ---")

# Pre-populate some memories
initial_memories = [
  %{
    id: 1,
    content: "User works at Acme Corp",
    tags: ["work"],
    importance: :medium,
    created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    access_count: 0
  },
  %{
    id: 2,
    content: "User's favorite programming language is Elixir",
    tags: ["preference", "tech"],
    importance: :medium,
    created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    access_count: 0
  },
  %{
    id: 3,
    content: "User has a dog named Max",
    tags: ["personal", "pet"],
    importance: :low,
    created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    access_count: 0
  }
]

agent5 =
  Nous.new("lmstudio:qwen3",
    instructions:
      "You have access to memories about the user. Search memories to answer questions.",
    tools: MemoryTools.all()
  )

{:ok, r5} =
  Nous.run(agent5, "What do you know about my work?", deps: %{memories: initial_memories})

IO.puts("Response: #{r5.output}")

IO.puts("\n=== Memory Tools Demo Complete ===")
IO.puts("\nKey features demonstrated:")
IO.puts("  1. Short-term memory via context")
IO.puts("  2. Tagging for organization")
IO.puts("  3. Persistent memory via Manager")
IO.puts("  4. Importance levels")
IO.puts("  5. Search and recall")

IO.puts("\nNext steps:")
IO.puts("  - Try RocksdbStore for disk persistence")
IO.puts("  - Add vector search for semantic recall")
IO.puts("  - Implement memory consolidation for long-term storage")

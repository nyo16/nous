#!/usr/bin/env elixir

# Nous AI - Conversation (v0.8.0)
# Multi-turn conversations with context continuation

IO.puts("=== Nous AI - Conversation Demo ===\n")

agent = Nous.new("lmstudio:qwen3",
  instructions: "You are a friendly assistant. Remember our conversation."
)

# ============================================================================
# Method 1: Context Continuation (v0.8.0 - Recommended)
# ============================================================================

IO.puts("--- Method 1: Context Continuation (v0.8.0) ---\n")

# First message
{:ok, result1} = Nous.run(agent, "Hi! My name is Alice.")
IO.puts("User: Hi! My name is Alice.")
IO.puts("Assistant: #{result1.output}\n")

# Follow-up using context: option - carries forward all state
{:ok, result2} = Nous.run(agent, "What's my name?", context: result1.context)
IO.puts("User: What's my name?")
IO.puts("Assistant: #{result2.output}\n")

# Continue the conversation
{:ok, result3} = Nous.run(agent, "I'm working on an Elixir project.", context: result2.context)
IO.puts("User: I'm working on an Elixir project.")
IO.puts("Assistant: #{result3.output}\n")

# The context carries all conversation history
{:ok, result4} = Nous.run(agent, "What do you know about me?", context: result3.context)
IO.puts("User: What do you know about me?")
IO.puts("Assistant: #{result4.output}\n")

IO.puts("Conversation length: #{length(result4.context.messages)} messages")
IO.puts("")

# ============================================================================
# Method 2: Message History (Legacy, still supported)
# ============================================================================

IO.puts("--- Method 2: Message History (Legacy) ---\n")

# Start fresh
{:ok, r1} = Nous.run(agent, "My favorite color is blue.")
IO.puts("User: My favorite color is blue.")
IO.puts("Assistant: #{r1.output}\n")

# Pass message_history explicitly
{:ok, r2} = Nous.run(agent, "What's my favorite color?", message_history: r1.new_messages)
IO.puts("User: What's my favorite color?")
IO.puts("Assistant: #{r2.output}\n")

# ============================================================================
# Method 3: Custom Message List
# ============================================================================

IO.puts("--- Method 3: Custom Messages ---\n")

alias Nous.Message

# Build a message list directly
messages = [
  Message.system("You are a math tutor."),
  Message.user("What is the square root of 144?"),
  Message.assistant("The square root of 144 is 12."),
  Message.user("And what's 12 squared?")
]

{:ok, result} = Nous.run(agent, messages: messages)
IO.puts("Continuing from custom history...")
IO.puts("Assistant: #{result.output}\n")

# ============================================================================
# Conversation with Tools
# ============================================================================

IO.puts("--- Conversation with Tools ---\n")

notes = fn ctx, %{"text" => text} ->
  existing = ctx.deps[:notes] || []
  %{saved: text, total_notes: length(existing) + 1}
end

agent_with_notes = Nous.new("lmstudio:qwen3",
  instructions: "You have a notes tool. Use it to save important info.",
  tools: [notes]
)

{:ok, r1} = Nous.run(agent_with_notes, "Save a note: Buy groceries",
  deps: %{notes: []}
)
IO.puts("User: Save a note: Buy groceries")
IO.puts("Assistant: #{r1.output}\n")

# Continue with context
{:ok, r2} = Nous.run(agent_with_notes, "Save another: Call mom",
  context: r1.context,
  deps: %{notes: ["Buy groceries"]}
)
IO.puts("User: Save another: Call mom")
IO.puts("Assistant: #{r2.output}\n")

# ============================================================================
# Key Points
# ============================================================================

IO.puts("""
--- Key Points ---

v0.8.0 Context Continuation (recommended):
  {:ok, result} = Nous.run(agent, "First message")
  {:ok, result2} = Nous.run(agent, "Follow up", context: result.context)

Legacy Message History:
  {:ok, result} = Nous.run(agent, "Message", message_history: previous)
  # Use result.new_messages for next call

Custom Messages:
  Nous.run(agent, messages: [Message.system(...), Message.user(...)])

The context: option preserves:
  - All messages
  - Tool call history
  - Usage statistics
  - Dependencies (deps)
""")

IO.puts("Next: mix run examples/05_callbacks.exs")

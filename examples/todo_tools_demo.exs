#!/usr/bin/env elixir

# Todo Tools Demo - Shows automatic task tracking

IO.puts("\n✅ Nous AI - Todo Tools Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

alias Nous.Tools.TodoTools

# Create agent with todo tracking enabled
agent = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful coding assistant.
  When given complex tasks, break them down into smaller steps using todos.
  Track your progress as you work through tasks.
  """,
  enable_todos: true,  # Enable todo tracking!
  tools: [
    &TodoTools.add_todo/2,
    &TodoTools.update_todo/2,
    &TodoTools.complete_todo/2,
    &TodoTools.list_todos/2,
    &TodoTools.delete_todo/2
  ]
)

IO.puts("==" |> String.duplicate(70))
IO.puts("")

# Test 1: Give AI a complex task - it should break it down
IO.puts("Test 1: Complex Task - AI Breaks It Down")
IO.puts("-" |> String.duplicate(70))
IO.puts("Task: 'Analyze the Elixir codebase and create a report'")
IO.puts("")

{:ok, result1} = Nous.run(agent,
  "Please analyze an Elixir codebase and create a report. Break this down into steps and start working.",
  deps: %{todos: []}  # Start with empty todos
)

IO.puts("AI Response:")
IO.puts(result1.output)
IO.puts("")

# Check todos created
todos_after_task1 = result1.deps[:todos] || []
IO.puts("Todos created: #{length(todos_after_task1)}")
Enum.each(todos_after_task1, fn todo ->
  status_icon = case todo.status do
    "completed" -> "✅"
    "in_progress" -> "⏳"
    "pending" -> "📝"
    _ -> "•"
  end
  IO.puts("  #{status_icon} [#{todo.id}] #{todo.text} (#{todo.status})")
end)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 2: Continue with existing todos
IO.puts("Test 2: Continue Work - AI Sees Previous Todos")
IO.puts("-" |> String.duplicate(70))

{:ok, result2} = Nous.run(agent,
  "Continue with the next task. What should we work on?",
  deps: %{todos: todos_after_task1}  # Pass existing todos
)

IO.puts("AI Response:")
IO.puts(result2.output)
IO.puts("")

# Check updated todos
todos_after_task2 = result2.deps[:todos] || todos_after_task1
IO.puts("Updated Todos:")
Enum.each(todos_after_task2, fn todo ->
  status_icon = case todo.status do
    "completed" -> "✅"
    "in_progress" -> "⏳"
    "pending" -> "📝"
    _ -> "•"
  end
  IO.puts("  #{status_icon} [#{todo.id}] #{todo.text} (#{todo.status})")
end)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 3: Ask AI to list todos
IO.puts("Test 3: AI Lists Its Own Todos")
IO.puts("-" |> String.duplicate(70))

{:ok, result3} = Nous.run(agent,
  "What todos do we have? Show me the current status.",
  deps: %{todos: todos_after_task2}
)

IO.puts("AI Response:")
IO.puts(result3.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("✅ Demo complete!")
IO.puts("")
IO.puts("Key Features Demonstrated:")
IO.puts("  ✓ AI automatically breaks down complex tasks into todos")
IO.puts("  ✓ Todos are injected into system prompt (AI always sees them)")
IO.puts("  ✓ AI updates todos as it works (in_progress, completed)")
IO.puts("  ✓ Todos persist across multiple run() calls via deps")
IO.puts("  ✓ AI can query its own todo list")
IO.puts("")
IO.puts("How It Works:")
IO.puts("  1. enable_todos: true - Enables todo tracking")
IO.puts("  2. Tools return __update_context__: %{todos: updated_todos}")
IO.puts("  3. AgentRunner merges updates into state.deps")
IO.puts("  4. Before each model request, todos injected into system prompt")
IO.puts("  5. AI sees: ⏳ In Progress, 📝 Pending, ✅ Completed")
IO.puts("")
IO.puts("Perfect for:")
IO.puts("  • Multi-step workflows")
IO.puts("  • Long-running tasks")
IO.puts("  • Autonomous agents")
IO.puts("  • Progress tracking")
IO.puts("")

#!/usr/bin/env elixir

# Nous AI - Context Updates (v0.8.0)
# Tools can modify context using ContextUpdate

IO.puts("=== Nous AI - Context Updates ===\n")

alias Nous.Tool.ContextUpdate

# ============================================================================
# Basic Context Access (deps)
# ============================================================================

IO.puts("--- Basic Context Access ---")

defmodule UserTools do
  def get_balance(ctx, _args) do
    user = ctx.deps[:user]
    %{user_id: user.id, balance: user.balance}
  end

  def get_preferences(ctx, _args) do
    user = ctx.deps[:user]
    %{theme: user.preferences[:theme], language: user.preferences[:language]}
  end
end

agent = Nous.new("lmstudio:qwen3",
  instructions: "Use tools to access user information.",
  tools: [
    &UserTools.get_balance/2,
    &UserTools.get_preferences/2
  ]
)

user = %{
  id: 123,
  name: "Alice",
  balance: 1250.50,
  preferences: %{theme: "dark", language: "en"}
}

{:ok, result} = Nous.run(agent, "What's my balance?", deps: %{user: user})
IO.puts("Response: #{result.output}\n")

# ============================================================================
# Context Updates with ContextUpdate struct (v0.8.0)
# ============================================================================

IO.puts("--- Context Updates ---")

defmodule TodoTools do
  def add_todo(ctx, %{"text" => text}) do
    existing = ctx.deps[:todos] || []
    new_todo = %{id: length(existing) + 1, text: text, done: false}

    # Return result WITH context update
    {:ok, %{added: new_todo, total: length(existing) + 1},
     ContextUpdate.new() |> ContextUpdate.set(:todos, existing ++ [new_todo])}
  end

  def list_todos(ctx, _args) do
    todos = ctx.deps[:todos] || []
    %{todos: todos, count: length(todos)}
  end

  def complete_todo(ctx, %{"id" => id}) do
    todos = ctx.deps[:todos] || []

    updated = Enum.map(todos, fn todo ->
      if todo.id == id, do: %{todo | done: true}, else: todo
    end)

    {:ok, %{completed: id},
     ContextUpdate.new() |> ContextUpdate.set(:todos, updated)}
  end
end

todo_agent = Nous.new("lmstudio:qwen3",
  instructions: "You manage a todo list. Use tools to add, list, and complete todos.",
  tools: [
    &TodoTools.add_todo/2,
    &TodoTools.list_todos/2,
    &TodoTools.complete_todo/2
  ]
)

# Start with empty todos
{:ok, r1} = Nous.run(todo_agent, "Add a todo: Buy groceries", deps: %{todos: []})
IO.puts("After add: #{r1.output}")

# Context carries forward with updates
{:ok, r2} = Nous.run(todo_agent, "Add another: Call mom", context: r1.context)
IO.puts("After second add: #{r2.output}")

# List shows accumulated todos
{:ok, r3} = Nous.run(todo_agent, "List all my todos", context: r2.context)
IO.puts("List: #{r3.output}\n")

# ============================================================================
# ContextUpdate Operations
# ============================================================================

IO.puts("--- ContextUpdate Operations ---")
IO.puts("""
ContextUpdate supports several operations:

  # Set a value (replaces existing)
  ContextUpdate.new() |> ContextUpdate.set(:key, value)

  # Merge into existing map
  ContextUpdate.new() |> ContextUpdate.merge(:settings, %{theme: "dark"})

  # Append to existing list
  ContextUpdate.new() |> ContextUpdate.append(:history, new_item)

  # Delete a key
  ContextUpdate.new() |> ContextUpdate.delete(:temporary_data)

Return from tool:
  {:ok, result, context_update}
""")

# ============================================================================
# Multi-User Scenarios
# ============================================================================

IO.puts("--- Multi-User Scenarios ---")

defmodule AccountTools do
  def check_balance(ctx, _args) do
    user = ctx.deps[:current_user]
    %{user: user.name, balance: user.balance}
  end
end

account_agent = Nous.new("lmstudio:qwen3",
  instructions: "Check user balances on request.",
  tools: [&AccountTools.check_balance/2]
)

# Alice's request
alice = %{name: "Alice", balance: 1000}
{:ok, r1} = Nous.run(account_agent, "Check my balance", deps: %{current_user: alice})
IO.puts("Alice: #{r1.output}")

# Bob's request (same agent, different deps)
bob = %{name: "Bob", balance: 5000}
{:ok, r2} = Nous.run(account_agent, "Check my balance", deps: %{current_user: bob})
IO.puts("Bob: #{r2.output}\n")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Use deps for:
   - User identity/session
   - Database connections
   - API keys
   - Configuration

2. Use ContextUpdate for:
   - Tool state changes
   - Accumulated data
   - Session state

3. Multi-tenant pattern:
   - Pass user-specific deps per request
   - Same agent instance serves multiple users
   - Each user gets isolated context

4. Testing:
   - Inject mock deps for unit tests
   - See 08_tool_testing.exs for helpers
""")

#!/usr/bin/env elixir

# Nous AI - Tools Example
# Give your AI agent functions to call

IO.puts("=== Nous AI - Tools Demo ===\n")

# Define a simple tool as a function
get_weather = fn _ctx, %{"city" => city} ->
  # In real code, call a weather API
  %{city: city, temperature: 72, conditions: "sunny"}
end

# Define a calculator tool
calculate = fn _ctx, %{"expression" => expr} ->
  # Simple evaluation (production code should be safer!)
  {result, _} = Code.eval_string(expr)
  %{expression: expr, result: result}
end

# Create agent with tools
agent = Nous.new("lmstudio:qwen3",
  instructions: "You are a helpful assistant with access to weather and math tools.",
  tools: [get_weather, calculate]
)

# Example 1: Weather query
IO.puts("--- Example 1: Weather ---")
{:ok, result} = Nous.run(agent, "What's the weather in Tokyo?")
IO.puts(result.output)
IO.puts("")

# Example 2: Math query
IO.puts("--- Example 2: Calculator ---")
{:ok, result} = Nous.run(agent, "What is 15 * 7 + 23?")
IO.puts(result.output)
IO.puts("")

# Example 3: Multi-tool query
IO.puts("--- Example 3: Combined ---")
{:ok, result} = Nous.run(agent, "Is 72 degrees warm? Check Tokyo's weather and tell me.")
IO.puts(result.output)

# Tool with context access (deps)
# See advanced/context_updates.exs for more details
IO.puts("\n--- Example 4: Tool with Context ---")

get_user_balance = fn ctx, _args ->
  user = ctx.deps[:user]
  %{user: user.name, balance: user.balance}
end

agent2 = Nous.new("lmstudio:qwen3",
  instructions: "You are a banking assistant.",
  tools: [get_user_balance]
)

deps = %{user: %{name: "Alice", balance: 1250.50}}

{:ok, result} = Nous.run(agent2, "What's my balance?", deps: deps)
IO.puts(result.output)

IO.puts("\nNext: mix run examples/03_streaming.exs")

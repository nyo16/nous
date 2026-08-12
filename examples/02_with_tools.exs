#!/usr/bin/env elixir

# Nous AI - Tools Example
# Give your AI agent functions to call

IO.puts("=== Nous AI - Tools Demo ===\n")

# Define a simple tool as a function.
#
# ALWAYS wrap a function in `Nous.Tool.from_function/2`. Passing the bare
# anonymous function works, but the tool then gets its name from
# `Function.info/1` — a compiler-mangled label like `-fun.0-/2` — and an EMPTY
# parameter schema, so the model cannot discover the arguments it must send.
get_weather = fn _ctx, %{"city" => city} ->
  # In real code, call a weather API
  %{city: city, temperature: 72, conditions: "sunny"}
end

weather_tool =
  Nous.Tool.from_function(get_weather,
    name: "get_weather",
    description: "Get the current weather for a city",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string", "description" => "City name, e.g. Tokyo"}
      },
      "required" => ["city"]
    }
  )

# Define a calculator tool
calculate = fn _ctx, %{"expression" => expr} ->
  # Simple evaluation (production code should be safer!)
  {result, _} = Code.eval_string(expr)
  %{expression: expr, result: result}
end

calculator_tool =
  Nous.Tool.from_function(calculate,
    name: "calculate",
    description: "Evaluate an arithmetic expression",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "expression" => %{"type" => "string", "description" => "e.g. \"15 * 7 + 23\""}
      },
      "required" => ["expression"]
    }
  )

# Create agent with tools
agent =
  Nous.new("lmstudio:qwen3",
    instructions: "You are a helpful assistant with access to weather and math tools.",
    tools: [weather_tool, calculator_tool]
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

# No arguments, but the schema is still explicit: an empty `properties` map is
# a statement ("this tool takes nothing"), an absent one is an accident.
balance_tool =
  Nous.Tool.from_function(get_user_balance,
    name: "get_user_balance",
    description: "Get the signed-in user's account balance",
    parameters: %{"type" => "object", "properties" => %{}, "required" => []}
  )

agent2 =
  Nous.new("lmstudio:qwen3",
    instructions: "You are a banking assistant.",
    tools: [balance_tool]
  )

deps = %{user: %{name: "Alice", balance: 1250.50}}

{:ok, result} = Nous.run(agent2, "What's my balance?", deps: deps)
IO.puts(result.output)

IO.puts("\nNext: mix run examples/03_streaming.exs")

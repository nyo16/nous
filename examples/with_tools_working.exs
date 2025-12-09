#!/usr/bin/env elixir

# Example: Using Nous with tools (function calling)
#
# This demonstrates how to give an AI agent access to custom functions
# that it can call to get information or perform actions.

IO.puts("Testing Nous AI with Tools")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Define some tools
defmodule Calculator do
  @doc """
  Add two numbers together.

  ## Parameters
  - x: First number
  - y: Second number
  """
  def add(_ctx, %{"x" => x, "y" => y}) do
    result = x + y
    IO.puts("  🔧 Tool called: add(#{x}, #{y}) = #{result}")
    result
  end

  @doc """
  Multiply two numbers.

  ## Parameters
  - x: First number
  - y: Second number
  """
  def multiply(_ctx, %{"x" => x, "y" => y}) do
    result = x * y
    IO.puts("  🔧 Tool called: multiply(#{x}, #{y}) = #{result}")
    result
  end

  @doc """
  Get the current time.
  """
  def get_time(_ctx, _args) do
    time = DateTime.utc_now() |> DateTime.to_string()
    IO.puts("  🔧 Tool called: get_time() = #{time}")
    time
  end
end

# Create agent with tools
IO.puts("Creating agent with tools:")
IO.puts("  - add(x, y)")
IO.puts("  - multiply(x, y)")
IO.puts("  - get_time()")
IO.puts("")

agent = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful assistant with access to calculator tools.
  When asked to perform calculations, use the provided tools.
  Always explain what you're doing.
  """,
  tools: [
    &Calculator.add/2,
    &Calculator.multiply/2,
    &Calculator.get_time/2
  ]
)

IO.puts("Agent ready: #{agent.name}")
IO.puts("Number of tools: #{length(agent.tools)}")
IO.puts("")

# Test 1: Simple calculation
IO.puts("Test 1: What is 25 + 17?")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "What is 25 + 17?") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nResponse:")
    IO.puts(result.output)
    IO.puts("\nStats:")
    IO.puts("  Tool calls: #{result.usage.tool_calls}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 2: Multiple operations
IO.puts("Test 2: Calculate (5 + 3) * 4")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "Calculate (5 + 3) * 4. Show your work!") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nResponse:")
    IO.puts(result.output)
    IO.puts("\nStats:")
    IO.puts("  Tool calls: #{result.usage.tool_calls}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 3: Get time
IO.puts("Test 3: What time is it?")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "What time is it right now?") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nResponse:")
    IO.puts(result.output)
    IO.puts("\nStats:")
    IO.puts("  Tool calls: #{result.usage.tool_calls}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("\n💡 The AI agent automatically decided which tools to call!")
IO.puts("   This is the power of function calling! 🚀")
IO.puts("")

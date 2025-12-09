#!/usr/bin/env elixir

# Calculator Tool Demo - Shows AI using multiple tools intelligently

IO.puts("\n🔧 Nous AI - Calculator Tools Demo")
IO.puts("=" |> String.duplicate(70))

defmodule MathTools do
  @doc "Add two numbers"
  def add(_ctx, args) do
    # Handle different possible argument formats from the AI
    {x, y} = case args do
      %{"x" => x, "y" => y} -> {x, y}
      %{"a" => a, "b" => b} -> {a, b}
      _ -> {0, 0}
    end

    result = x + y
    IO.puts("  ➕ add(#{x}, #{y}) = #{result}")
    result
  end

  @doc "Multiply two numbers"
  def multiply(_ctx, args) do
    # Handle different possible argument formats from the AI
    {x, y} = case args do
      %{"x" => x, "y" => y} -> {x, y}
      %{"a" => a, "b" => b} -> {a, b}
      _ -> {0, 0}
    end

    result = x * y
    IO.puts("  ✖️  multiply(#{x}, #{y}) = #{result}")
    result
  end
end

agent = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "You are a math helper. Use the add and multiply tools to calculate.",
  tools: [&MathTools.add/2, &MathTools.multiply/2]
)

IO.puts("\nAgent created with #{length(agent.tools)} tools")
IO.puts("")

# Test: Multi-step calculation
IO.puts("Question: What is (12 + 8) * 5?")
IO.puts("-" |> String.duplicate(70))

{:ok, result} = Nous.run(agent, "Calculate (12 + 8) * 5. Show your work!")

IO.puts("\n✅ Final Answer:")
IO.puts(result.output)

IO.puts("\n📊 Stats:")
IO.puts("  Tool calls: #{result.usage.tool_calls}")
IO.puts("  Total tokens: #{result.usage.total_tokens}")
IO.puts("  Requests: #{result.usage.requests}")

IO.puts("\n" <> ("=" |> String.duplicate(70)))
IO.puts("✨ The AI automatically chained the tools to solve the problem!")

#!/usr/bin/env elixir

# Example: Using Anthropic Claude with Extended Thinking
#
# Extended thinking allows Claude to "think through" complex problems
# before responding, improving reasoning quality.

IO.puts("\n🧠 Anthropic Claude - Extended Thinking Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Check for API key
api_key = System.get_env("ANTHROPIC_API_KEY")

if is_nil(api_key) do
  IO.puts("❌ ANTHROPIC_API_KEY not set!")
  System.halt(1)
end

# ============================================================================
# Thinking Mode Configuration
# ============================================================================

IO.puts("Creating agents with different thinking configurations...")
IO.puts("")

# Agent WITH extended thinking
agent_with_thinking =
  Nous.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "You are a helpful assistant. Think through problems carefully.",
    model_settings: %{
      max_tokens: 2000,
      thinking: %{
        type: "enabled",
        budget_tokens: 5000  # Allow up to 5000 tokens for thinking
      }
    }
  )

IO.puts("✓ Agent with thinking enabled (budget: 5000 tokens)")

# Agent WITHOUT thinking (normal mode)
agent_normal =
  Nous.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "You are a helpful assistant.",
    model_settings: %{
      max_tokens: 2000
    }
  )

IO.puts("✓ Agent with normal mode (no extended thinking)")
IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Test Complex Reasoning
# ============================================================================

complex_question = """
If a train travels from New York to Boston (215 miles) at 65 mph,
and another train travels from Boston to New York at 55 mph,
and they leave at the same time, where will they meet?
Show your reasoning step by step.
"""

IO.puts("\nComplex Question (benefits from thinking):")
IO.puts(complex_question)
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent_with_thinking, complex_question) do
  {:ok, result} ->
    IO.puts("\n✅ Response (WITH extended thinking):")
    IO.puts(result.output)
    IO.puts("\n📊 Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Compare with Normal Mode
# ============================================================================

IO.puts("\nSame question with normal mode (for comparison):")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent_normal, complex_question) do
  {:ok, result} ->
    IO.puts("\n✅ Response (normal mode):")
    IO.puts(result.output)
    IO.puts("\n📊 Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# ============================================================================
# Configuration Options
# ============================================================================

IO.puts("📖 Thinking Mode Configuration:")
IO.puts("")
IO.puts("Option 1: Enable with budget")
IO.puts("  thinking: %{type: \"enabled\", budget_tokens: 5000}")
IO.puts("")
IO.puts("Option 2: Enable at agent level")
IO.puts("  model_settings: %{thinking: %{type: \"enabled\", budget_tokens: 3000}}")
IO.puts("")
IO.puts("Option 3: Enable per-request")
IO.puts("  Nous.run(agent, prompt,")
IO.puts("    model_settings: %{thinking: %{type: \"enabled\", budget_tokens: 5000}}")
IO.puts("  )")
IO.puts("")
IO.puts("💡 Use thinking for:")
IO.puts("  - Complex reasoning problems")
IO.puts("  - Multi-step logical deduction")
IO.puts("  - Code debugging and analysis")
IO.puts("  - Mathematical proofs")
IO.puts("")

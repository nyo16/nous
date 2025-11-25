#!/usr/bin/env elixir

# Example: Using Anthropic Claude with Extended Context (1M tokens)
#
# This demonstrates how to enable Claude's extended context window
# for processing very large documents or conversations.

IO.puts("\n📚 Anthropic Claude - Extended Context Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Check for API key
api_key = System.get_env("ANTHROPIC_API_KEY")

if is_nil(api_key) do
  IO.puts("❌ ANTHROPIC_API_KEY not set!")
  System.halt(1)
end

# ============================================================================
# Option 1: Enable at agent creation (applies to all requests)
# ============================================================================

IO.puts("Method 1: Enable long context at agent creation")
IO.puts("-" |> String.duplicate(70))

agent_with_long_context =
  Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "You are a helpful assistant",
    model_settings: %{
      enable_long_context: true,  # Enable 1M token context window
      max_tokens: 500,
      temperature: 0.7
    }
  )

IO.puts("✓ Agent created with extended context (1M tokens)")
IO.puts("")

# Test with long context agent
case Yggdrasil.run(agent_with_long_context, "Hello! Can you process large documents?") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))

# ============================================================================
# Option 2: Enable per-request (override default)
# ============================================================================

IO.puts("\nMethod 2: Enable long context per-request")
IO.puts("-" |> String.duplicate(70))

# Agent without long context by default
agent_normal =
  Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "You are a helpful assistant",
    model_settings: %{
      max_tokens: 500
    }
  )

IO.puts("✓ Agent created with normal context")

# Enable long context for this specific request
case Yggdrasil.run(
       agent_normal,
       "Process this large input...",
       model_settings: %{enable_long_context: true}
     ) do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")
    IO.puts("(This request used extended 1M context)")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# ============================================================================
# Usage Recommendations
# ============================================================================

IO.puts("📖 Usage Recommendations:")
IO.puts("")
IO.puts("✓ Use enable_long_context: true when:")
IO.puts("  - Processing large documents (>200K tokens)")
IO.puts("  - Long conversation history")
IO.puts("  - Code analysis of large codebases")
IO.puts("  - Book summaries or long-form content")
IO.puts("")
IO.puts("✓ Use enable_long_context: false (default) when:")
IO.puts("  - Short questions and answers")
IO.puts("  - Simple tool calling")
IO.puts("  - Cost optimization is important")
IO.puts("")
IO.puts("💡 Extended context provides up to 1 million tokens!")
IO.puts("")

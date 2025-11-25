#!/usr/bin/env elixir

# Example: Using Yggdrasil with Anthropic Claude (native API)
#
# This uses the native Anthropic API via the Anthropix library,
# not the OpenAI-compatible API.
#
# Setup:
# 1. Get API key from https://console.anthropic.com/
# 2. export ANTHROPIC_API_KEY="sk-ant-..."
# 3. Run this example

IO.puts("\n🤖 Yggdrasil AI - Anthropic Claude Example")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Check for API key
api_key = System.get_env("ANTHROPIC_API_KEY")

if is_nil(api_key) do
  IO.puts("❌ ANTHROPIC_API_KEY not set!")
  IO.puts("")
  IO.puts("Please set your API key:")
  IO.puts("  export ANTHROPIC_API_KEY='sk-ant-...'")
  IO.puts("")
  IO.puts("Get your key from: https://console.anthropic.com/")
  System.halt(1)
end

# Create agent using Anthropic Claude
# Using claude-sonnet-4-5-20250929 as requested
agent =
  Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "Be helpful and concise. Explain things clearly.",
    model_settings: %{
      max_tokens: 500,
      temperature: 0.7
    }
  )

IO.puts("Agent created:")
IO.puts("  Provider: Anthropic (native API)")
IO.puts("  Model: claude-sonnet-4-5-20250929")
IO.puts("")

# Test 1: Simple question
IO.puts("Test 1: What is Elixir?")
IO.puts("-" |> String.duplicate(70))

case Yggdrasil.run(agent, "What is Elixir programming language? Answer in 2 sentences.") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nResponse:")
    IO.puts(result.output)
    IO.puts("\n📊 Usage:")
    IO.puts("  Requests: #{result.usage.requests}")
    IO.puts("  Input tokens: #{result.usage.input_tokens}")
    IO.puts("  Output tokens: #{result.usage.output_tokens}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("✨ Using Anthropic's native API via Anthropix!")
IO.puts("")

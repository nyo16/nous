#!/usr/bin/env elixir

# Example: Using Nous with Google Gemini
#
# This uses Google's Gemini API via the gemini_ex library
#
# Setup:
# 1. Get API key from https://makersuite.google.com/app/apikey
# 2. export GOOGLE_AI_API_KEY="AIzaSy..."
# 3. Run this example

IO.puts("\n🤖 Nous AI - Google Gemini Example")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Check for API key
api_key = System.get_env("GOOGLE_AI_API_KEY")

if is_nil(api_key) do
  IO.puts("❌ GOOGLE_AI_API_KEY not set!")
  IO.puts("")
  IO.puts("Please set your API key:")
  IO.puts("  export GOOGLE_AI_API_KEY='AIzaSy...'")
  IO.puts("")
  IO.puts("Get your key from: https://makersuite.google.com/app/apikey")
  System.halt(1)
end

# Create agent using Google Gemini
agent =
  Nous.new("gemini:gemini-2.0-flash-exp",
    api_key: api_key,
    instructions: "Be helpful and concise. Answer clearly.",
    model_settings: %{
      temperature: 0.7,
      max_tokens: 500
    }
  )

IO.puts("Agent created:")
IO.puts("  Provider: Google Gemini")
IO.puts("  Model: gemini-2.0-flash-exp")
IO.puts("")

# Test 1: Simple question
IO.puts("Test: What is Elixir programming language?")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "What is Elixir programming language? Answer in 2 sentences.") do
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
IO.puts("✨ Using Google's Gemini API!")
IO.puts("")

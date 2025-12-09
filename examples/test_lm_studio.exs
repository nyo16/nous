#!/usr/bin/env elixir

# Test Nous with local LM Studio
#
# Make sure LM Studio is running on http://localhost:1234
# with the qwen/qwen3-30b-a3b-2507 model loaded

IO.puts("Testing Nous AI with LM Studio")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Create agent pointing to LM Studio
agent = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Always answer in rhymes. Today is Thursday",
  model_settings: %{
    temperature: 0.7,
    max_tokens: -1
  }
)

IO.puts("Agent created:")
IO.puts("  Name: #{agent.name}")
IO.puts("  Model: #{agent.model.model}")
IO.puts("  Provider: #{agent.model.provider}")
IO.puts("  Base URL: #{agent.model.base_url}")
IO.puts("")

# Test 1: Simple question
IO.puts("Test 1: What day is it today?")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "What day is it today?") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nResponse:")
    IO.puts(result.output)
    IO.puts("\nUsage:")
    IO.puts("  Requests: #{result.usage.requests}")
    IO.puts("  Input tokens: #{result.usage.input_tokens}")
    IO.puts("  Output tokens: #{result.usage.output_tokens}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")
    IO.puts("\nCost: $0.00 (running locally!) 💰")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
    IO.puts("\nMake sure:")
    IO.puts("  1. LM Studio is running")
    IO.puts("  2. Server is started on http://localhost:1234")
    IO.puts("  3. Model qwen/qwen3-30b-a3b-2507 is loaded")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))

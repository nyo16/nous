#!/usr/bin/env elixir

# Example: Using Nous with LM Studio (local LLM server)
#
# LM Studio runs a local OpenAI-compatible server on http://localhost:1234
# You can download and run any model locally without API costs.
#
# Setup:
# 1. Download LM Studio from https://lmstudio.ai/
# 2. Download a model (e.g., Qwen 3 30B)
# 3. Start the local server in LM Studio
# 4. Run this example

Mix.install([
  {:nous, path: ".."}
])

alias Nous.Agent

# Create agent pointing to local LM Studio server
agent = Agent.new("custom:qwen/qwen3-30b-a3b-2507",
  base_url: "http://localhost:1234/v1",
  api_key: "not-needed",  # LM Studio doesn't require API key
  instructions: "Always answer in rhymes.",
  model_settings: %{
    temperature: 0.7,
    max_tokens: -1  # -1 means no limit
  }
)

# Run agent
IO.puts("Asking local LLM: What day is it today?")
IO.puts("(Using LM Studio at http://localhost:1234)\n")

case Agent.run(agent, "What day is it today?") do
  {:ok, result} ->
    IO.puts("Response:")
    IO.puts(result.output)
    IO.puts("\n---")
    IO.puts("Tokens used: #{result.usage.total_tokens}")
    IO.puts("Cost: $0.00 (running locally!)")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
    IO.puts("\nMake sure LM Studio is running on http://localhost:1234")
end

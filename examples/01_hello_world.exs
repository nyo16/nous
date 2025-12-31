#!/usr/bin/env elixir

# Nous AI - Hello World
# The simplest possible example

# Create an AI agent
agent = Nous.new("lmstudio:qwen3",
  instructions: "You are a friendly assistant. Keep responses brief."
)

# Ask it something
IO.puts("Asking: Hello! What can you do?")
IO.puts("")

{:ok, result} = Nous.run(agent, "Hello! What can you do?")

# See the response
IO.puts("Response:")
IO.puts(result.output)
IO.puts("")
IO.puts("Tokens used: #{result.usage.total_tokens}")

# That's it! You just ran your first AI agent.
#
# Try different providers:
#   Nous.new("anthropic:claude-sonnet-4-5-20250929", ...)
#   Nous.new("openai:gpt-4", ...)
#
# Next steps:
#   mix run examples/02_with_tools.exs   - Add function calling
#   mix run examples/03_streaming.exs    - Real-time responses

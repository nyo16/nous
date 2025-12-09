#!/usr/bin/env elixir

# Basic Nous Agent Template
# Copy this file and customize for your use case

# ============================================================================
# Configuration - Edit these values
# ============================================================================

# Choose your model (uncomment one):
# model = "lmstudio:qwen/qwen3-30b"              # Local (free)
# model = "anthropic:claude-sonnet-4-5-20250929"  # Claude (paid)
# model = "openai:gpt-4"                         # OpenAI (paid)
# model = "gemini:gemini-2.0-flash-exp"          # Gemini (paid)
model = "lmstudio:qwen/qwen3-30b"

# Your custom instructions
instructions = """
You are a helpful assistant.
Be concise and clear in your responses.
"""

# Your question/prompt
prompt = "Tell me an interesting fact about space."

# ============================================================================
# Agent Creation and Execution
# ============================================================================

# Create the agent
agent = Nous.new(model,
  instructions: instructions,
  model_settings: %{
    temperature: 0.7,    # Creativity (0.0 = deterministic, 1.0 = creative)
    max_tokens: -1       # Response length (-1 = unlimited)
  }
)

# Run the agent
IO.puts("🤖 Running agent with model: #{model}")
IO.puts("📝 Prompt: #{prompt}")
IO.puts("⏳ Thinking...")
IO.puts("")

case Nous.run(agent, prompt) do
  {:ok, result} ->
    IO.puts("✅ Response:")
    IO.puts(result.output)
    IO.puts("")
    IO.puts("📊 Usage:")
    IO.puts("  Input tokens:  #{result.usage.input_tokens}")
    IO.puts("  Output tokens: #{result.usage.output_tokens}")
    IO.puts("  Total tokens:  #{result.usage.total_tokens}")

  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
    IO.puts("")
    IO.puts("💡 Common fixes:")
    IO.puts("  - Make sure LM Studio is running (if using local model)")
    IO.puts("  - Check your API key is set (if using cloud model)")
    IO.puts("  - Verify your model string is correct")
end

# ============================================================================
# Next Steps
# ============================================================================

# Ready for more? Try these templates:
# - tool_agent.exs        (add function calling)
# - streaming_agent.exs   (real-time responses)
# - conversation_agent.exs (multi-turn chat)
#
# Or explore the examples:
# - examples/by_level/beginner/     (start here)
# - examples/by_feature/tools/      (function calling)
# - examples/by_feature/streaming/  (real-time)
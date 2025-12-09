#!/usr/bin/env elixir

# Example: Using Nous with vLLM server
#
# vLLM is a high-performance LLM serving system with OpenAI-compatible API
# Setup:
# 1. Install vLLM: pip install vllm
# 2. Start server: vllm serve qwen/qwen3-30b --port 8000
# 3. Run this example

IO.puts("\n🚀 Nous AI - vLLM Example")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Create agent pointing to vLLM server
# Note: base_url is required for vLLM
agent = Nous.new("vllm:qwen/qwen3-30b",
  base_url: "http://localhost:8000/v1",
  api_key: "not-needed",  # vLLM doesn't require API key by default
  instructions: "Be helpful and concise",
  model_settings: %{
    temperature: 0.7,
    max_tokens: 500
  }
)

IO.puts("Agent created:")
IO.puts("  Provider: vLLM")
IO.puts("  Model: qwen/qwen3-30b")
IO.puts("  Base URL: http://localhost:8000/v1")
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
    IO.puts("\nMake sure vLLM is running:")
    IO.puts("  vllm serve qwen/qwen3-30b --port 8000")
end

IO.puts("\n" <> ("=" |> String.duplicate(70)))
IO.puts("💡 vLLM provides high-performance inference for large models!")
IO.puts("")

#!/usr/bin/env elixir

# Nous AI - LM Studio (Local AI)
# Run AI models locally on your machine

IO.puts("=== Nous AI - LM Studio (Local) ===\n")

# ============================================================================
# Setup
# ============================================================================

IO.puts("""
--- Setup ---

1. Download LM Studio: https://lmstudio.ai/
2. Start LM Studio and load a model
3. Start the local server (default: http://localhost:1234)
4. Run this example
""")

# Check if LM Studio is running
base_url = System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234"

IO.puts("Checking LM Studio at #{base_url}...")

# ============================================================================
# Basic Usage
# ============================================================================

IO.puts("\n--- Basic Usage ---")

agent = Nous.new("lmstudio:qwen3",
  base_url: base_url,
  instructions: "You are helpful and concise."
)

IO.puts("Created agent with local model")

case Nous.run(agent, "What is 2 + 2?") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
    IO.puts("Make sure LM Studio is running with a model loaded.")
end

IO.puts("")

# ============================================================================
# Model Selection
# ============================================================================

IO.puts("--- Model Selection ---")
IO.puts("""
LM Studio model names map to loaded models:

  lmstudio:qwen3           - Qwen models
  lmstudio:llama           - Llama models
  lmstudio:mistral         - Mistral models
  lmstudio:codellama       - Code-focused models

The actual model used depends on what's loaded in LM Studio.
""")

# ============================================================================
# Tools with Local Models
# ============================================================================

IO.puts("--- Tools with Local Models ---")

get_time = fn _ctx, _args ->
  %{time: DateTime.utc_now() |> DateTime.to_string()}
end

calculate = fn _ctx, %{"expression" => expr} ->
  try do
    {result, _} = Code.eval_string(expr)
    %{result: result}
  rescue
    _ -> %{error: "Could not evaluate"}
  end
end

tool_agent = Nous.new("lmstudio:qwen3",
  base_url: base_url,
  instructions: "Use tools when asked about time or math.",
  tools: [get_time, calculate]
)

case Nous.run(tool_agent, "What time is it?") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tool calls: #{result.usage.tool_calls}")
  {:error, _} ->
    IO.puts("(Skipped - LM Studio not running)")
end

IO.puts("")

# ============================================================================
# Model Settings
# ============================================================================

IO.puts("--- Model Settings ---")

configured_agent = Nous.new("lmstudio:qwen3",
  base_url: base_url,
  instructions: "Be concise.",
  model_settings: %{
    temperature: 0.3,    # Lower = more focused
    max_tokens: 500,
    top_p: 0.9
  }
)

IO.puts("Agent configured with custom settings")
IO.puts("")

# ============================================================================
# Streaming
# ============================================================================

IO.puts("--- Streaming ---")

case Nous.run_stream(agent, "Count from 1 to 5.") do
  {:ok, stream} ->
    stream |> Enum.each(fn
      {:text_delta, text} -> IO.write(text)
      {:finish, _} -> IO.puts("")
      _ -> :ok
    end)

  {:error, _} ->
    IO.puts("(Skipped - LM Studio not running)")
end

IO.puts("")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Choose the right model:
   - Qwen: Good general purpose, efficient
   - Llama: Strong reasoning
   - Mistral: Fast, good for chat
   - CodeLlama: Best for code tasks

2. Hardware requirements:
   - 7B models: 8GB RAM
   - 13B models: 16GB RAM
   - 70B models: 32GB+ RAM

3. Performance tips:
   - Use smaller models for quick tasks
   - Enable GPU acceleration in LM Studio
   - Lower max_tokens for faster responses

4. When to use local:
   - Privacy-sensitive data
   - Offline requirements
   - Cost optimization
   - Development/testing
""")

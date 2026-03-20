#!/usr/bin/env elixir

# Nous AI - Custom Provider Examples
# Demonstrates using the `custom:` prefix with various OpenAI-compatible endpoints

IO.puts("=== Nous AI - Custom Provider Examples ===\n")

# ============================================================================
# Configuration Methods
# ============================================================================

IO.puts("""
--- Configuration Precedence ---

The custom provider loads configuration in this order (higher overrides lower):

1. Direct options (Nous.new/2)
2. Environment variables (CUSTOM_BASE_URL, CUSTOM_API_KEY)
3. Application config (config :nous, :custom, ...)

Examples below show all three methods.

""")

# ============================================================================
# Example 1: Groq (Cloud Provider)
# ============================================================================

IO.puts("--- Example 1: Groq (with explicit options) ---")

# Option 1: Explicit options
agent =
  Nous.new("custom:llama-3.1-70b-versatile",
    base_url: "https://api.groq.com/openai/v1",
    api_key: System.get_env("GROQ_API_KEY"),
    instructions: "Be concise."
  )

# Note: This will fail without GROQ_API_KEY set
if System.get_env("GROQ_API_KEY") do
  case Nous.run(agent, "What is the BEAM VM? One sentence.") do
    {:ok, result} ->
      IO.puts("Response: #{result.output}")
      IO.puts("Tokens: #{result.usage.total_tokens}")

    {:error, error} ->
      IO.puts("Error: #{inspect(error)}")
  end
else
  IO.puts("(Skipped - set GROQ_API_KEY to run this example)")
end

IO.puts("")

# ============================================================================
# Example 2: Together AI (Cloud Provider)
# ============================================================================

IO.puts("--- Example 2: Together AI (with explicit options) ---")

if System.get_env("TOGETHER_API_KEY") do
  agent =
    Nous.new("custom:meta-llama/Llama-3-70b-chat-hf",
      base_url: "https://api.together.xyz/v1",
      api_key: System.get_env("TOGETHER_API_KEY"),
      instructions: "Be helpful and concise."
    )

  case Nous.run(agent, "What language is Elixir built on?") do
    {:ok, result} ->
      IO.puts("Response: #{result.output}")
      IO.puts("Tokens: #{result.usage.total_tokens}")

    {:error, error} ->
      IO.puts("Error: #{inspect(error)}")
  end
else
  IO.puts("(Skipped - set TOGETHER_API_KEY to run this example)")
end

IO.puts("")

# ============================================================================
# Example 3: Local Server (LM Studio)
# ============================================================================

IO.puts("--- Example 3: Local Server (LM Studio style) ---")
IO.puts("Using custom: prefix with localhost:1234 (LM Studio default)")

local_agent =
  Nous.new("custom:qwen3",
    base_url: "http://localhost:1234/v1",
    instructions: "You are a helpful local assistant."
  )

case Nous.run(local_agent, "Hello from the custom provider!") do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")

  {:error, error} ->
    IO.puts("Could not connect to local server (expected if none running)")
    IO.puts("To test: Start LM Studio and load a model")
end

IO.puts("")

# ============================================================================
# Example 4: Environment Variable Configuration
# ============================================================================

IO.puts("--- Example 4: Environment Variable Configuration ---")

IO.puts("""
Set these environment variables for global defaults:

  export CUSTOM_BASE_URL="http://localhost:1234/v1"
  export CUSTOM_API_KEY="not-needed"

Then use without options:

  agent = Nous.new("custom:my-model")
""")

# Demonstrate with explicit env vars
original_base = System.get_env("CUSTOM_BASE_URL")
original_key = System.get_env("CUSTOM_API_KEY")

System.put_env("CUSTOM_BASE_URL", "http://localhost:1234/v1")
System.put_env("CUSTOM_API_KEY", "not-needed")

# Now create agent without base_url - it reads from env
env_agent = Nous.new("custom:qwen3")
IO.puts("Created agent with base_url from CUSTOM_BASE_URL env var")

# Restore original values
if original_base,
  do: System.put_env("CUSTOM_BASE_URL", original_base),
  else: System.delete_env("CUSTOM_BASE_URL")

if original_key,
  do: System.put_env("CUSTOM_API_KEY", original_key),
  else: System.delete_env("CUSTOM_API_KEY")

IO.puts("")

# ============================================================================
# Example 5: Streaming with Custom Provider
# ============================================================================

IO.puts("--- Example 5: Streaming with Custom Provider ---")

streaming_agent =
  Nous.new("custom:qwen3",
    base_url: "http://localhost:1234/v1",
    instructions: "Write a haiku."
  )

case Nous.run_stream(streaming_agent, "Write a haiku about coding") do
  {:ok, stream} ->
    IO.write("Response: ")

    stream
    |> Enum.each(fn
      {:text_delta, text} -> IO.write(text)
      {:finish, _} -> IO.puts("")
      _ -> :ok
    end)

  {:error, _} ->
    IO.puts("(Skipped - no local server running)")
end

IO.puts("")

# ============================================================================
# Example 6: Tools with Custom Provider
# ============================================================================

IO.puts("--- Example 6: Tools with Custom Provider ---")

get_weather = fn _ctx, %{"city" => city} ->
  forecasts = %{
    "San Francisco" => %{temp: 62, condition: "foggy"},
    "Tokyo" => %{temp: 75, condition: "sunny"},
    "London" => %{temp: 55, condition: "rainy"}
  }

  Map.get(forecasts, city, %{temp: 70, condition: "unknown"})
end

tool_agent =
  Nous.new("custom:meta-llama/Llama-3-70b",
    base_url: "https://api.together.xyz/v1",
    api_key: System.get_env("TOGETHER_API_KEY"),
    instructions: "Use tools when asked about weather.",
    tools: [get_weather]
  )

if System.get_env("TOGETHER_API_KEY") do
  case Nous.run(tool_agent, "What's the weather in Tokyo?") do
    {:ok, result} ->
      IO.puts("Response: #{result.output}")

    {:error, error} ->
      IO.puts("Error: #{inspect(error)}")
  end
else
  IO.puts("(Skipped - set TOGETHER_API_KEY to run this example)")
end

IO.puts("")

# ============================================================================
# Example 7: Backward Compatibility
# ============================================================================

IO.puts("--- Example 7: Backward Compatibility ---")

IO.puts("""
The legacy openai_compatible: prefix still works:

  # Legacy (backward compatible)
  Nous.new("openai_compatible:my-model", base_url: "...")

  # Recommended approach
  Nous.new("custom:my-model", base_url: "...")

Both create a model with provider: :custom
""")

# ============================================================================
# Summary
# ============================================================================

IO.puts("""
--- Summary ---

The custom: provider supports:
- Groq, Together AI, OpenRouter, and other cloud providers
- Local servers: LM Studio, Ollama, vLLM, SGLang
- Self-hosted OpenAI-compatible APIs

Configuration methods (precedence):
1. Direct options (Nous.new/2)
2. Environment variables (CUSTOM_BASE_URL, CUSTOM_API_KEY)
3. Application config (config :nous, :custom, ...)

For more details, see the Custom Providers guide:
  docs/guides/custom_providers.md
""")

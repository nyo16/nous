#!/usr/bin/env elixir

# Nous AI - Switching Providers
# Same code works with different AI providers

IO.puts("=== Nous AI - Provider Comparison ===\n")

# ============================================================================
# Provider-Agnostic Code
# ============================================================================

IO.puts("--- Provider-Agnostic Design ---")
IO.puts("""
Nous uses a unified API across all providers:

  agent = Nous.new("provider:model", ...)
  {:ok, result} = Nous.run(agent, prompt)

Provider string format: "provider:model-name"
""")

# ============================================================================
# Supported Providers
# ============================================================================

IO.puts("--- Supported Providers ---")
IO.puts("""
Provider          | Model Format                    | Env Variable
------------------|----------------------------------|-------------------
Anthropic         | anthropic:claude-sonnet-4-5-20250929    | ANTHROPIC_API_KEY
OpenAI            | openai:gpt-4                    | OPENAI_API_KEY
LM Studio (local) | lmstudio:model-name             | (none - local)
OpenAI-compatible | openai:model@base_url           | OPENAI_API_KEY
""")

# ============================================================================
# Same Prompt, Different Providers
# ============================================================================

IO.puts("--- Comparison Demo ---\n")

prompt = "What is Elixir? Answer in one sentence."
instructions = "Be concise and accurate."

# Define available providers based on env vars
providers = [
  if(System.get_env("ANTHROPIC_API_KEY"),
    do: {"Anthropic Claude", "anthropic:claude-sonnet-4-5-20250929", System.get_env("ANTHROPIC_API_KEY")}),
  if(System.get_env("OPENAI_API_KEY"),
    do: {"OpenAI GPT-4", "openai:gpt-4", System.get_env("OPENAI_API_KEY")}),
  {"LM Studio (local)", "lmstudio:qwen3", nil}
] |> Enum.filter(& &1)

if Enum.empty?(providers) do
  IO.puts("No API keys found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY to compare.")
  IO.puts("Trying local LM Studio only.\n")
end

# Test each provider
Enum.each(providers, fn {name, model, api_key} ->
  IO.puts("#{name}:")

  opts = [instructions: instructions]
  opts = if api_key, do: Keyword.put(opts, :api_key, api_key), else: opts

  agent = Nous.new(model, opts)

  start = System.monotonic_time(:millisecond)

  case Nous.run(agent, prompt) do
    {:ok, result} ->
      duration = System.monotonic_time(:millisecond) - start
      IO.puts("  Response: #{String.slice(result.output, 0..80)}...")
      IO.puts("  Tokens: #{result.usage.total_tokens}")
      IO.puts("  Time: #{duration}ms")

    {:error, error} ->
      IO.puts("  Error: #{inspect(error)}")
  end

  IO.puts("")
end)

# ============================================================================
# Environment-Based Provider Selection
# ============================================================================

IO.puts("--- Environment-Based Selection ---")
IO.puts("""
defmodule MyApp.AI do
  def get_agent do
    cond do
      System.get_env("ANTHROPIC_API_KEY") ->
        Nous.new("anthropic:claude-sonnet-4-5-20250929",
          api_key: System.get_env("ANTHROPIC_API_KEY")
        )

      System.get_env("OPENAI_API_KEY") ->
        Nous.new("openai:gpt-4",
          api_key: System.get_env("OPENAI_API_KEY")
        )

      true ->
        Nous.new("lmstudio:qwen3")  # Fallback to local
    end
  end
end
""")

# ============================================================================
# Config-Based Selection
# ============================================================================

IO.puts("--- Config-Based Selection ---")
IO.puts("""
# config/config.exs
config :my_app, :ai_provider,
  provider: System.get_env("AI_PROVIDER", "lmstudio"),
  model: System.get_env("AI_MODEL", "qwen3")

# In code
def get_agent do
  config = Application.get_env(:my_app, :ai_provider)
  model_string = "\#{config.provider}:\#{config.model}"
  Nous.new(model_string)
end
""")

# ============================================================================
# Provider Capabilities
# ============================================================================

IO.puts("--- Provider Capabilities ---")
IO.puts("""
Feature           | Anthropic | OpenAI | LM Studio
------------------|-----------|--------|----------
Streaming         | Yes       | Yes    | Yes
Tools/Functions   | Yes       | Yes    | Varies
Extended Thinking | Yes       | No     | No
Vision/Images     | Yes       | Yes    | Varies
Max Context       | 200K      | 128K   | Varies
Local/Private     | No        | No     | Yes

Choose based on your needs:
- Privacy: LM Studio
- Capability: Anthropic/OpenAI
- Cost: LM Studio (free) or gpt-3.5-turbo
""")

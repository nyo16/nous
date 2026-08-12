#!/usr/bin/env elixir

# Nous AI - Anthropic Claude
# Using Claude models via the Anthropic API

IO.puts("=== Nous AI - Anthropic Claude ===\n")

# Setup: export ANTHROPIC_API_KEY="sk-ant-..."
api_key = System.get_env("ANTHROPIC_API_KEY")

if is_nil(api_key) do
  IO.puts("ANTHROPIC_API_KEY not set!")
  IO.puts("Get your key from: https://console.anthropic.com/")
  System.halt(1)
end

# ============================================================================
# Basic Claude Usage
# ============================================================================

IO.puts("--- Basic Claude ---")

agent =
  Nous.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "Be helpful and concise."
  )

{:ok, result} = Nous.run(agent, "What is Elixir? One sentence.")
IO.puts("Response: #{result.output}")
IO.puts("Tokens: #{result.usage.total_tokens}\n")

# ============================================================================
# Model Options
# ============================================================================

IO.puts("--- Available Models ---")

IO.puts("""
  anthropic:claude-sonnet-4-5-20250929  - Best for most tasks
  anthropic:claude-opus-4-5-20250929    - Most capable
  anthropic:claude-haiku-3-5-20241022   - Fastest, cheapest
""")

# ============================================================================
# Thinking / Reasoning Configuration
# ============================================================================

IO.puts("--- Thinking Configuration ---")

# Nous does not expose an Anthropic-specific thinking setting. The only
# thinking knob in the library is Gemini/Vertex AI's `:thinking_config`
# model setting - see examples/providers/vertex_ai.exs and the
# `Nous.Providers.Gemini` docs:
#
#     Nous.new("vertex_ai:gemini-2.5-pro",
#       model_settings: %{thinking_config: %{thinking_budget: 1024, include_thoughts: true}}
#     )
IO.puts("""
Thinking configuration is a Gemini/Vertex AI feature in Nous
(model_settings: %{thinking_config: %{...}}).
See examples/providers/vertex_ai.exs.
""")

# ============================================================================
# Claude with Tools
# ============================================================================

IO.puts("--- Claude with Tools ---")

get_weather = fn _ctx, %{"city" => city} ->
  %{city: city, temperature: 22, conditions: "partly cloudy"}
end

tool_agent =
  Nous.new("anthropic:claude-sonnet-4-5-20250929",
    api_key: api_key,
    instructions: "Use tools when helpful.",
    tools: [get_weather]
  )

{:ok, result} = Nous.run(tool_agent, "What's the weather in Paris?")
IO.puts("Response: #{result.output}")
IO.puts("Tool calls: #{result.usage.tool_calls}\n")

# ============================================================================
# Long Context
# ============================================================================

IO.puts("--- Long Context ---")

# Claude supports up to 200K tokens context
long_text = String.duplicate("Elixir is great. ", 100)

{:ok, result} = Nous.run(agent, "Summarize this: #{long_text}")
IO.puts("Summarized #{String.length(long_text)} chars")
IO.puts("Response: #{result.output}\n")

# ============================================================================
# Streaming
# ============================================================================

IO.puts("--- Streaming ---")

{:ok, stream} = Nous.run_stream(agent, "Count from 1 to 5.")

stream
|> Enum.each(fn
  {:text_delta, text} -> IO.write(text)
  {:finish, _} -> IO.puts("\n")
  _ -> :ok
end)

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Choose the right model:
   - claude-sonnet-4-5-20250929: Balance of capability and speed
   - claude-opus-4-5-20250929: Complex reasoning
   - claude-haiku-3-5-20241022: High volume, simple tasks

2. Ask Claude to show its work in the prompt when you need step-by-step
   reasoning - there is no separate thinking toggle for this provider.

3. Claude excels at:
   - Following complex instructions
   - Long document analysis
   - Code generation
   - Creative writing
""")

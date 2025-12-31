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

agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
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
# Extended Thinking Mode
# ============================================================================

IO.puts("--- Extended Thinking ---")

thinking_agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
  api_key: api_key,
  instructions: "Think through problems carefully.",
  model_settings: %{
    extended_thinking: true,
    thinking_budget_tokens: 1000
  }
)

{:ok, result} = Nous.run(thinking_agent, "What is 15 * 7 + 23? Show your work.")
IO.puts("Response: #{result.output}")

# Access thinking (if available)
if result.thinking do
  IO.puts("Thinking: #{String.slice(result.thinking, 0..100)}...")
end
IO.puts("")

# ============================================================================
# Claude with Tools
# ============================================================================

IO.puts("--- Claude with Tools ---")

get_weather = fn _ctx, %{"city" => city} ->
  %{city: city, temperature: 22, conditions: "partly cloudy"}
end

tool_agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
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
stream |> Enum.each(fn
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

2. Use extended thinking for:
   - Math problems
   - Complex reasoning
   - Multi-step analysis

3. Claude excels at:
   - Following complex instructions
   - Long document analysis
   - Code generation
   - Creative writing
""")

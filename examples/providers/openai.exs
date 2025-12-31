#!/usr/bin/env elixir

# Nous AI - OpenAI GPT
# Using GPT models via the OpenAI API

IO.puts("=== Nous AI - OpenAI GPT ===\n")

# Setup: export OPENAI_API_KEY="sk-..."
api_key = System.get_env("OPENAI_API_KEY")

if is_nil(api_key) do
  IO.puts("OPENAI_API_KEY not set!")
  IO.puts("Get your key from: https://platform.openai.com/api-keys")
  System.halt(1)
end

# ============================================================================
# Basic GPT Usage
# ============================================================================

IO.puts("--- Basic GPT-4 ---")

agent = Nous.new("openai:gpt-4",
  api_key: api_key,
  instructions: "Be helpful and concise."
)

{:ok, result} = Nous.run(agent, "What is Phoenix Framework? One sentence.")
IO.puts("Response: #{result.output}")
IO.puts("Tokens: #{result.usage.total_tokens}\n")

# ============================================================================
# Model Options
# ============================================================================

IO.puts("--- Available Models ---")
IO.puts("""
  openai:gpt-4o          - Latest, most capable
  openai:gpt-4-turbo     - Fast, capable
  openai:gpt-4           - Original GPT-4
  openai:gpt-3.5-turbo   - Fast, economical
""")

# ============================================================================
# GPT with Tools (Function Calling)
# ============================================================================

IO.puts("--- Function Calling ---")

get_stock_price = fn _ctx, %{"symbol" => symbol} ->
  prices = %{"AAPL" => 185.50, "GOOGL" => 142.30, "MSFT" => 378.90}
  %{symbol: symbol, price: Map.get(prices, symbol, 100.00)}
end

calculate = fn _ctx, %{"expression" => expr} ->
  {result, _} = Code.eval_string(expr)
  %{result: result}
end

tool_agent = Nous.new("openai:gpt-4",
  api_key: api_key,
  instructions: "Use tools when helpful for stock prices or calculations.",
  tools: [get_stock_price, calculate]
)

{:ok, result} = Nous.run(tool_agent, "What's the price of AAPL stock?")
IO.puts("Response: #{result.output}")
IO.puts("Tool calls: #{result.usage.tool_calls}\n")

# ============================================================================
# Model Settings
# ============================================================================

IO.puts("--- Model Settings ---")

creative_agent = Nous.new("openai:gpt-4",
  api_key: api_key,
  instructions: "Be creative and imaginative.",
  model_settings: %{
    temperature: 0.9,       # Higher = more creative
    max_tokens: 500,
    top_p: 0.95,
    frequency_penalty: 0.5  # Reduce repetition
  }
)

{:ok, result} = Nous.run(creative_agent, "Write a haiku about programming.")
IO.puts("Response: #{result.output}\n")

# ============================================================================
# Streaming
# ============================================================================

IO.puts("--- Streaming ---")

{:ok, stream} = Nous.run_stream(agent, "List 3 benefits of Elixir.")
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
   - gpt-4o: Best overall, multimodal
   - gpt-4-turbo: Complex reasoning, large context
   - gpt-3.5-turbo: Simple tasks, high volume

2. Optimize costs:
   - Use gpt-3.5-turbo for simple tasks
   - Set max_tokens appropriately
   - Cache responses when possible

3. GPT excels at:
   - Function calling (tools)
   - Following structured output formats
   - General knowledge tasks
   - Code completion
""")

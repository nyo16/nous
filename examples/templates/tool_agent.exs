#!/usr/bin/env elixir

# Yggdrasil Agent with Tools Template
# Shows how to add function calling to your agent

# ============================================================================
# Tool Definitions - Add your custom functions here
# ============================================================================

defmodule MyTools do
  @moduledoc """
  Your custom tools for the agent to call.
  Each tool is an Elixir function that takes (context, args) parameters.
  """

  @doc """
  Get weather information for a location.
  This is a mock tool - replace with real API calls.
  """
  def get_weather(_ctx, %{"location" => location}) do
    # In real usage, call a weather API here
    case location do
      loc when loc in ["Paris", "paris"] ->
        "The weather in Paris is sunny and 22°C with light winds."
      loc when loc in ["Tokyo", "tokyo"] ->
        "The weather in Tokyo is rainy and 18°C with high humidity."
      loc when loc in ["New York", "new york", "NYC"] ->
        "The weather in New York is cloudy and 15°C with moderate winds."
      _ ->
        "The weather in #{location} is pleasant and mild."
    end
  end

  @doc """
  Calculate basic math operations.
  """
  def calculate(_ctx, %{"operation" => op, "a" => a, "b" => b}) do
    case op do
      "add" -> a + b
      "subtract" -> a - b
      "multiply" -> a * b
      "divide" when b != 0 -> a / b
      "divide" -> "Error: Division by zero"
      _ -> "Error: Unknown operation #{op}"
    end
  end

  @doc """
  Get current timestamp.
  """
  def get_time(_ctx, _args) do
    DateTime.utc_now()
    |> DateTime.to_string()
  end

  @doc """
  Search for information (mock implementation).
  Replace with real search API like Brave Search.
  """
  def search(_ctx, %{"query" => query}) do
    # Mock search results - replace with real search API
    "Search results for '#{query}': Found 3 relevant articles about #{query} from recent sources."
  end
end

# ============================================================================
# Configuration - Edit these values
# ============================================================================

# Choose your model
model = "lmstudio:qwen/qwen3-30b"

# Instructions that mention the tools
instructions = """
You are a helpful assistant with access to several tools.
Use the provided tools when appropriate to answer questions.

Available tools:
- get_weather: Get weather for any location
- calculate: Perform basic math operations (add, subtract, multiply, divide)
- get_time: Get current timestamp
- search: Search for information online

Call tools when the user asks questions that require them.
"""

# Your question/prompt that will trigger tool usage
prompt = "What's the weather in Paris? Also, what's 15 * 8?"

# List of tools to provide to the agent
tools = [
  &MyTools.get_weather/2,
  &MyTools.calculate/2,
  &MyTools.get_time/2,
  &MyTools.search/2
]

# ============================================================================
# Agent Creation and Execution
# ============================================================================

# Create the agent with tools
agent = Yggdrasil.new(model,
  instructions: instructions,
  tools: tools,
  model_settings: %{
    temperature: 0.7,
    max_tokens: -1
  }
)

# Run the agent
IO.puts("🔧 Running agent with #{length(tools)} tools available")
IO.puts("📝 Prompt: #{prompt}")
IO.puts("⏳ Thinking and using tools...")
IO.puts("")

case Yggdrasil.run(agent, prompt) do
  {:ok, result} ->
    IO.puts("✅ Response:")
    IO.puts(result.output)
    IO.puts("")

    # Show tool usage details
    if result.usage.tool_calls > 0 do
      IO.puts("🔧 Tools used:")
      IO.puts("  Tool calls: #{result.usage.tool_calls}")
      IO.puts("")
    end

    IO.puts("📊 Usage:")
    IO.puts("  Input tokens:  #{result.usage.input_tokens}")
    IO.puts("  Output tokens: #{result.usage.output_tokens}")
    IO.puts("  Total tokens:  #{result.usage.total_tokens}")

  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
    IO.puts("")
    IO.puts("💡 Tool calling troubleshooting:")
    IO.puts("  - Make sure your model supports function calling")
    IO.puts("  - Check that tool functions return simple data types")
    IO.puts("  - Verify tool function names and parameters")
end

# ============================================================================
# Tool Development Tips
# ============================================================================

# Tool function guidelines:
# 1. Take (context, args) parameters
# 2. Return simple data types (string, number, map, list)
# 3. Handle errors gracefully
# 4. Add @doc strings for clarity
#
# Example tool patterns:
#
# API calls:
# def call_api(_ctx, %{"query" => query}) do
#   HTTPoison.get!("https://api.example.com/search?q=#{query}")
#   |> Map.get(:body)
#   |> Jason.decode!()
# end
#
# Database queries:
# def get_user(_ctx, %{"id" => id}) do
#   MyApp.Repo.get(User, id)
#   |> Map.take([:name, :email])
# end
#
# File operations:
# def save_file(_ctx, %{"filename" => name, "content" => content}) do
#   File.write(name, content)
#   "File saved successfully"
# end

# ============================================================================
# Next Steps
# ============================================================================

# Ready for more advanced patterns?
# - streaming_agent.exs       (real-time responses)
# - conversation_agent.exs    (multi-turn chat with state)
# - ../by_feature/tools/      (more tool examples)
# - ../specialized/trading_desk/ (production multi-tool system)
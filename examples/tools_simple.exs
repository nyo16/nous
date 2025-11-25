#!/usr/bin/env elixir

# Simplest possible tool example

defmodule SimpleTools do
  @doc "Get the current weather (fake for demo)"
  def get_weather(_ctx, args) do
    # Handle both map with location key or empty args
    location = case args do
      %{"location" => loc} -> loc
      _ -> "Paris"  # Default
    end

    "The weather in #{location} is sunny and 72°F"
  end
end

# Create agent with tool
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "You can check the weather. Use the get_weather tool when asked.",
  tools: [&SimpleTools.get_weather/2]
)

# Ask about weather
IO.puts("Asking: What's the weather in Paris?\n")

{:ok, result} = Yggdrasil.run(agent, "What's the weather in Paris?")

IO.puts("Response: #{result.output}")
IO.puts("\nTool calls made: #{result.usage.tool_calls}")

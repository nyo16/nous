#!/usr/bin/env elixir

# Example: Using Anthropic Claude with Tools
#
# This demonstrates Claude's native function calling capability
# using the Anthropix library.

IO.puts("\n🤖 Anthropic Claude - Tool Calling Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Check for API key
api_key = System.get_env("ANTHROPIC_API_KEY")

if is_nil(api_key) do
  IO.puts("❌ ANTHROPIC_API_KEY not set!")
  IO.puts("Please export your key: export ANTHROPIC_API_KEY='sk-ant-...'")
  System.halt(1)
end

# Define tools
defmodule WeatherTools do
  @doc "Get current weather for a city"
  def get_weather(_ctx, args) do
    city = Map.get(args, "city", "Unknown")
    IO.puts("  🌤️  Tool called: get_weather(#{city})")

    # Return fake weather data
    %{
      city: city,
      temperature: "72°F",
      condition: "Sunny",
      humidity: "45%"
    }
  end

  @doc "Get weather forecast for next 3 days"
  def get_forecast(_ctx, args) do
    city = Map.get(args, "city", "Unknown")
    IO.puts("  📅 Tool called: get_forecast(#{city})")

    # Return fake forecast
    %{
      city: city,
      forecast: [
        %{day: "Tomorrow", temp: "75°F", condition: "Partly Cloudy"},
        %{day: "Day 2", temp: "70°F", condition: "Rainy"},
        %{day: "Day 3", temp: "68°F", condition: "Sunny"}
      ]
    }
  end
end

# Create agent with tools
IO.puts("Creating Claude agent with weather tools...")

agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
  api_key: api_key,
  instructions: """
  You are a helpful weather assistant.
  Use the provided tools to get weather information.
  Always be friendly and explain what you're doing.
  """,
  tools: [
    &WeatherTools.get_weather/2,
    &WeatherTools.get_forecast/2
  ],
  model_settings: %{
    max_tokens: 1000,
    temperature: 0.7
  }
)

IO.puts("Agent ready with #{length(agent.tools)} tools\n")

# Test 1: Current weather
IO.puts("Test 1: What's the weather in Paris?")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "What's the current weather in Paris?") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nClaude's Response:")
    IO.puts(result.output)
    IO.puts("\n📊 Stats:")
    IO.puts("  Tool calls: #{result.usage.tool_calls}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
end

IO.puts("\n" <> ("=" |> String.duplicate(70)))
IO.puts("")

# Test 2: Forecast
IO.puts("Test 2: What's the forecast for London?")
IO.puts("-" |> String.duplicate(70))

case Nous.run(agent, "Can you give me the weather forecast for London?") do
  {:ok, result} ->
    IO.puts("\n✅ Success!")
    IO.puts("\nClaude's Response:")
    IO.puts(result.output)
    IO.puts("\n📊 Stats:")
    IO.puts("  Tool calls: #{result.usage.tool_calls}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("\n❌ Error:")
    IO.puts(inspect(error, pretty: true))
end

IO.puts("\n" <> ("=" |> String.duplicate(70)))
IO.puts("🎉 Claude autonomously decided which tools to call!")
IO.puts("")

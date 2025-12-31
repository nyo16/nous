#!/usr/bin/env elixir

# Nous AI - Tool Testing Helpers (v0.8.0)
# Mock tools, spy tools, and test utilities

IO.puts("=== Nous AI - Tool Testing Demo ===\n")

alias Nous.Tool.Testing

# ============================================================================
# Mock Tools - Return Fixed Results
# ============================================================================

IO.puts("--- Mock Tools ---")

# Create a mock tool that always returns the same result
search_mock = Testing.mock_tool("search", %{
  results: ["Elixir is a functional language", "Phoenix is a web framework"]
})

IO.puts("Created mock tool: #{search_mock.name}")
IO.puts("Mock returns: #{inspect(search_mock.function.(nil, %{}))}")
IO.puts("")

# Use mock in agent
agent = Nous.new("lmstudio:qwen3",
  instructions: "You have a search tool. Use it to answer questions.",
  tools: [search_mock]
)

IO.puts("Agent with mock tool:")
{:ok, result} = Nous.run(agent, "Search for Elixir")
IO.puts("Response: #{result.output}")
IO.puts("")

# ============================================================================
# Spy Tools - Record All Calls
# ============================================================================

IO.puts("--- Spy Tools ---")

# Create a spy tool that records all calls
{database_spy, spy_agent} = Testing.spy_tool("query_database",
  result: %{records: [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]}
)

IO.puts("Created spy tool: #{database_spy.name}")

# Use spy in agent
agent2 = Nous.new("lmstudio:qwen3",
  instructions: "You have a database query tool.",
  tools: [database_spy]
)

{:ok, _} = Nous.run(agent2, "List all users from the database")

# Check recorded calls
calls = Testing.get_calls(spy_agent)
IO.puts("Spy recorded #{length(calls)} call(s):")
Enum.each(calls, fn {_ctx, args} ->
  IO.puts("  Arguments: #{inspect(args)}")
end)
IO.puts("")

# ============================================================================
# Test Context Helper
# ============================================================================

IO.puts("--- Test Context ---")

# Create a context with test dependencies
test_ctx = Testing.test_context(%{
  user: %{id: 123, name: "Test User"},
  api_key: "test-key-12345",
  database: %{connected: true}
})

IO.puts("Test context deps: #{inspect(test_ctx.deps)}")
IO.puts("")

# ============================================================================
# Asserting Tool Calls
# ============================================================================

IO.puts("--- Assertions Example ---")

# Create spy and run agent
{calc_spy, calc_agent} = Testing.spy_tool("calculate",
  result: %{result: 42}
)

agent3 = Nous.new("lmstudio:qwen3",
  instructions: "You have a calculator. Use it for math.",
  tools: [calc_spy]
)

{:ok, _} = Nous.run(agent3, "What is 6 times 7?")

# Assert tool was called
calls = Testing.get_calls(calc_agent)
called? = Testing.called?(calc_agent)
IO.puts("Tool was called: #{called?}")

if called? do
  # Check arguments
  {_ctx, args} = List.first(calls)
  IO.puts("Arguments passed: #{inspect(args)}")
end
IO.puts("")

# ============================================================================
# Multiple Spies
# ============================================================================

IO.puts("--- Multiple Spies ---")

{search_spy, search_agent} = Testing.spy_tool("search", result: %{results: []})
{weather_spy, weather_agent} = Testing.spy_tool("get_weather", result: %{temp: 72})

multi_agent = Nous.new("lmstudio:qwen3",
  instructions: "You have search and weather tools.",
  tools: [search_spy, weather_spy]
)

{:ok, _} = Nous.run(multi_agent, "Search for weather forecast and tell me the current temp")

IO.puts("Search called: #{Testing.called?(search_agent)} (#{Testing.call_count(search_agent)} times)")
IO.puts("Weather called: #{Testing.called?(weather_agent)} (#{Testing.call_count(weather_agent)} times)")
IO.puts("")

# ============================================================================
# Testing Pattern
# ============================================================================

IO.puts("""
--- Testing Pattern in ExUnit ---

defmodule MyAgentTest do
  use ExUnit.Case
  alias Nous.Tool.Testing

  test "agent uses search tool for queries" do
    {search_spy, spy_agent} = Testing.spy_tool("search",
      result: %{results: ["Found: Elixir"]}
    )

    agent = Nous.new("openai:gpt-4", tools: [search_spy])
    {:ok, result} = Nous.run(agent, "Search for Elixir")

    # Assertions
    assert Testing.called?(spy_agent)
    assert Testing.call_count(spy_agent) >= 1

    calls = Testing.get_calls(spy_agent)
    {_ctx, args} = hd(calls)
    assert args["query"] =~ "Elixir"

    assert result.output =~ "Found"
  end

  test "tool receives correct context" do
    {spy, spy_agent} = Testing.spy_tool("user_lookup")

    agent = Nous.new("openai:gpt-4", tools: [spy])
    {:ok, _} = Nous.run(agent, "Look up my profile",
      deps: %{user_id: 123}
    )

    [{ctx, _args}] = Testing.get_calls(spy_agent)
    assert ctx.deps.user_id == 123
  end
end
""")

IO.puts("Next: mix run examples/09_agent_server.exs")

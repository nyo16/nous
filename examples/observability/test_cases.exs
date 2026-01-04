#!/usr/bin/env elixir

# Nous Observability - Test Cases
# Run with: mix run examples/observability/test_cases.exs
# Make sure nous_ui is running at http://localhost:4000

IO.puts("=== Observability Test Cases ===\n")

# Enable observability with global metadata
Nous.Observability.enable(
  endpoint: "http://localhost:4000/api/telemetry",
  metadata: %{environment: "testing", app_version: "1.0.0"}
)

# Helper to run a test case with metadata
run_test = fn name, agent, prompt, metadata ->
  IO.puts("--- #{name} ---")
  Nous.Observability.set_run_metadata(metadata)

  case Nous.run(agent, prompt) do
    {:ok, result} ->
      output_preview = String.slice(result.output || "", 0, 100)
      IO.puts("Success: #{output_preview}...")
      IO.puts("Tokens: #{result.usage.total_tokens}, Tools: #{result.usage.tool_calls}")
    {:error, reason} ->
      IO.puts("Error: #{inspect(reason)}")
  end
  IO.puts("")
end

# ============================================================================
# Test Case 1: Simple Agent (No Tools)
# Purpose: Verify basic trace/span capture with user metadata
# Expected: Trace with agent_run span, iteration span, llm_call span
# ============================================================================
IO.puts("\n========== Test Case 1: Simple Agent ==========")

agent1 = Nous.new("lmstudio:qwen3",
  name: "Simple Chat",
  instructions: "You are a helpful assistant. Be very brief in your responses."
)

run_test.("Simple Agent - Basic Q&A", agent1, "What is 2+2? Just give the number.", %{
  user_id: "user_001",
  session_id: "sess_A",
  test_case: "simple_agent"
})

# ============================================================================
# Test Case 2: Agent with Single Tool Call
# Purpose: Verify tool execution capture with input/output
# Expected: Tool span with input args and output result
# ============================================================================
IO.puts("\n========== Test Case 2: Single Tool Call ==========")

get_weather = fn _ctx, %{"city" => city} ->
  Process.sleep(100) # Simulate API latency
  %{
    city: city,
    temperature: 22,
    conditions: "sunny",
    humidity: 65
  }
end

agent2 = Nous.new("lmstudio:qwen3",
  name: "Weather Bot",
  instructions: "You are a weather assistant. Use the get_weather tool to answer weather questions. Be brief.",
  tools: [get_weather]
)

run_test.("Single Tool - Weather Query", agent2, "What's the weather in Tokyo?", %{
  user_id: "user_002",
  session_id: "sess_B",
  test_case: "single_tool"
})

# ============================================================================
# Test Case 3: Agent with Multiple Tools
# Purpose: Verify multiple tool spans under same iteration
# Expected: Multiple tool spans, each with their own input/output
# ============================================================================
IO.puts("\n========== Test Case 3: Multiple Tools ==========")

get_time = fn _ctx, %{"timezone" => tz} ->
  Process.sleep(50)
  %{
    timezone: tz,
    time: DateTime.utc_now() |> DateTime.to_string(),
    offset: "+09:00"
  }
end

calculate = fn _ctx, %{"expression" => expr} ->
  # Simple safe evaluation
  result = case expr do
    "15 * 7" -> 105
    "100 / 4" -> 25
    _ -> "unknown"
  end
  %{expression: expr, result: result}
end

agent3 = Nous.new("lmstudio:qwen3",
  name: "Multi-Tool Bot",
  instructions: "You have access to weather, time, and calculator tools. Use them when appropriate. Be brief.",
  tools: [get_weather, get_time, calculate]
)

run_test.("Multiple Tools - Weather and Time", agent3, "What's the weather in Paris and the current time in Europe/Paris timezone?", %{
  user_id: "user_003",
  session_id: "sess_C",
  test_case: "multiple_tools"
})

# ============================================================================
# Test Case 4: Conversational Agent
# Purpose: Verify message capture in trace
# Expected: Full message history (system, user, assistant) captured
# ============================================================================
IO.puts("\n========== Test Case 4: Conversational ==========")

agent4 = Nous.new("lmstudio:qwen3",
  name: "Conversational Bot",
  instructions: "You are a friendly assistant that tells short jokes. Keep jokes to 1-2 sentences."
)

run_test.("Conversational - Tell a Joke", agent4, "Tell me a short programming joke", %{
  user_id: "user_004",
  session_id: "sess_D",
  test_case: "conversational"
})

# ============================================================================
# Test Case 5: Error Handling - Tool Failure
# Purpose: Verify error capture with stacktrace
# Expected: Error span with type, message, and stacktrace
# ============================================================================
IO.puts("\n========== Test Case 5: Error Handling ==========")

failing_tool = fn _ctx, _args ->
  raise RuntimeError, message: "Simulated tool failure for testing!"
end

agent5 = Nous.new("lmstudio:qwen3",
  name: "Error Test Agent",
  instructions: "You have a tool that might fail. Use it when asked.",
  tools: [failing_tool]
)

IO.puts("--- Error Handling - Tool Failure ---")
Nous.Observability.set_run_metadata(%{
  user_id: "user_005",
  session_id: "sess_E",
  test_case: "error_handling"
})

# This will likely fail, which is what we want to test
result = try do
  Nous.run(agent5, "Please use the failing_tool")
rescue
  e ->
    IO.puts("Caught expected error: #{Exception.message(e)}")
    {:error, :expected_failure}
catch
  :exit, reason ->
    IO.puts("Caught exit: #{inspect(reason)}")
    {:error, :exit}
end

IO.puts("Result: #{inspect(result)}")
IO.puts("")

# ============================================================================
# Test Case 6: Production-like Environment
# Purpose: Verify rich metadata propagation
# Expected: All metadata fields visible in UI (user_id, session_id, environment, custom tags)
# ============================================================================
IO.puts("\n========== Test Case 6: Production Environment ==========")

agent6 = Nous.new("lmstudio:qwen3",
  name: "Production Agent",
  instructions: "You are a production assistant. Be helpful and professional. Keep responses brief.",
  tools: [get_weather]
)

run_test.("Production - Rich Metadata", agent6, "What's the weather in London?", %{
  user_id: "prod_user_100",
  session_id: "prod_sess_XYZ",
  environment: "production",
  customer_tier: "premium",
  request_source: "web_app",
  feature_flags: ["new_ui", "beta_features"]
})

# ============================================================================
# Summary and Cleanup
# ============================================================================
IO.puts("\n=== Waiting for telemetry to flush (5 seconds) ===")
Process.sleep(5000)

IO.puts("""

=== Test Summary ===
6 test cases executed:
1. Simple Agent - Basic trace/span structure
2. Single Tool - Tool input/output capture
3. Multiple Tools - Multiple tool spans
4. Conversational - Message capture
5. Error Handling - Error with stacktrace
6. Production Env - Rich metadata

=== Check Results ===
Open http://localhost:4000 to view:
- Dashboard should show 6 new traces
- Each trace should have user_id and session_id
- Span details should show input/output data
- Error test should show stacktrace in error field
""")

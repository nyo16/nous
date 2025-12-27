#!/usr/bin/env elixir

# Telemetry Demo - Shows all telemetry events being emitted

IO.puts("\n📊 Nous AI - Telemetry Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Attach telemetry handler to see all events
:telemetry.attach_many(
  "telemetry-demo",
  [
    [:nous, :agent, :run, :start],
    [:nous, :agent, :run, :stop],
    [:nous, :agent, :run, :exception],
    [:nous, :model, :request, :start],
    [:nous, :model, :request, :stop],
    [:nous, :model, :request, :exception],
    [:nous, :tool, :execute, :start],
    [:nous, :tool, :execute, :stop],
    [:nous, :tool, :execute, :exception]
  ],
  fn event, measurements, metadata, _config ->
    event_name = Enum.join(event, ".")
    duration_ms = if measurements[:duration] do
      System.convert_time_unit(measurements[:duration], :native, :millisecond)
    else
      nil
    end

    IO.puts("\n📡 Event: #{event_name}")

    if duration_ms do
      IO.puts("   Duration: #{duration_ms}ms")
    end

    if measurements[:total_tokens] do
      IO.puts("   Tokens: #{measurements[:total_tokens]} (in: #{measurements[:input_tokens]}, out: #{measurements[:output_tokens]})")
    end

    if measurements[:tool_calls] do
      IO.puts("   Tool calls: #{measurements[:tool_calls]}")
    end

    if metadata[:tool_name] do
      IO.puts("   Tool: #{metadata[:tool_name]}")
    end

    if metadata[:agent_name] do
      IO.puts("   Agent: #{metadata[:agent_name]}")
    end

    if metadata[:model_provider] do
      IO.puts("   Model: #{metadata[:model_provider]}:#{metadata[:model_name]}")
    end
  end,
  nil
)

IO.puts("✓ Telemetry handler attached")
IO.puts("✓ Watching for events...")
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 1: Simple agent run
IO.puts("Test 1: Simple Agent Run")
IO.puts("-" |> String.duplicate(70))

agent = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Be very brief"
)

{:ok, result} = Nous.run(agent, "What is 2+2? Just the number.")

IO.puts("\nFinal result: #{result.output}")

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Test 2: Agent with tools
IO.puts("Test 2: Agent with Tools")
IO.puts("-" |> String.duplicate(70))

defmodule DemoTools do
  def add(_ctx, args) do
    x = Map.get(args, "x", 0)
    y = Map.get(args, "y", 0)
    x + y
  end
end

agent_with_tools = Nous.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Use the add tool",
  tools: [&DemoTools.add/2]
)

{:ok, result2} = Nous.run(agent_with_tools, "What is 5 + 3?")

IO.puts("\nFinal result: #{result2.output}")

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("✅ Demo complete!")
IO.puts("")
IO.puts("Summary of telemetry events you saw:")
IO.puts("  • nous.agent.run.start - When agent starts")
IO.puts("  • nous.model.request.start - Before API call")
IO.puts("  • nous.model.request.stop - After API responds")
IO.puts("  • nous.tool.execute.start - Before tool runs")
IO.puts("  • nous.tool.execute.stop - After tool completes")
IO.puts("  • nous.agent.run.stop - When agent finishes")
IO.puts("")
IO.puts("All events include:")
IO.puts("  ✓ Tool names (when applicable)")
IO.puts("  ✓ Duration in milliseconds")
IO.puts("  ✓ Token counts")
IO.puts("  ✓ Model provider and name")
IO.puts("  ✓ Success/failure status")
IO.puts("")

# Detach handler
:telemetry.detach("telemetry-demo")

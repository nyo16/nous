#!/usr/bin/env elixir

# Nous AI - Telemetry
# Observability and metrics for AI agents

IO.puts("=== Nous AI - Telemetry Demo ===\n")

# ============================================================================
# Attach Custom Handler
# ============================================================================

IO.puts("--- Custom Telemetry Handler ---")

:telemetry.attach_many(
  "demo-handler",
  [
    [:nous, :agent, :run, :start],
    [:nous, :agent, :run, :stop],
    [:nous, :agent, :iteration, :start],
    [:nous, :agent, :iteration, :stop],
    [:nous, :provider, :request, :start],
    [:nous, :provider, :request, :stop],
    [:nous, :tool, :execute, :start],
    [:nous, :tool, :execute, :stop],
    [:nous, :tool, :timeout]
  ],
  fn event, measurements, metadata, _config ->
    event_name = Enum.join(event, ".")

    duration = if measurements[:duration] do
      "#{System.convert_time_unit(measurements[:duration], :native, :millisecond)}ms"
    else
      nil
    end

    IO.puts("[#{event_name}] #{inspect_metadata(metadata)} #{duration || ""}")
  end,
  nil
)

defp inspect_metadata(metadata) do
  cond do
    metadata[:agent_name] -> "agent=#{metadata[:agent_name]}"
    metadata[:tool_name] -> "tool=#{metadata[:tool_name]}"
    metadata[:provider] -> "provider=#{metadata[:provider]}"
    true -> ""
  end
end

IO.puts("Handler attached. Running agent...\n")

# ============================================================================
# Test Agent Run
# ============================================================================

get_time = fn _ctx, _args ->
  %{time: DateTime.utc_now() |> DateTime.to_string()}
end

agent = Nous.new("lmstudio:qwen3",
  name: "demo-agent",
  instructions: "You have a time tool.",
  tools: [get_time]
)

{:ok, result} = Nous.run(agent, "What time is it?")

IO.puts("\nResult: #{result.output}")
IO.puts("")

# ============================================================================
# Default Handler
# ============================================================================

IO.puts("--- Default Handler ---")
IO.puts("""
Nous provides a built-in handler for development:

  Nous.Telemetry.attach_default_handler()

This logs events at appropriate levels:
  - Agent runs: info
  - Provider requests: debug
  - Tool executions: debug
  - Exceptions: error
""")

# ============================================================================
# Available Events
# ============================================================================

IO.puts("--- Available Events ---")
IO.puts("""
Agent Events:
  [:nous, :agent, :run, :start]       - Agent execution starts
  [:nous, :agent, :run, :stop]        - Agent execution completes
  [:nous, :agent, :run, :exception]   - Agent execution failed
  [:nous, :agent, :iteration, :start] - Iteration starts
  [:nous, :agent, :iteration, :stop]  - Iteration completes

Provider Events:
  [:nous, :provider, :request, :start]      - API request starts
  [:nous, :provider, :request, :stop]       - API request completes
  [:nous, :provider, :request, :exception]  - API request failed
  [:nous, :provider, :stream, :start]       - Stream starts
  [:nous, :provider, :stream, :chunk]       - Stream chunk received
  [:nous, :provider, :stream, :connected]   - Stream connected

Tool Events:
  [:nous, :tool, :execute, :start]     - Tool execution starts
  [:nous, :tool, :execute, :stop]      - Tool execution completes
  [:nous, :tool, :execute, :exception] - Tool execution failed
  [:nous, :tool, :timeout]             - Tool timed out

Context Events:
  [:nous, :context, :update]    - Context modified by tool
  [:nous, :callback, :execute]  - Callback executed
""")

# ============================================================================
# Metrics Integration
# ============================================================================

IO.puts("--- Metrics Integration ---")
IO.puts("""
For production metrics, use telemetry_metrics:

  defmodule MyApp.Telemetry do
    import Telemetry.Metrics

    def metrics do
      [
        # Count agent runs
        counter("nous.agent.run.start.count"),

        # Track duration distribution
        distribution("nous.agent.run.stop.duration",
          unit: {:native, :millisecond}
        ),

        # Sum total tokens
        sum("nous.agent.run.stop.total_tokens"),

        # Count by tool name
        counter("nous.tool.execute.stop.count",
          tags: [:tool_name]
        ),

        # Track timeouts
        counter("nous.tool.timeout.count",
          tags: [:tool_name]
        )
      ]
    end
  end

Works with:
  - Prometheus (via telemetry_metrics_prometheus)
  - StatsD (via telemetry_metrics_statsd)
  - Phoenix LiveDashboard
""")

# ============================================================================
# Cost Tracking
# ============================================================================

IO.puts("--- Cost Tracking ---")

defmodule CostTracker do
  use Agent

  def start_link, do: Agent.start_link(fn -> %{total_tokens: 0, requests: 0} end, name: __MODULE__)
  def get_stats, do: Agent.get(__MODULE__, & &1)

  def handle_event([:nous, :agent, :run, :stop], measurements, _metadata, _config) do
    Agent.update(__MODULE__, fn state ->
      %{
        state |
        total_tokens: state.total_tokens + measurements.total_tokens,
        requests: state.requests + 1
      }
    end)
  end
  def handle_event(_, _, _, _), do: :ok
end

CostTracker.start_link()
:telemetry.attach("cost-tracker", [:nous, :agent, :run, :stop], &CostTracker.handle_event/4, nil)

# Run some requests
{:ok, _} = Nous.run(agent, "Hello")
{:ok, _} = Nous.run(agent, "What is 2+2?")

stats = CostTracker.get_stats()
IO.puts("Cost tracking:")
IO.puts("  Total tokens: #{stats.total_tokens}")
IO.puts("  Total requests: #{stats.requests}")

# Detach handlers
:telemetry.detach("demo-handler")
:telemetry.detach("cost-tracker")

#!/usr/bin/env elixir

# Cancellation Demo
#
# This example demonstrates how to cancel agent execution mid-run.
#
# Run with: mix run examples/cancellation_demo.exs

defmodule CancellationDemo do
  alias Nous.{Agent, Tool}
  require Logger

  # A slow tool that simulates long-running work
  def slow_search(_ctx, %{"query" => query}) do
    IO.puts("\n🔍 Starting search for: #{query}")
    IO.puts("   This will take 10 seconds...")

    # Sleep in small increments so cancellation can interrupt
    Enum.each(1..10, fn i ->
      Process.sleep(1000)
      IO.puts("   ... #{i} seconds elapsed")
    end)

    "Search results for #{query}"
  end

  def slow_analyze(_ctx, %{"data" => data}) do
    IO.puts("\n📊 Analyzing data: #{data}")
    IO.puts("   This will take 8 seconds...")

    Enum.each(1..8, fn i ->
      Process.sleep(1000)
      IO.puts("   ... #{i} seconds elapsed")
    end)

    "Analysis complete for #{data}"
  end

  def run do
    IO.puts("""
    ╔═══════════════════════════════════════════════════════════╗
    ║           Agent Cancellation Demo                         ║
    ╚═══════════════════════════════════════════════════════════╝

    This demo shows how to cancel agent execution mid-run.

    We'll start an agent that calls slow tools, then cancel it.
    """)

    # Create agent with slow tools
    agent = Agent.new("lmstudio:qwen/qwen3-30b",
      instructions: "You are a research assistant. Use tools to gather information.",
      tools: [
        Tool.from_function(&slow_search/2,
          name: "search",
          description: "Search for information (takes 10 seconds)"
        ),
        Tool.from_function(&slow_analyze/2,
          name: "analyze",
          description: "Analyze data (takes 8 seconds)"
        )
      ],
      model_settings: %{temperature: 0.7, max_tokens: 500}
    )

    # Start agent in background using Task
    IO.puts("\n🚀 Starting agent run...")
    IO.puts("   (Will call slow tools)\n")

    task = Task.async(fn ->
      # This run will be cancelled
      result = Agent.run(agent,
        "Search for 'Elixir programming' and then analyze the results",
        max_iterations: 15
      )

      case result do
        {:ok, response} ->
          IO.puts("\n✅ Agent completed:")
          IO.puts("   #{response.output}")

        {:error, %Nous.Errors.ExecutionCancelled{reason: reason}} ->
          IO.puts("\n🛑 Agent was cancelled: #{reason}")

        {:error, error} ->
          IO.puts("\n❌ Agent failed: #{Exception.message(error)}")
      end
    end)

    # Let it run for 3 seconds
    Process.sleep(3000)

    # Cancel by shutting down the task
    IO.puts("\n\n⏸️  Cancelling execution after 3 seconds...\n")
    Task.shutdown(task, 5_000)

    IO.puts("""

    ✅ Task cancelled successfully!

    The agent was interrupted mid-execution, demonstrating:
    - Task tracking via Task.async
    - Graceful shutdown with timeout
    - Cleanup of resources

    Note: For AgentServer (GenServer-based), use:
      AgentServer.cancel_execution(pid)

    This provides:
    - Cancellation flag checking at each iteration
    - Broadcast of cancellation event
    - Proper state cleanup
    """)

    IO.puts("""

    ╔═══════════════════════════════════════════════════════════╗
    ║  Alternative: Using AgentServer with cancellation         ║
    ╚═══════════════════════════════════════════════════════════╝

    For production use with LiveView or GenServer:

    1. Start AgentServer:
       {:ok, pid} = AgentServer.start_link(
         session_id: "demo-123",
         agent_config: %{
           model: "lmstudio:qwen/qwen3-30b",
           instructions: "You are a helpful assistant",
           tools: [...]
         }
       )

    2. Send message (starts execution):
       AgentServer.send_message(pid, "Do something...")

    3. Cancel mid-execution:
       AgentServer.cancel_execution(pid)
       # Returns: {:ok, :cancelled}

    4. Listen for cancellation event:
       # In your LiveView or GenServer:
       def handle_info({:agent_cancelled, reason}, state) do
         # Handle cancellation
         {:noreply, state}
       end

    The AgentServer approach provides:
    - Automatic task tracking
    - PubSub broadcasting of events
    - Conversation history management
    - Graceful cancellation with cleanup
    """)
  end
end

# Run the demo
CancellationDemo.run()

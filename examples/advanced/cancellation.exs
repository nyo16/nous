#!/usr/bin/env elixir

# Nous AI - Cancellation
# Stopping agent execution mid-run

IO.puts("=== Nous AI - Cancellation ===\n")

# ============================================================================
# Basic Task Cancellation
# ============================================================================

IO.puts("--- Basic Task Cancellation ---")

defmodule SlowTools do
  def slow_search(_ctx, %{"query" => query}) do
    IO.puts("  Starting search for: #{query}")
    IO.puts("  This takes 10 seconds...")

    Enum.each(1..10, fn i ->
      Process.sleep(1000)
      IO.puts("  ... #{i} seconds elapsed")
    end)

    %{query: query, results: ["Result 1", "Result 2"]}
  end
end

agent = Nous.new("lmstudio:qwen3",
  instructions: "You are a research assistant. Use tools to gather information.",
  tools: [&SlowTools.slow_search/2]
)

IO.puts("Starting agent in background task...")

task = Task.async(fn ->
  Nous.run(agent, "Search for 'Elixir programming'")
end)

# Let it run for 3 seconds
Process.sleep(3000)

IO.puts("\nCancelling after 3 seconds...")
Task.shutdown(task, :brutal_kill)

IO.puts("Task cancelled.\n")

# ============================================================================
# Graceful Cancellation with Timeout
# ============================================================================

IO.puts("--- Graceful Cancellation ---")
IO.puts("""
Use Task.shutdown with timeout for cleanup:

  task = Task.async(fn -> Nous.run(agent, message) end)

  # Allow 5 seconds for graceful shutdown
  case Task.shutdown(task, 5_000) do
    {:ok, result} ->
      # Task completed before shutdown
      handle_result(result)

    nil ->
      # Task was killed after timeout
      IO.puts("Task was forcefully terminated")
  end
""")

# ============================================================================
# Streaming Cancellation
# ============================================================================

IO.puts("--- Streaming Cancellation ---")
IO.puts("""
For streaming, you can stop early by breaking from the stream:

  {:ok, stream} = Nous.run_stream(agent, message)

  stream
  |> Stream.take_while(fn
    {:text_delta, text} ->
      IO.write(text)
      String.length(text) < 1000  # Stop after 1000 chars

    {:finish, _} ->
      false  # Always stop on finish

    _ ->
      true
  end)
  |> Stream.run()
""")

# ============================================================================
# AgentServer Cancellation
# ============================================================================

IO.puts("--- AgentServer Cancellation ---")
IO.puts("""
For production apps, use AgentServer with built-in cancellation:

  # Start server
  {:ok, pid} = Nous.AgentServer.start_link(
    session_id: "user-123",
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You are helpful."
    }
  )

  # Send message (starts execution)
  Nous.AgentServer.send_message(pid, "Do something complex...")

  # Cancel mid-execution
  :ok = Nous.AgentServer.cancel(pid)

  # Handle cancellation event
  def handle_info({:agent_cancelled, reason}, state) do
    IO.puts("Cancelled: #{reason}")
    {:noreply, state}
  end
""")

# ============================================================================
# LiveView Cancellation
# ============================================================================

IO.puts("--- LiveView Cancellation ---")
IO.puts("""
In Phoenix LiveView, track the task reference:

  def handle_event("send", %{"message" => msg}, socket) do
    task = Task.async(fn ->
      Nous.run(socket.assigns.agent, msg, notify_pid: socket.root_pid)
    end)

    {:noreply, assign(socket, current_task: task, streaming: true)}
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns[:current_task] do
      Task.shutdown(socket.assigns.current_task, :brutal_kill)
    end

    {:noreply, assign(socket,
      current_task: nil,
      streaming: false
    )}
  end

  # In template:
  <%= if @streaming do %>
    <button phx-click="cancel">Stop</button>
  <% end %>
""")

# ============================================================================
# Cancellation Check in Tools
# ============================================================================

IO.puts("--- Cancellation Check in Tools ---")
IO.puts("""
For long-running tools, check for cancellation periodically:

  def long_running_tool(ctx, args) do
    Enum.reduce_while(1..100, %{}, fn i, acc ->
      # Check if cancelled
      if Process.get(:cancelled) do
        {:halt, {:error, :cancelled}}
      else
        Process.sleep(100)
        {:cont, Map.put(acc, i, process_item(i))}
      end
    end)
  end

Or use a cancellation token pattern:

  def tool_with_token(ctx, args) do
    cancel_ref = ctx.deps[:cancel_ref]

    Enum.reduce_while(items, [], fn item, acc ->
      receive do
        {:cancel, ^cancel_ref} -> {:halt, {:error, :cancelled}}
      after
        0 ->
          result = process(item)
          {:cont, [result | acc]}
      end
    end)
  end
""")

# ============================================================================
# Timeout vs Cancellation
# ============================================================================

IO.puts("--- Timeout vs Cancellation ---")
IO.puts("""
Timeouts are automatic, cancellation is manual:

  Timeout (automatic):
    agent = Nous.new("openai:gpt-4", timeout: 30_000)
    {:error, :timeout} = Nous.run(agent, message)

  Cancellation (manual):
    task = Task.async(fn -> Nous.run(agent, message) end)
    # Later...
    Task.shutdown(task, :brutal_kill)

Use timeouts for:
  - Preventing runaway requests
  - SLA compliance
  - Resource management

Use cancellation for:
  - User-initiated stop
  - Conditional abort
  - Interactive UIs
""")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Use Task.async for cancellable operations:
   - Provides clean cancellation API
   - Handles cleanup automatically

2. Choose appropriate shutdown mode:
   - :brutal_kill - Immediate termination
   - timeout_ms - Allow graceful cleanup
   - :infinity - Wait forever (not recommended)

3. Save partial results when appropriate:
   - Store streaming output before cancel
   - Mark response as incomplete

4. For production, use AgentServer:
   - Built-in cancellation support
   - PubSub event broadcasting
   - Proper state management

5. In LiveView:
   - Track task reference in assigns
   - Provide cancel button during streaming
   - Handle both completion and cancellation

6. For long-running tools:
   - Periodically check cancellation flag
   - Return early with partial results
   - Clean up resources
""")

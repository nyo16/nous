#!/usr/bin/env elixir

# Nous AI - Callbacks (v0.8.0)
# Two ways to receive events: map callbacks and process messages

IO.puts("=== Nous AI - Callbacks Demo ===\n")

agent = Nous.new("lmstudio:qwen3",
  instructions: "You are helpful. Keep responses brief."
)

# ============================================================================
# Method 1: Map-based callbacks
# ============================================================================

IO.puts("--- Method 1: Map Callbacks ---")
IO.puts("Streaming response with callbacks:\n")

{:ok, _result} = Nous.run(agent, "Count from 1 to 5",
  callbacks: %{
    on_llm_new_delta: fn _event, delta ->
      IO.write(delta)
    end,
    on_llm_new_message: fn _event, message ->
      IO.puts("\n[Message complete: #{String.length(message.content)} chars]")
    end
  }
)

IO.puts("")

# ============================================================================
# Method 2: Process messages (for GenServer/LiveView)
# ============================================================================

IO.puts("\n--- Method 2: Process Messages (notify_pid) ---")
IO.puts("Receiving events as process messages:\n")

# Spawn a task that uses notify_pid
parent = self()

Task.start(fn ->
  {:ok, _result} = Nous.run(agent, "Say hello in 3 languages",
    notify_pid: parent
  )
end)

# Receive and handle messages
defmodule MessageHandler do
  def loop do
    receive do
      {:agent_delta, text} ->
        IO.write(text)
        loop()

      {:tool_call, call} ->
        IO.puts("\n[Tool called: #{call.name}]")
        loop()

      {:tool_result, result} ->
        IO.puts("[Tool result: #{inspect(result.result)}]")
        loop()

      {:agent_complete, result} ->
        IO.puts("\n[Complete! Tokens: #{result.usage.total_tokens}]")
        :done

      {:agent_error, error} ->
        IO.puts("\n[Error: #{inspect(error)}]")
        :done

    after
      30_000 ->
        IO.puts("\n[Timeout]")
        :done
    end
  end
end

MessageHandler.loop()

# ============================================================================
# Method 3: Callbacks with tools
# ============================================================================

IO.puts("\n--- Method 3: Callbacks with Tools ---")

search = fn _ctx, %{"query" => query} ->
  Process.sleep(100)  # Simulate API call
  %{results: ["Result for: #{query}"]}
end

agent_with_tools = Nous.new("lmstudio:qwen3",
  instructions: "Use the search tool when asked to look something up.",
  tools: [search]
)

{:ok, _result} = Nous.run(agent_with_tools, "Search for Elixir programming",
  callbacks: %{
    on_tool_call: fn _event, call ->
      IO.puts("[Calling tool: #{call.name}(#{inspect(call.arguments)})]")
    end,
    on_tool_response: fn _event, response ->
      IO.puts("[Tool response: #{inspect(response.result)}]")
    end,
    on_llm_new_delta: fn _event, delta ->
      IO.write(delta)
    end
  }
)

IO.puts("\n")

# ============================================================================
# LiveView Integration Pattern
# ============================================================================

IO.puts("""
--- LiveView Integration Pattern ---

In a Phoenix LiveView, use notify_pid: self() to receive events:

  def handle_event("send_message", %{"text" => text}, socket) do
    Task.start(fn ->
      Nous.run(agent, text, notify_pid: socket.root_pid)
    end)
    {:noreply, socket}
  end

  def handle_info({:agent_delta, text}, socket) do
    {:noreply, stream_insert(socket, :messages, %{text: text})}
  end

  def handle_info({:agent_complete, _result}, socket) do
    {:noreply, assign(socket, :loading, false)}
  end

See: lib/nous/agent_server.ex for stateful agent pattern
""")

IO.puts("Next: mix run examples/06_prompt_templates.exs")

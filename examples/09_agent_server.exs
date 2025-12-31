#!/usr/bin/env elixir

# Nous AI - AgentServer (v0.8.0)
# Stateful agents with GenServer and PubSub

IO.puts("=== Nous AI - AgentServer Demo ===\n")

# ============================================================================
# Basic AgentServer Usage
# ============================================================================

IO.puts("--- Basic AgentServer ---")

# Start an AgentServer
{:ok, pid} = Nous.AgentServer.start_link(
  agent_config: %{
    model: "lmstudio:qwen3",
    instructions: "You are a helpful assistant. Remember our conversation."
  },
  session_id: "demo-session-001"
)

IO.puts("Started AgentServer: #{inspect(pid)}")

# Subscribe to events
Nous.AgentServer.subscribe(pid)
IO.puts("Subscribed to events")
IO.puts("")

# Send a message
IO.puts("Sending: Hello, I'm Alice")
Nous.AgentServer.send_message(pid, "Hello, I'm Alice")

# Receive streaming events
defmodule EventReceiver do
  def receive_until_complete do
    receive do
      {:agent_delta, text} ->
        IO.write(text)
        receive_until_complete()

      {:tool_call, call} ->
        IO.puts("\n[Tool: #{call.name}]")
        receive_until_complete()

      {:agent_complete, result} ->
        IO.puts("\n[Complete - #{result.usage.total_tokens} tokens]\n")
        :ok

      {:agent_error, error} ->
        IO.puts("\n[Error: #{inspect(error)}]")
        :error

    after
      30_000 ->
        IO.puts("\n[Timeout]")
        :timeout
    end
  end
end

EventReceiver.receive_until_complete()

# Send follow-up (conversation continues)
IO.puts("Sending follow-up: What's my name?")
Nous.AgentServer.send_message(pid, "What's my name?")
EventReceiver.receive_until_complete()

# Check conversation history
history = Nous.AgentServer.get_history(pid)
IO.puts("Conversation has #{length(history)} messages")
IO.puts("")

# ============================================================================
# AgentServer with Tools
# ============================================================================

IO.puts("--- AgentServer with Tools ---")

get_time = fn _ctx, _args ->
  %{time: DateTime.utc_now() |> DateTime.to_string()}
end

{:ok, pid2} = Nous.AgentServer.start_link(
  agent_config: %{
    model: "lmstudio:qwen3",
    instructions: "You have a time tool. Use it when asked about time.",
    tools: [get_time]
  },
  session_id: "tools-session"
)

Nous.AgentServer.subscribe(pid2)
Nous.AgentServer.send_message(pid2, "What time is it?")
EventReceiver.receive_until_complete()

# ============================================================================
# AgentServer with PubSub (Phoenix Integration)
# ============================================================================

IO.puts("""
--- Phoenix LiveView Integration ---

In a Phoenix application, AgentServer integrates with PubSub:

# In your LiveView
def mount(_params, %{"user_id" => user_id}, socket) do
  # Start or lookup existing agent server
  {:ok, pid} = AgentRegistry.get_or_start(user_id, %{
    model: "anthropic:claude-sonnet-4-5-20250929",
    instructions: "You are a helpful assistant."
  })

  # Subscribe to agent events
  Nous.AgentServer.subscribe(pid)

  {:ok, assign(socket, agent: pid, messages: [])}
end

def handle_event("send_message", %{"text" => text}, socket) do
  Nous.AgentServer.send_message(socket.assigns.agent, text)
  {:noreply, socket}
end

def handle_info({:agent_delta, text}, socket) do
  # Stream text to UI
  {:noreply, stream_insert(socket, :response, %{text: text})}
end

def handle_info({:agent_complete, result}, socket) do
  {:noreply, assign(socket, loading: false)}
end

def handle_info({:tool_call, call}, socket) do
  # Show tool indicator in UI
  {:noreply, assign(socket, current_tool: call.name)}
end
""")

# ============================================================================
# Cleanup
# ============================================================================

# Stop the servers
GenServer.stop(pid)
GenServer.stop(pid2)

IO.puts("Next: mix run examples/10_react_agent.exs")

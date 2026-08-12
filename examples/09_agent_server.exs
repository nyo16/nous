#!/usr/bin/env elixir

# Nous AI - AgentServer (v0.8.0)
# Stateful agents with GenServer and PubSub
#
# NOTE: AgentServer never sends events directly to the caller - it publishes
# them over Nous.PubSub. Delivery therefore requires BOTH of:
#
#   1. `{:phoenix_pubsub, "~> 2.1"}` present as a dependency, AND
#   2. `config :nous, pubsub: MyApp.PubSub` pointing at a running
#      Phoenix.PubSub process.
#
# With either missing, `Nous.PubSub.configured_pubsub/0` returns nil and
# `Nous.PubSub.subscribe/2` is a silent no-op: nothing is delivered and the
# receive loops below simply hit their 30s timeout.

IO.puts("=== Nous AI - AgentServer Demo ===\n")

# ============================================================================
# Basic AgentServer Usage
# ============================================================================

IO.puts("--- Basic AgentServer ---")

# Start an AgentServer. The session_id doubles as the PubSub topic key.
session_id = "demo-session-001"

{:ok, pid} =
  Nous.AgentServer.start_link(
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You are a helpful assistant. Remember our conversation."
    },
    session_id: session_id
  )

IO.puts("Started AgentServer: #{inspect(pid)}")

# Subscribe to events. Events are broadcast on Nous.PubSub.agent_topic/1,
# keyed by session_id - not by pid - so subscribe to that topic.
Nous.PubSub.subscribe(Nous.PubSub.configured_pubsub(), Nous.PubSub.agent_topic(session_id))
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

# Bare anonymous functions make poor tools: the name the model sees is the
# compiler-mangled closure name and the parameter schema is empty. Wrap them
# with Nous.Tool.from_function/2 to supply a real name, description and schema.
get_time =
  Nous.Tool.from_function(
    fn _ctx, _args ->
      %{time: DateTime.utc_now() |> DateTime.to_string()}
    end,
    name: "get_time",
    description: "Get the current UTC time as a string.",
    parameters: %{"type" => "object", "properties" => %{}, "required" => []}
  )

tools_session_id = "tools-session"

{:ok, pid2} =
  Nous.AgentServer.start_link(
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You have a time tool. Use it when asked about time.",
      tools: [get_time]
    },
    session_id: tools_session_id
  )

Nous.PubSub.subscribe(
  Nous.PubSub.configured_pubsub(),
  Nous.PubSub.agent_topic(tools_session_id)
)

Nous.AgentServer.send_message(pid2, "What time is it?")
EventReceiver.receive_until_complete()

# ============================================================================
# AgentServer with PubSub (Phoenix Integration)
# ============================================================================

IO.puts("""
--- Phoenix LiveView Integration ---

In a Phoenix application, AgentServer integrates with Nous.PubSub.

# Configure once in config/config.exs:
#   config :nous, pubsub: MyApp.PubSub

# In your LiveView
def mount(_params, %{"user_id" => user_id}, socket) do
  session_id = user_id

  # Subscribe to agent events via Nous.PubSub
  Nous.PubSub.subscribe(Nous.PubSub.configured_pubsub(), Nous.PubSub.agent_topic(session_id))

  # Start agent - pubsub auto-configured from app config
  {:ok, pid} = Nous.AgentServer.start_link(
    session_id: session_id,
    agent_config: %{
      model: "anthropic:claude-sonnet-4-5-20250929",
      instructions: "You are a helpful assistant."
    }
  )

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

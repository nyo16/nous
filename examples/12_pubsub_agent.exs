#!/usr/bin/env elixir

# Nous AI - PubSub Agent Communication
# Full agent lifecycle managed via Nous.PubSub (wraps Phoenix.PubSub)
#
# This example shows how to:
#   1. Start supervised agents via AgentDynamicSupervisor
#   2. Find agents via AgentRegistry
#   3. Communicate entirely through PubSub (no direct PID references)
#   4. Use HITL approval via PubSub broadcasts
#   5. Persist and restore sessions
#
# Run: mix run examples/12_pubsub_agent.exs
#
# Requires phoenix_pubsub (an optional dep of Nous):
#   {:phoenix_pubsub, "~> 2.1"}
#
# Nous.PubSub is a thin wrapper over Phoenix.PubSub. It reads the pubsub name
# from `config :nous, pubsub: MyApp.PubSub`; when that is unset,
# `Nous.PubSub.configured_pubsub/0` returns nil and every subscribe/broadcast
# is a silent no-op — agents run fine but you never see an event. This script
# therefore starts a real Phoenix.PubSub and sets the config BEFORE any agent
# starts, which is exactly what a Phoenix app does in its supervision tree.
#
# Model: the agent runs need a local LM Studio on http://localhost:1234/v1.
# Without one you still see the full event flow — the events are just
# {:agent_error, ...} instead of {:agent_delta, ...}.

IO.puts("=== Nous AI - PubSub Agent Communication ===\n")

# ============================================================================
# Real PubSub, wired the way a Phoenix app wires it
# ============================================================================

unless Code.ensure_loaded?(Phoenix.PubSub) do
  IO.puts("""
  Skipping: phoenix_pubsub is not available.

  Add it to your mix.exs deps and run `mix deps.get`:

      {:phoenix_pubsub, "~> 2.1"}
  """)

  System.halt(0)
end

{:ok, _pubsub} = Phoenix.PubSub.Supervisor.start_link(name: Demo.PubSub)

# Must happen before any AgentServer starts: the server reads the configured
# pubsub when it builds its callbacks.
Application.put_env(:nous, :pubsub, Demo.PubSub)

pubsub = Nous.PubSub.configured_pubsub()
IO.puts("Configured pubsub: #{inspect(pubsub)}\n")

# ============================================================================
# Example 1: Basic PubSub Agent Lifecycle
# ============================================================================

IO.puts("--- Example 1: Basic PubSub Agent ---\n")

session_id = "user-session-#{:rand.uniform(10000)}"
topic = Nous.PubSub.agent_topic(session_id)

# Subscribe to the agent's topic BEFORE starting it.
:ok = Nous.PubSub.subscribe(pubsub, topic)
IO.puts("Subscribed to topic: #{topic}")

# Start a supervised agent registered in the AgentRegistry
{:ok, agent_pid} =
  Nous.AgentServer.start_link(
    session_id: session_id,
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You are a helpful assistant. Be concise.",
      tools: []
    },
    # No `pubsub:` option needed here: the AgentServer picks up
    # `config :nous, pubsub:` and broadcasts every event to
    # `Nous.PubSub.agent_topic(session_id)`.
    name: Nous.AgentRegistry.via_tuple(session_id)
  )

IO.puts("Agent started: #{session_id} (pid: #{inspect(agent_pid)})")

# Find the agent by session_id (no PID needed!)
{:ok, found_pid} = Nous.AgentRegistry.lookup(session_id)
IO.puts("Found agent via registry: #{inspect(found_pid)}\n")

# Send a message via the registered name (no PID needed)
IO.puts("Sending message via PubSub pattern...")
Nous.AgentServer.send_message(found_pid, "Hello! What is Elixir?")

# Receive PubSub events.
#
# These clauses mirror exactly what is published on the agent topic:
# `Nous.Agent.Callbacks.to_message/2` maps every callback event to a tuple
# ({:agent_start, %{agent: agent}}, {:agent_delta, text}, {:agent_thinking, text},
# {:agent_message, msg}, {:tool_call, call}, {:tool_result, result},
# {:agent_complete, result}, {:agent_error, error}), and AgentServer adds
# {:agent_status, :started | :thinking}, {:agent_response, output} and
# {:agent_cancelled, reason}.
#
# Note on {:agent_delta, _}: deltas only exist for a streaming run. AgentServer
# does not enable streaming, so the answer arrives whole in {:agent_response,
# output}. The delta clause is here because the same handler works verbatim for
# a `Nous.run(agent, prompt, stream: true, ...)` run on the same topic.
defmodule EventHandler do
  def collect_response(acc \\ "") do
    receive do
      {:agent_start, %{agent: agent}} ->
        IO.puts("[Started: #{agent.model.provider}:#{agent.model.model}]")
        collect_response(acc)

      {:agent_status, :started} ->
        collect_response(acc)

      {:agent_status, :thinking} ->
        IO.puts("[Status: thinking...]")
        collect_response(acc)

      {:agent_delta, text} ->
        IO.write(text)
        collect_response(acc <> text)

      {:agent_thinking, _text} ->
        collect_response(acc)

      {:agent_message, _message} ->
        collect_response(acc)

      {:agent_response, output} ->
        IO.puts("Response: #{output}")
        collect_response(acc)

      {:agent_complete, result} ->
        IO.puts(
          "[Complete - #{result.usage.total_tokens} tokens, #{result.iterations} iterations]"
        )

        {:ok, result}

      {:agent_error, error} ->
        IO.puts("[Error: #{inspect(error)}]")
        {:error, error}

      {:tool_call, call} ->
        IO.puts("[Tool call: #{call.name}]")
        collect_response(acc)

      {:tool_result, _result} ->
        collect_response(acc)

      {:agent_cancelled, reason} ->
        IO.puts("[Cancelled: #{reason}]")
        {:error, :cancelled}

      other ->
        IO.puts("[Unhandled event: #{inspect(other)}]")
        collect_response(acc)
    after
      # Safety net only. The normal exits are {:agent_complete, _} (model
      # answered) or {:agent_error, _} (e.g. connection refused because no
      # LM Studio is running) — both arrive in well under a second, so this
      # script finishes promptly either way.
      10_000 ->
        IO.puts("[Timeout waiting for agent events]")
        {:error, :timeout}
    end
  end

  # Drop any events still queued from a previous turn. A script (unlike a
  # LiveView) collects one turn at a time, so leftover post-completion events
  # would otherwise be read as the *next* turn's events.
  def drain do
    receive do
      _event -> drain()
    after
      0 -> :ok
    end
  end
end

EventHandler.collect_response()

# ============================================================================
# Example 2: Multi-turn conversation via PubSub
# ============================================================================

IO.puts("\n--- Example 2: Multi-turn Conversation ---\n")

IO.puts("Sending follow-up...")
EventHandler.drain()
Nous.AgentServer.send_message(found_pid, "What are its best features?")
EventHandler.collect_response()

# Check conversation history
history = Nous.AgentServer.get_history(found_pid)
IO.puts("\nConversation has #{length(history)} messages")

# ============================================================================
# Example 3: Agent with Tools + PubSub Events
# ============================================================================

IO.puts("\n--- Example 3: Tools + PubSub ---\n")

session_id2 = "tools-session-#{:rand.uniform(10000)}"
topic2 = Nous.PubSub.agent_topic(session_id2)
:ok = Nous.PubSub.subscribe(pubsub, topic2)

get_time = fn _ctx, _args ->
  %{time: DateTime.utc_now() |> Calendar.strftime("%H:%M:%S"), timezone: "UTC"}
end

get_weather = fn _ctx, %{"city" => city} ->
  %{city: city, temp: 22, conditions: "partly cloudy"}
end

{:ok, _pid2} =
  Nous.AgentServer.start_link(
    session_id: session_id2,
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You have access to time and weather tools. Use them when asked.",
      tools: [
        Nous.Tool.from_function(get_time,
          name: "get_time",
          description: "Get the current time",
          parameters: %{"type" => "object", "properties" => %{}, "required" => []}
        ),
        Nous.Tool.from_function(get_weather,
          name: "get_weather",
          description: "Get weather for a city",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["city"]
          }
        )
      ]
    },
    name: Nous.AgentRegistry.via_tuple(session_id2)
  )

# Send message to agent by looking it up from registry
{:ok, pid2} = Nous.AgentRegistry.lookup(session_id2)
EventHandler.drain()
Nous.AgentServer.send_message(pid2, "What time is it and what's the weather in Tokyo?")
EventHandler.collect_response()

# ============================================================================
# Example 4: Session Persistence via PubSub
# ============================================================================

IO.puts("\n--- Example 4: Session Persistence ---\n")

session_id3 = "persist-session-#{:rand.uniform(10000)}"
topic3 = Nous.PubSub.agent_topic(session_id3)
:ok = Nous.PubSub.subscribe(pubsub, topic3)

{:ok, _pid3} =
  Nous.AgentServer.start_link(
    session_id: session_id3,
    agent_config: %{
      model: "lmstudio:qwen3",
      instructions: "You are a helpful assistant. Remember our conversation."
    },
    persistence: Nous.Persistence.ETS,
    name: Nous.AgentRegistry.via_tuple(session_id3)
  )

{:ok, pid3} = Nous.AgentRegistry.lookup(session_id3)

IO.puts("Sending message with persistence enabled...")
EventHandler.drain()
Nous.AgentServer.send_message(pid3, "My favorite color is blue. Remember that.")
EventHandler.collect_response()

# Save context explicitly
:ok = Nous.AgentServer.save_context(pid3)
IO.puts("\nContext saved for session: #{session_id3}")

# Verify persistence
{:ok, saved_data} = Nous.Persistence.ETS.load(session_id3)
IO.puts("Persisted data version: #{saved_data.version}")
IO.puts("Persisted messages: #{length(saved_data.messages)}")

# ============================================================================
# Phoenix LiveView Integration Pattern
# ============================================================================

IO.puts("""

--- Phoenix LiveView Pattern ---

In a real Phoenix app, the full pattern looks like this:

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def mount(%{"session_id" => session_id}, _session, socket) do
    # Subscribe to agent events via PubSub
    Nous.PubSub.subscribe(Nous.PubSub.configured_pubsub(), Nous.PubSub.agent_topic(session_id))

    # Start or find existing agent
    pid = case Nous.AgentRegistry.lookup(session_id) do
      {:ok, pid} -> pid
      {:error, :not_found} ->
        {:ok, pid} = Nous.AgentDynamicSupervisor.start_agent(
          session_id,
          %{model: "openai:gpt-4", instructions: "Be helpful."},
          persistence: Nous.Persistence.ETS,
          pubsub: MyApp.PubSub
        )
        pid
    end

    {:ok, assign(socket, session_id: session_id, agent: pid, messages: [])}
  end

  # User sends a message -> forward to agent
  def handle_event("send", %{"message" => text}, socket) do
    Nous.AgentServer.send_message(socket.assigns.agent, text)
    {:noreply, assign(socket, loading: true)}
  end

  # Agent streams text -> update UI
  def handle_info({:agent_delta, text}, socket) do
    {:noreply, update(socket, :current_text, &(&1 <> text))}
  end

  # Agent calls a tool -> show indicator
  def handle_info({:tool_call, call}, socket) do
    {:noreply, assign(socket, tool_status: "Using \#{call.name}...")}
  end

  # Agent finishes -> add to messages
  def handle_info({:agent_complete, result}, socket) do
    messages = socket.assigns.messages ++ [
      %{role: :assistant, content: result.output}
    ]
    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  # Agent needs approval -> show dialog (via Nous.PubSub.Approval)
  def handle_info({:approval_required, info}, socket) do
    {:noreply, assign(socket, pending_approval: info)}
  end

  # User approves or rejects
  def handle_event("approve_tool", _params, socket) do
    info = socket.assigns.pending_approval
    Nous.PubSub.Approval.respond(
      MyApp.PubSub, info.session_id, info.tool_call_id, :approve
    )
    {:noreply, assign(socket, pending_approval: nil)}
  end

  def handle_event("reject_tool", _params, socket) do
    info = socket.assigns.pending_approval
    Nous.PubSub.Approval.respond(
      MyApp.PubSub, info.session_id, info.tool_call_id, :reject
    )
    {:noreply, assign(socket, pending_approval: nil)}
  end
end
```

To enable async approval, configure HITL with Nous.PubSub.Approval:
```elixir
deps = %{hitl_config: %{
  tools: ["send_email"],
  handler: Nous.PubSub.Approval.handler(
    pubsub: MyApp.PubSub,
    session_id: session_id,
    timeout: :timer.minutes(5)
  )
}}
```

Key points:
  - Configure PubSub once: `config :nous, pubsub: MyApp.PubSub`
  - All communication goes through PubSub topics (Nous.PubSub.agent_topic/1,
    i.e. "nous:agent:{session_id}")
  - No direct PID references in the LiveView
  - AgentRegistry handles lookup by session_id
  - Persistence auto-saves after each response
  - Agent survives LiveView reconnects (supervised)
  - Async HITL approval via Nous.PubSub.Approval
""")

# ============================================================================
# Cleanup
# ============================================================================

# Stop agents gracefully
for sid <- [session_id, session_id2, session_id3] do
  case Nous.AgentRegistry.lookup(sid) do
    {:ok, pid} -> GenServer.stop(pid, :normal)
    _ -> :ok
  end
end

IO.puts("Agents stopped. Done!")

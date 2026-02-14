#!/usr/bin/env elixir

# Nous AI - PubSub Agent Communication
# Full agent lifecycle managed via Phoenix.PubSub
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
# NOTE: This example requires phoenix_pubsub:
#   {:phoenix_pubsub, "~> 2.1"}
#
# For demonstration, we simulate PubSub with a simple process-based approach
# that mirrors the real Phoenix.PubSub API.

IO.puts("=== Nous AI - PubSub Agent Communication ===\n")

# ============================================================================
# Simulated PubSub (replace with Phoenix.PubSub in real Phoenix apps)
# ============================================================================

defmodule DemoPubSub do
  @moduledoc """
  Minimal PubSub simulation for this example.
  In a real Phoenix app, use Phoenix.PubSub instead.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic, self()})
  end

  def broadcast(topic, message) do
    GenServer.call(__MODULE__, {:broadcast, topic, message})
  end

  @impl true
  def init(_), do: {:ok, %{subscriptions: %{}}}

  @impl true
  def handle_call({:subscribe, topic, pid}, _from, state) do
    subs = Map.update(state.subscriptions, topic, [pid], &[pid | &1])
    {:reply, :ok, %{state | subscriptions: subs}}
  end

  @impl true
  def handle_call({:broadcast, topic, message}, _from, state) do
    pids = Map.get(state.subscriptions, topic, [])
    Enum.each(pids, fn pid -> send(pid, message) end)
    {:reply, :ok, state}
  end
end

# Start our demo PubSub
{:ok, _} = DemoPubSub.start_link([])

# ============================================================================
# Example 1: Basic PubSub Agent Lifecycle
# ============================================================================

IO.puts("--- Example 1: Basic PubSub Agent ---\n")

session_id = "user-session-#{:rand.uniform(10000)}"
topic = "agent:#{session_id}"

# Subscribe to the agent's topic BEFORE starting it
DemoPubSub.subscribe(topic)
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
    # In a real Phoenix app, set pubsub: MyApp.PubSub
    # The AgentServer broadcasts all events to "agent:{session_id}"
    name: Nous.AgentRegistry.via_tuple(session_id)
  )

IO.puts("Agent started: #{session_id} (pid: #{inspect(agent_pid)})")

# Find the agent by session_id (no PID needed!)
{:ok, found_pid} = Nous.AgentRegistry.lookup(session_id)
IO.puts("Found agent via registry: #{inspect(found_pid)}\n")

# Send a message via the registered name (no PID needed)
IO.puts("Sending message via PubSub pattern...")
Nous.AgentServer.send_message(found_pid, "Hello! What is Elixir?")

# Receive PubSub events
defmodule EventHandler do
  def collect_response(acc \\ "") do
    receive do
      {:agent_status, :thinking} ->
        IO.puts("[Status: thinking...]")
        collect_response(acc)

      {:agent_delta, text} ->
        IO.write(text)
        collect_response(acc <> text)

      {:agent_response, _output} ->
        collect_response(acc)

      {:agent_complete, result} ->
        IO.puts("\n[Complete - #{result.usage.total_tokens} tokens]")
        {:ok, result}

      {:agent_error, error} ->
        IO.puts("\n[Error: #{inspect(error)}]")
        {:error, error}

      {:tool_call, call} ->
        IO.puts("\n[Tool call: #{call.name}]")
        collect_response(acc)

      {:tool_result, _result} ->
        collect_response(acc)

      {:agent_cancelled, reason} ->
        IO.puts("\n[Cancelled: #{reason}]")
        {:error, :cancelled}

      other ->
        IO.puts("[Unknown event: #{inspect(other)}]")
        collect_response(acc)
    after
      30_000 ->
        IO.puts("\n[Timeout]")
        {:error, :timeout}
    end
  end
end

EventHandler.collect_response()

# ============================================================================
# Example 2: Multi-turn conversation via PubSub
# ============================================================================

IO.puts("\n--- Example 2: Multi-turn Conversation ---\n")

IO.puts("Sending follow-up...")
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
topic2 = "agent:#{session_id2}"
DemoPubSub.subscribe(topic2)

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
Nous.AgentServer.send_message(pid2, "What time is it and what's the weather in Tokyo?")
EventHandler.collect_response()

# ============================================================================
# Example 4: Session Persistence via PubSub
# ============================================================================

IO.puts("\n--- Example 4: Session Persistence ---\n")

session_id3 = "persist-session-#{:rand.uniform(10000)}"
topic3 = "agent:#{session_id3}"
DemoPubSub.subscribe(topic3)

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
    Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:\#{session_id}")

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

  # Agent needs approval -> show dialog
  def handle_info({:approval_required, tool_call}, socket) do
    {:noreply, assign(socket, pending_approval: tool_call)}
  end
end
```

Key points:
  - All communication goes through PubSub topics ("agent:{session_id}")
  - No direct PID references in the LiveView
  - AgentRegistry handles lookup by session_id
  - Persistence auto-saves after each response
  - Agent survives LiveView reconnects (supervised)
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

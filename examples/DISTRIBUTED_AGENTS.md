# Distributed Agents Guide

## Overview

This guide shows how to create **named, distributed AI agents** that work across an Elixir cluster using Registry.

## Key Concepts

### Named Processes
Instead of anonymous PIDs, agents get unique names:
```elixir
{:via, Registry, {MyApp.AgentRegistry, "user:123:chat"}}
```

### Benefits
- ✅ **Find agents by name** across cluster
- ✅ **One agent per user** (conversation persistence)
- ✅ **Automatic cleanup** when owner dies (process linking)
- ✅ **Distributed** - works across nodes
- ✅ **Monitoring** - track all running agents

---

## Setup

### 1. Add Registry to Application

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Registry for naming agents
      {Registry, keys: :unique, name: MyApp.AgentRegistry},

      # Task supervisor for agent tasks
      {Task.Supervisor, name: MyApp.TaskSupervisor},

      # Your other children...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### 2. Create DistributedAgent GenServer

See `examples/distributed_agent_example.ex` for complete implementation.

---

## Usage Patterns

### Pattern 1: Simple Named Agent

```elixir
# Start agent with a name
{:ok, pid} = MyApp.DistributedAgent.start_agent(
  name: "my-chat-agent",
  model: "anthropic:claude-sonnet-4-5-20250929"
)

# Chat with it by name (from anywhere!)
{:ok, result} = MyApp.DistributedAgent.chat("my-chat-agent", "Hello!")
IO.puts(result.output)

# Find the PID
{:ok, ^pid} = MyApp.DistributedAgent.whereis("my-chat-agent")

# Stop it
MyApp.DistributedAgent.stop_agent("my-chat-agent")
```

---

### Pattern 2: LiveView with Linked Agent ⭐ **Recommended**

```elixir
defmodule MyAppWeb.ChatLive do
  use Phoenix.LiveView
  alias MyApp.DistributedAgent

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    # Create unique name for this user's chat
    agent_name = "chat:user:#{user_id}"

    # Start agent LINKED to this LiveView process
    {:ok, agent_pid} = DistributedAgent.start_agent(
      name: agent_name,
      model: "anthropic:claude-sonnet-4-5-20250929",
      owner_pid: self(),  # ← Link to LiveView!
      instructions: "You are a helpful assistant for user #{user_id}"
    )

    socket =
      socket
      |> assign(:agent_name, agent_name)
      |> assign(:agent_pid, agent_pid)

    {:ok, socket}
  end

  @impl true
  def handle_event("send", %{"message" => msg}, socket) do
    # Chat with named agent (works even if agent is on another node!)
    Task.start(fn ->
      {:ok, result} = DistributedAgent.chat(socket.assigns.agent_name, msg)
      send(socket.assigns.parent_pid || self(), {:response, result.output})
    end)

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Agent automatically dies because it's linked!
    # But we can also stop it explicitly:
    DistributedAgent.stop_agent(socket.assigns.agent_name)
    :ok
  end
end
```

**Key Point:** When LiveView dies → Agent dies automatically! ✨

---

### Pattern 3: Session-Based Agents

```elixir
defmodule MyAppWeb.SessionChatLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    # Use session ID for agent name
    session_id = session["session_id"] || generate_session_id()
    agent_name = "chat:session:#{session_id}"

    # Start or reconnect to existing agent
    agent_pid = case DistributedAgent.whereis(agent_name) do
      {:ok, pid} ->
        # Agent already exists, reconnect
        Process.link(pid)
        pid

      {:error, :not_found} ->
        # Create new agent
        {:ok, pid} = DistributedAgent.start_agent(
          name: agent_name,
          owner_pid: self()
        )
        pid
    end

    {:ok, assign(socket, agent_name: agent_name, agent_pid: agent_pid)}
  end
end
```

---

### Pattern 4: Distributed Cluster

```elixir
# Node 1
iex(node1@host)> {:ok, _} = DistributedAgent.start_agent(
  name: {:via, Registry, {MyApp.AgentRegistry, "global-agent"}},
  model: "anthropic:claude-sonnet-4-5-20250929"
)

# Node 2 (different machine!)
iex(node2@host)> {:ok, result} = DistributedAgent.chat(
  {:via, Registry, {MyApp.AgentRegistry, "global-agent"}},
  "Hello from node 2!"
)

# Works across the cluster! 🌐
```

---

## Process Lifecycle

### What happens when LiveView dies?

```elixir
# 1. LiveView starts
liveview_pid = spawn(LiveView)

# 2. Agent starts with owner_pid
{:ok, agent_pid} = DistributedAgent.start_agent(
  name: "agent-1",
  owner_pid: liveview_pid  # ← Links to LiveView
)

# 3. Inside DistributedAgent.init/1:
Process.link(owner_pid)  # ← Bidirectional link created

# 4. LiveView crashes/closes
Process.exit(liveview_pid, :normal)

# 5. Agent automatically dies! ✅
# Because: linked processes die together
```

### Visual Flow

```
LiveView Process          Agent GenServer
     │                         │
     │──── start_agent ────────▶ init()
     │                         │
     │◀──── Process.link ──────│  (bidirectional)
     │                         │
     │──── chat ───────────────▶ handle_call
     │◀──── response ──────────│
     │                         │
     ✗ (dies)                  │
     │                         │
     └────── linked ───────────▶ ✗ (dies automatically)
```

---

## Advanced: Agent Registry Operations

### List all running agents
```elixir
MyApp.AgentRegistry.Helpers.list_agents()
# => [{"chat:user:1", #PID<0.123.0>}, {"chat:user:2", #PID<0.124.0>}]
```

### Count agents
```elixir
MyApp.AgentRegistry.Helpers.count_agents()
# => 5
```

### Find agents by pattern
```elixir
MyApp.AgentRegistry.Helpers.find_agents("user:123")
# => [{"chat:user:123", #PID<...>, %{model: "claude-sonnet-4-5", ...}}]
```

### Stop all agents for a user
```elixir
MyApp.AgentRegistry.Helpers.stop_agents_matching("user:123")
# Stops all agents with "user:123" in their name
```

---

## Complete Example

```elixir
# 1. Start registry (in application.ex)
{Registry, keys: :unique, name: MyApp.AgentRegistry}

# 2. In LiveView mount
def mount(_params, %{"user_id" => user_id}, socket) do
  agent_name = "chat:user:#{user_id}"

  {:ok, agent_pid} = MyApp.DistributedAgent.start_agent(
    name: agent_name,
    model: "anthropic:claude-sonnet-4-5-20250929",
    owner_pid: self()  # ← Links to LiveView
  )

  {:ok, assign(socket, agent_name: agent_name)}
end

# 3. Send messages
def handle_event("send", %{"msg" => msg}, socket) do
  {:ok, result} = MyApp.DistributedAgent.chat(socket.assigns.agent_name, msg)
  {:noreply, update(socket, :messages, &(&1 ++ [result.output]))}
end

# 4. Cleanup (automatic!)
def terminate(_reason, _socket) do
  # Agent dies automatically because it's linked! ✨
  :ok
end
```

---

## Important Notes

### spawn_link returns the PID:
```elixir
agent_pid = spawn_link(fn ->
  agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")
  {:ok, r} = Yggdrasil.run(agent, msg)
  send(parent, {:done, r.output})
end)

# agent_pid is the PID of the spawned process
# NOT the "agent" itself (agents are just config structs)
```

### Agent vs Process:
```elixir
# Agent (struct) - just configuration
agent = Yggdrasil.new("anthropic:...")

# Process (PID) - the running task
process_pid = spawn_link(fn -> Yggdrasil.run(agent, msg) end)
```

### For named, persistent agents:
Use the **DistributedAgent GenServer** pattern - it wraps the agent in a named process.

---

## Quick Reference

| Pattern | Use Case | Cleanup | Distribution |
|---------|----------|---------|--------------|
| `spawn_link` | Quick requests | Automatic | No |
| Named GenServer | Persistent chats | Automatic | Yes |
| Registry | Multi-user | Manual | Yes |
| Cluster | Global agents | Automatic | Yes |

---

## Testing

```elixir
test "agent dies when owner dies" do
  # Start owner process
  owner = spawn(fn -> Process.sleep(:infinity) end)

  # Start agent linked to owner
  {:ok, agent_pid} = DistributedAgent.start_agent(
    name: "test-agent",
    owner_pid: owner
  )

  assert Process.alive?(agent_pid)

  # Kill owner
  Process.exit(owner, :kill)

  # Agent should die
  Process.sleep(100)
  refute Process.alive?(agent_pid)
end
```

---

## Summary

**Key Insight:** The PID from `spawn_link` is the **process PID**, not the agent. To get a **named agent process**, wrap it in a GenServer with Registry.

**Simple case:** Use `spawn_link` - cleanup is automatic
**Complex case:** Use DistributedAgent GenServer - get naming + linking

**See `examples/distributed_agent_example.ex` for complete code!**

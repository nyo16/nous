# LiveView + Yggdrasil Integration Guide

## Overview

This guide shows how to integrate Yggdrasil AI agents with Phoenix LiveView, including proper process linking and cleanup.

## Key Concepts

### Process Linking
When you spawn an agent from LiveView, you should link the processes so that:
- If LiveView dies → Agent process dies automatically
- If Agent dies → LiveView gets notified
- No orphaned processes or memory leaks

### Two Patterns

1. **Linked Spawn** (Simplest) - For quick requests
2. **GenServer** (Production) - For complex state management

---

## Pattern 1: Simple Linked Spawn ⭐ **Recommended for most cases**

```elixir
defmodule MyAppWeb.ChatLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [])}
  end

  @impl true
  def handle_event("send_message", %{"text" => text}, socket) do
    # Add user message
    socket = update(socket, :messages, &(&1 ++ [{:user, text}]))

    # Spawn LINKED agent process
    parent = self()

    spawn_link(fn ->
      # Create agent
      agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")

      # Run agent
      {:ok, result} = Yggdrasil.run(agent, text)

      # Send result to LiveView
      send(parent, {:agent_response, result.output})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_response, response}, socket) do
    # Add assistant message
    socket = update(socket, :messages, &(&1 ++ [{:assistant, response}]))
    {:noreply, socket}
  end

  # When LiveView terminates, linked processes die automatically! ✨
end
```

**Benefits:**
- ✅ Automatic cleanup (spawn_link)
- ✅ Simple and clear
- ✅ No manual process management
- ✅ Works great for most use cases

---

## Pattern 2: Streaming with Process Linking

```elixir
defmodule MyAppWeb.StreamingChatLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:messages, [])
      |> assign(:streaming, false)
      |> assign(:current_text, "")
      |> assign(:agent_pid, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"text" => text}, socket) do
    # Mark as streaming
    socket =
      socket
      |> assign(:streaming, true)
      |> assign(:current_text, "")

    # Spawn linked process for streaming
    parent = self()

    agent_pid = spawn_link(fn ->
      agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")

      case Yggdrasil.run_stream(agent, text) do
        {:ok, stream} ->
          # Stream each chunk to LiveView
          stream
          |> Stream.each(fn
            {:text_delta, chunk} ->
              send(parent, {:stream_chunk, chunk})

            {:finish, _} ->
              send(parent, :stream_complete)

            _ ->
              :ok
          end)
          |> Stream.run()

        {:error, error} ->
          send(parent, {:stream_error, error})
      end
    end)

    {:noreply, assign(socket, :agent_pid, agent_pid)}
  end

  @impl true
  def handle_event("stop_streaming", _params, socket) do
    # Kill the agent process
    if socket.assigns.agent_pid && Process.alive?(socket.assigns.agent_pid) do
      Process.exit(socket.assigns.agent_pid, :kill)
    end

    {:noreply, assign(socket, streaming: false, agent_pid: nil)}
  end

  @impl true
  def handle_info({:stream_chunk, text}, socket) do
    # Append chunk to current text
    new_text = socket.assigns.current_text <> text

    socket =
      socket
      |> assign(:current_text, new_text)
      |> push_event("append_text", %{text: text})

    {:noreply, socket}
  end

  @impl true
  def handle_info(:stream_complete, socket) do
    # Add complete message to history
    messages = socket.assigns.messages ++ [{:assistant, socket.assigns.current_text}]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:current_text, "")
      |> assign(:agent_pid, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_error, error}, socket) do
    socket =
      socket
      |> assign(:streaming, false)
      |> assign(:agent_pid, nil)
      |> put_flash(:error, "Error: #{inspect(error)}")

    {:noreply, socket}
  end

  # Cleanup when LiveView terminates
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.agent_pid && Process.alive?(socket.assigns.agent_pid) do
      Process.exit(socket.assigns.agent_pid, :shutdown)
    end

    :ok
  end
end
```

**Benefits:**
- ✅ Real-time streaming to UI
- ✅ Can stop generation mid-stream
- ✅ Proper cleanup on LiveView death
- ✅ Great UX for long responses

---

## Pattern 3: GenServer for Persistent Agents

```elixir
defmodule MyApp.PersistentAgentServer do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def chat(message) do
    GenServer.call(__MODULE__, {:chat, message}, 60_000)
  end

  @impl true
  def init(opts) do
    # Agent persists across multiple requests
    agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
      instructions: opts[:instructions] || "Be helpful",
      tools: opts[:tools] || []
    )

    {:ok, %{agent: agent, history: []}}
  end

  @impl true
  def handle_call({:chat, message}, _from, state) do
    # Run agent with conversation history
    case Yggdrasil.run(state.agent, message, message_history: state.history) do
      {:ok, result} ->
        # Update history
        new_history = state.history ++ result.new_messages

        {:reply, {:ok, result}, %{state | history: new_history}}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("PersistentAgentServer shutting down: #{inspect(reason)}")
    :ok
  end
end
```

**Benefits:**
- ✅ Conversation history maintained
- ✅ One agent for all requests
- ✅ Survives individual request failures
- ✅ Proper supervision tree integration

---

## Application Supervisor Setup

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your Phoenix endpoint
      MyAppWeb.Endpoint,

      # Task supervisor for agent tasks
      {Task.Supervisor, name: MyApp.TaskSupervisor},

      # Optional: Persistent agent server
      {MyApp.PersistentAgentServer,
       model: "anthropic:claude-sonnet-4-5-20250929",
       instructions: "You are a helpful assistant"}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## Best Practices

### ✅ DO

1. **Use `spawn_link/1`** for agent tasks from LiveView
   ```elixir
   spawn_link(fn -> run_agent() end)
   ```

2. **Store PID** if you need to kill it
   ```elixir
   agent_pid = spawn_link(fn -> ... end)
   assign(socket, :agent_pid, agent_pid)
   ```

3. **Implement `terminate/2`** for cleanup
   ```elixir
   def terminate(_reason, socket) do
     if socket.assigns.agent_pid do
       Process.exit(socket.assigns.agent_pid, :shutdown)
     end
     :ok
   end
   ```

4. **Use Task.Supervisor** for better control
   ```elixir
   Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
     run_agent()
   end)
   ```

### ❌ DON'T

1. **Don't use `spawn/1`** (unlinked) - can cause orphans
2. **Don't block LiveView process** - always async
3. **Don't forget cleanup** in `terminate/2`
4. **Don't store agent in socket** - create per-request

---

## Testing

```elixir
# test/my_app_web/live/chat_live_test.exs
defmodule MyAppWeb.ChatLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  test "sends message to agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    # Send a message
    view
    |> form("#chat-form", message: %{text: "Hello!"})
    |> render_submit()

    # Wait for response
    assert_receive {:agent_response, _response}, 5000

    # Check it was added to messages
    assert view |> element(".message-assistant") |> has_element?()
  end
end
```

---

## Complete Example Code

See `examples/liveview_agent_example.ex` for complete working code including:
- Full LiveView implementation
- Streaming support
- Process linking
- Cleanup on termination
- Error handling
- Stop button

---

## Quick Reference

| Pattern | Use Case | Complexity | Cleanup |
|---------|----------|------------|---------|
| `spawn_link` | Simple requests | ⭐ Low | Automatic |
| Streaming | Real-time UI | ⭐⭐ Medium | Manual in terminate |
| GenServer | Persistent state | ⭐⭐⭐ High | Automatic via supervisor |

**Recommendation:** Start with `spawn_link` pattern, upgrade to GenServer if needed.

---

## Key Takeaway

**Always link agent processes to LiveView:**
```elixir
# ✅ Good - linked, auto-cleanup
spawn_link(fn -> run_agent() end)

# ❌ Bad - orphan if LiveView dies
spawn(fn -> run_agent() end)
```

**The `spawn_link/1` ensures graceful shutdown!** 🎯

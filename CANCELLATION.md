# Agent Execution Cancellation

This document describes the cancellation mechanism implemented for Yggdrasil AI agents.

## Overview

Yggdrasil AI now supports graceful cancellation of agent execution mid-run. This is useful for:
- User-initiated cancellation (stop button in UI)
- Timeout enforcement
- Resource cleanup when switching tasks
- Handling new messages while previous execution is running

## Implementation

### 1. AgentServer Cancellation (Recommended)

For GenServer-based agents (e.g., with LiveView):

```elixir
# Start an agent server
{:ok, pid} = Yggdrasil.AgentServer.start_link(
  session_id: "user-123",
  agent_config: %{
    model: "lmstudio:qwen/qwen3-30b",
    instructions: "You are a helpful assistant",
    tools: [&MyTools.search/2, &MyTools.analyze/2]
  }
)

# Send a message (starts execution)
Yggdrasil.AgentServer.send_message(pid, "Search for Elixir resources")

# Cancel execution mid-run
Yggdrasil.AgentServer.cancel_execution(pid)
# => {:ok, :cancelled}

# Or if nothing is running:
Yggdrasil.AgentServer.cancel_execution(pid)
# => {:ok, :no_execution}
```

#### Handling Cancellation Events

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    # Subscribe to agent events
    Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:#{socket.assigns.session_id}")
    {:ok, socket}
  end

  def handle_event("cancel", _params, socket) do
    # Cancel the running agent
    Yggdrasil.AgentServer.cancel_execution(socket.assigns.agent_pid)
    {:noreply, socket}
  end

  def handle_info({:agent_cancelled, reason}, socket) do
    # Handle cancellation
    socket = put_flash(socket, :info, "Agent execution cancelled: #{reason}")
    {:noreply, socket}
  end

  def handle_info({:agent_response, response, _msg}, socket) do
    # Handle successful completion
    {:noreply, update_messages(socket, response)}
  end
end
```

### 2. Direct Agent Cancellation

For direct `Agent.run/3` calls, use Task-based cancellation:

```elixir
# Start agent in a task
task = Task.async(fn ->
  Yggdrasil.Agent.run(agent, "Do something complex", max_iterations: 20)
end)

# Do other work...
Process.sleep(5000)

# Cancel after timeout
Task.shutdown(task, 5_000)  # 5 second grace period
```

### 3. Custom Cancellation Logic

Pass a cancellation check function:

```elixir
# Create a cancellation flag
cancellation_ref = :atomics.new(1, [])
:atomics.put(cancellation_ref, 1, 0)

# Start agent with cancellation check
task = Task.async(fn ->
  Yggdrasil.Agent.run(agent, "Long running task",
    cancellation_check: fn ->
      case :atomics.get(cancellation_ref, 1) do
        1 -> throw({:cancelled, "User requested cancellation"})
        0 -> :ok
      end
    end
  )
end)

# Later, trigger cancellation
:atomics.put(cancellation_ref, 1, 1)
```

## Architecture

### AgentServer State

```elixir
%{
  session_id: String.t(),
  agent: Agent.t() | ReActAgent.t(),
  conversation_history: list(),
  current_task: Task.t() | nil,        # Tracks running task
  cancelled: boolean(),                # Cancellation flag
  # ...
}
```

### AgentRunner Loop

The runner checks for cancellation before each iteration:

```elixir
defp execute_loop(state, messages) do
  # Check cancellation before iteration
  case check_cancellation(state) do
    {:error, _} = err -> err
    :ok -> do_iteration(state, messages)
  end
end
```

### Error Handling

Cancelled executions return `{:error, %Yggdrasil.Errors.ExecutionCancelled{}}`:

```elixir
case Yggdrasil.Agent.run(agent, prompt, cancellation_check: check_fn) do
  {:ok, result} ->
    # Success

  {:error, %Yggdrasil.Errors.ExecutionCancelled{reason: reason}} ->
    # Cancelled
    IO.puts("Execution cancelled: #{reason}")

  {:error, error} ->
    # Other error
end
```

## Features

### ✅ Graceful Shutdown
- Task.shutdown with configurable timeout
- Resources cleaned up properly
- State reset for next execution

### ✅ Event Broadcasting
- PubSub messages for cancellation events
- LiveView can react to cancellation
- Conversation history preserved

### ✅ Automatic Task Management
- AgentServer tracks current task
- New messages cancel previous execution
- No manual task tracking needed

### ✅ Works with Both Agent Types
- Standard Agent
- ReActAgent
- Cancellation check passed through automatically

## Examples

See `examples/cancellation_demo.exs` for a complete working example.

## Testing

Run the demo:
```bash
mix run examples/cancellation_demo.exs
```

## Implementation Details

### Files Modified

1. **lib/exadantic/agent_server.ex**
   - Added `current_task` and `cancelled` to state
   - Implemented `cancel_execution/1` API
   - Added `check_cancelled/1` helper
   - Task tracking via `Task.async`

2. **lib/exadantic/agent_runner.ex**
   - Added `:cancellation_check` option
   - Checks cancellation before each iteration
   - Returns `ExecutionCancelled` error on cancel

3. **lib/exadantic/errors.ex**
   - Added `ExecutionCancelled` exception type

### Key Design Decisions

**Why Task.async instead of Task.start?**
- Task.async provides a task reference we can track
- Enables proper cleanup with Task.shutdown
- Allows monitoring via Task.await if needed

**Why check at iteration level?**
- Tool execution may be long-running
- Can't interrupt mid-tool without coordination
- Iteration boundary is safe cancellation point

**Why use throw/catch for cancellation?**
- Allows deep call stack interruption
- Distinguishes from normal errors
- Clean control flow for cancellation path

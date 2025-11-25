# LiveView Chat with Yggdrasil AI

Complete guide for building a real-time chat interface with Yggdrasil agents using Phoenix LiveView and PubSub.

## Architecture Overview

```
┌─────────────────┐
│  Phoenix        │
│  LiveView       │
│  (UI Process)   │
└────────┬────────┘
         │
         │ spawns & links
         ▼
┌─────────────────┐      PubSub        ┌─────────────────┐
│  AgentServer    │◄─────messages─────►│   LiveView      │
│  (GenServer)    │                     │   Process       │
└────────┬────────┘                     └─────────────────┘
         │
         │ runs
         ▼
┌─────────────────┐
│  Yggdrasil      │
│  Agent          │
│  (ReAct/Std)    │
└─────────────────┘
```

**Key Features:**
- ✅ Agent GenServer linked to LiveView (dies when LiveView dies)
- ✅ Real-time bidirectional communication via PubSub
- ✅ Conversation history maintained by GenServer
- ✅ Support for both standard and ReAct agents
- ✅ Token usage tracking
- ✅ Status indicators (ready, thinking, error)
- ✅ Auto-scroll to latest messages

## Files Included

1. **`lib/exadantic/agent_server.ex`** - GenServer wrapper for agents with PubSub integration
2. **`examples/liveview_chat_example.ex`** - Complete single-page LiveView implementation

## Quick Start

### 1. Add to Your Phoenix Project

#### Step 1: Copy Files

```bash
# Copy AgentServer to your project
cp examples/liveview_chat_example.ex lib/my_app_web/live/agent_chat_live.ex
cp lib/exadantic/agent_server.ex lib/my_app/agent_server.ex
```

#### Step 2: Update Module Names

In `lib/my_app_web/live/agent_chat_live.ex`:
```elixir
defmodule MyAppWeb.AgentChatLive do
  use MyAppWeb, :live_view
  alias MyApp.AgentServer
  # ...
end
```

In `lib/my_app/agent_server.ex`:
```elixir
defmodule MyApp.AgentServer do
  # No changes needed if using MyApp.PubSub
end
```

#### Step 3: Ensure PubSub is Running

In `lib/my_app/application.ex`:
```elixir
children = [
  # ...
  {Phoenix.PubSub, name: MyApp.PubSub},
  # ...
]
```

#### Step 4: Add Route

In `lib/my_app_web/router.ex`:
```elixir
scope "/", MyAppWeb do
  pipe_through :browser

  live "/chat", AgentChatLive
end
```

#### Step 5: Configure Agent

In `lib/my_app_web/live/agent_chat_live.ex`, update the `agent_config`:

```elixir
agent_config = %{
  model: "lmstudio:qwen/qwen3-30b-a3b-2507",  # or "openai:gpt-4"
  type: :react,  # or :standard
  instructions: "You are a helpful assistant",
  tools: [
    # Add your custom tools
    &MyApp.Tools.search/2,
    &MyApp.Tools.calculate/2,
  ],
  model_settings: %{
    temperature: 0.7,
    max_tokens: 2000
  }
}
```

### 2. Run Your App

```bash
mix phx.server
```

Visit: http://localhost:4000/chat

## How It Works

### Message Flow

1. **User sends message** → LiveView `phx-click="send_message"`
2. **LiveView broadcasts** → PubSub `{:user_message, msg}`
3. **AgentServer receives** → Processes message with agent
4. **AgentServer broadcasts** → PubSub `{:agent_response, response}`
5. **LiveView receives** → Updates UI with response

### Process Lifecycle

```elixir
# When LiveView mounts:
1. Generate unique session_id
2. Start AgentServer linked to LiveView
3. Subscribe to PubSub topic "agent:#{session_id}"
4. Render initial UI

# When user sends message:
1. Add message to UI immediately
2. Broadcast to AgentServer via PubSub
3. Show "thinking" indicator

# When agent responds:
1. AgentServer runs agent asynchronously
2. Broadcasts response via PubSub
3. LiveView receives and updates UI
4. Hide "thinking" indicator

# When LiveView dies (user closes page):
1. LiveView process terminates
2. AgentServer dies automatically (linked)
3. Conversation history is lost
```

## Customization Options

### Use Standard Agent

```elixir
agent_config = %{
  model: "openai:gpt-4",
  type: :standard,  # Changed from :react
  instructions: "Be helpful and concise",
  tools: []
}
```

### Add Custom Tools

```elixir
defmodule MyApp.Tools do
  def search(_ctx, %{"query" => query}) do
    # Your search implementation
    MyApp.Search.perform(query)
  end

  def calculate(_ctx, %{"expression" => expr}) do
    # Your calculation implementation
    Code.eval_string(expr) |> elem(0)
  end
end

# In agent_config:
tools: [
  &MyApp.Tools.search/2,
  &MyApp.Tools.calculate/2
]
```

### Persist Conversation History

Add to your LiveView:

```elixir
def handle_info({:agent_response, content, metadata}, socket) do
  # Save to database
  MyApp.Chats.save_message(socket.assigns.session_id, :assistant, content)

  # ... rest of handler
end
```

### Multi-User Support

Each user gets their own AgentServer:

```elixir
def mount(_params, session, socket) do
  user_id = session["user_id"]
  session_id = "user:#{user_id}"

  # Each user has their own agent
  {:ok, agent_pid} = AgentServer.start_link(
    session_id: session_id,
    agent_config: agent_config
  )

  # ...
end
```

## Advanced Features

### 1. Add Typing Indicators

Already included! The LiveView shows a bouncing dot animation when `agent_status == :thinking`.

### 2. Token Budget Warnings

```elixir
def handle_info({:agent_response, content, metadata}, socket) do
  total_tokens = socket.assigns.total_tokens + metadata.usage.total_tokens

  socket = if total_tokens > 10_000 do
    put_flash(socket, :warning, "High token usage: #{total_tokens}")
  else
    socket
  end

  # ...
end
```

### 3. Rate Limiting

```elixir
def handle_event("send_message", %{"message" => msg}, socket) do
  case check_rate_limit(socket.assigns.session_id) do
    :ok ->
      # Process message

    {:error, :rate_limited} ->
      {:noreply, put_flash(socket, :error, "Please slow down")}
  end
end
```

### 4. Message Persistence

```elixir
# In AgentServer
def handle_cast({:user_message, message}, state) do
  # Save to database
  MyApp.Chats.save_message(state.session_id, :user, message)

  # ... rest of handler
end
```

### 5. Load Previous Conversations

```elixir
def mount(_params, _session, socket) do
  # Load previous messages from DB
  messages = MyApp.Chats.get_messages(session_id)

  socket = assign(socket, :messages, messages)

  # ... rest of mount
end
```

## Styling

The example uses Tailwind CSS classes. Customize the styles in `render/1`:

### Dark Mode

```elixir
# Change:
<div class="bg-gray-50">  # to bg-gray-900
<div class="bg-white">    # to bg-gray-800
<div class="text-gray-900"> # to text-gray-100
```

### Different Layout

```elixir
# Sidebar layout:
<div class="flex h-screen">
  <div class="w-64 bg-gray-800"><!-- Sidebar --></div>
  <div class="flex-1"><!-- Chat --></div>
</div>
```

## Troubleshooting

### Agent not responding

1. Check PubSub is running: `Phoenix.PubSub.subscribers(MyApp.PubSub, "agent:test")`
2. Check agent process is alive: `Process.alive?(socket.assigns.agent_pid)`
3. Check logs for errors

### Messages not showing

1. Verify `phx-hook="ScrollToBottom"` is on messages container
2. Check browser console for JavaScript errors
3. Verify assigns are being updated: `IO.inspect(socket.assigns.messages)`

### High latency

1. Use faster model (e.g., `gpt-3.5-turbo` instead of `gpt-4`)
2. Reduce `max_tokens` in model_settings
3. Use standard agent instead of ReAct for simple queries

### Memory leaks

1. Ensure agents are linked to LiveView
2. Clean up conversation history periodically
3. Set max message limit

## Production Considerations

### 1. Session Management

```elixir
# Use DynamicSupervisor for agent processes
defmodule MyApp.AgentSupervisor do
  use DynamicSupervisor

  def start_agent(session_id, config) do
    DynamicSupervisor.start_child(__MODULE__, {
      AgentServer,
      session_id: session_id,
      agent_config: config
    })
  end
end
```

### 2. Graceful Shutdown

```elixir
def terminate(reason, socket) do
  # Save conversation before shutdown
  if socket.assigns[:agent_pid] do
    history = AgentServer.get_history(socket.assigns.agent_pid)
    MyApp.Chats.save_conversation(socket.assigns.session_id, history)
  end

  :ok
end
```

### 3. Error Recovery

```elixir
def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
  Logger.error("Agent crashed: #{inspect(reason)}")

  # Restart agent
  {:ok, new_agent_pid} = AgentServer.start_link(
    session_id: socket.assigns.session_id,
    agent_config: get_agent_config()
  )

  socket =
    socket
    |> assign(:agent_pid, new_agent_pid)
    |> put_flash(:info, "Reconnected to agent")

  {:noreply, socket}
end
```

### 4. Load Balancing

For high traffic, run multiple nodes:

```elixir
# In config/runtime.exs
config :my_app, MyApp.PubSub,
  adapter: Phoenix.PubSub.PG2  # Works across nodes
```

## Example Deployment

### Using Fly.io

```bash
# Dockerfile already includes PubSub support
fly launch
fly deploy
```

### Using Heroku

```bash
heroku create
git push heroku main
heroku open /chat
```

## Testing

### Unit Test AgentServer

```elixir
defmodule MyApp.AgentServerTest do
  use ExUnit.Case

  test "sends response via PubSub" do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:test")

    {:ok, pid} = AgentServer.start_link(
      session_id: "test",
      agent_config: %{model: "openai:gpt-4", type: :standard}
    )

    AgentServer.send_message(pid, "Hello")

    assert_receive {:agent_response, response, _metadata}, 5000
    assert is_binary(response)
  end
end
```

### Integration Test LiveView

```elixir
defmodule MyAppWeb.AgentChatLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  test "chat flow", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat")

    # Send message
    view
    |> form("#chat-form", message: "Hello")
    |> render_submit()

    # Wait for response
    assert render(view) =~ "Hello"
  end
end
```

## Performance Tips

1. **Use streaming** for long responses (not shown in example)
2. **Limit conversation history** to last 20 messages
3. **Use GPT-3.5** for simple queries, GPT-4 for complex
4. **Cache common queries** in Redis
5. **Use ReAct only when needed** - it uses more tokens

## Security Considerations

1. **Rate limiting** per user/IP
2. **Input validation** on messages
3. **Token budget limits** per user
4. **Content filtering** for inappropriate content
5. **Authentication** required for access

## Next Steps

- [ ] Add message streaming
- [ ] Implement message editing
- [ ] Add file upload support
- [ ] Build chat history sidebar
- [ ] Add user authentication
- [ ] Implement message search
- [ ] Add export conversation feature

## Resources

- [Phoenix LiveView Docs](https://hexdocs.pm/phoenix_live_view)
- [Phoenix PubSub Docs](https://hexdocs.pm/phoenix_pubsub)
- [Yggdrasil Docs](../README.md)
- [ReAct Paper](https://arxiv.org/abs/2210.03629)

## Support

For issues or questions:
- GitHub Issues: https://github.com/yourusername/exadantic_ai/issues
- Example Code: `examples/liveview_chat_example.ex`
- AgentServer: `lib/exadantic/agent_server.ex`

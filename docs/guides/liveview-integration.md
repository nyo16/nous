# LiveView Integration with Nous AI

Comprehensive guide for integrating Nous AI agents with Phoenix LiveView, covering real-time streaming, multi-user coordination, and production patterns.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Basic LiveView Integration](#basic-liveview-integration)
3. [Streaming Patterns](#streaming-patterns)
4. [GenServer Agent Management](#genserver-agent-management)
5. [PubSub Multi-User Coordination](#pubsub-multi-user-coordination)
6. [Production Patterns](#production-patterns)
7. [Error Handling & Recovery](#error-handling--recovery)
8. [Testing Strategies](#testing-strategies)
9. [Performance Optimization](#performance-optimization)
10. [Complete Examples](#complete-examples)

---

## Quick Start

The fastest way to get AI agents working in LiveView:

```elixir
defmodule MyAppWeb.ChatLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    # Initialize agent once on mount and keep it in state
    agent = Nous.new("anthropic:claude-3-5-sonnet",
      instructions: "You are a helpful assistant."
    )

    socket = assign(socket,
      agent: agent,
      messages: [],
      input: "",
      streaming: false
    )

    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if not socket.assigns.streaming do
      # Spawn streaming in background, passing the agent from state
      parent = self()
      spawn_link(fn -> stream_response(parent, socket.assigns.agent, message) end)

      socket = assign(socket, :streaming, true, :input, "")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_chunk, text}, socket) do
    # Update UI with streaming text
    {:noreply, push_event(socket, "append_text", %{text: text})}
  end

  def handle_info({:stream_complete, final_message}, socket) do
    messages = socket.assigns.messages ++ [final_message]
    socket = assign(socket, :messages, messages, :streaming, false)
    {:noreply, socket}
  end

  defp stream_response(parent, agent, prompt) do
    # Use the agent passed as parameter instead of creating a new one
    Nous.run_stream(agent, prompt)
    |> Stream.each(fn
      {:text_delta, text} -> send(parent, {:stream_chunk, text})
      {:finish, result} -> send(parent, {:stream_complete, %{role: :assistant, content: result.output}})
    end)
    |> Stream.run()
  end

  def render(assigns) do
    # Your LiveView template here
  end
end
```

---

## Basic LiveView Integration

### Simple Agent Interaction

The most basic pattern for LiveView + AI:

```elixir
defmodule MyAppWeb.SimpleChatLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    # Initialize agent on mount
    agent = Nous.new("anthropic:claude-3-5-sonnet",
      instructions: "You are a helpful assistant in a web chat."
    )

    socket = assign(socket,
      agent: agent,
      messages: [],
      input: "",
      loading: false
    )

    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if socket.assigns.loading do
      {:noreply, socket}
    else
      # Add user message
      user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [user_msg]

      # Start async AI response
      task = Task.async(fn ->
        case Nous.run(socket.assigns.agent, message) do
          {:ok, result} -> {:ok, result.output}
          {:error, error} -> {:error, "AI Error: #{inspect(error)}"}
        end
      end)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> assign(:loading, true)
        |> assign(:current_task, task)

      {:noreply, socket}
    end
  end

  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_info({ref, result}, socket) when socket.assigns.current_task.ref == ref do
    # Task completed
    Process.demonitor(ref, [:flush])

    {messages, socket} = case result do
      {:ok, ai_response} ->
        ai_msg = %{role: :assistant, content: ai_response, timestamp: DateTime.utc_now()}
        {socket.assigns.messages ++ [ai_msg], socket}

      {:error, error_msg} ->
        error_msg = %{role: :error, content: error_msg, timestamp: DateTime.utc_now()}
        {socket.assigns.messages ++ [error_msg], socket}
    end

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:loading, false)
      |> assign(:current_task, nil)

    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns.current_task && socket.assigns.current_task.ref == ref do
      # Task crashed
      error_msg = %{role: :error, content: "Request failed: #{inspect(reason)}", timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [error_msg]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:loading, false)
        |> assign(:current_task, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end
end
```

### Form Handling and Validation

```elixir
defmodule MyAppWeb.SmartFormLive do
  use Phoenix.LiveView
  import Ecto.Changeset

  def mount(_params, _session, socket) do
    agent = Nous.new("anthropic:claude-3-5-sonnet",
      instructions: """
      You help users fill out forms intelligently.
      Suggest improvements, catch errors, and provide helpful hints.
      Be concise and actionable in your suggestions.
      """
    )

    changeset = change(%{name: "", email: "", message: ""})

    socket = assign(socket,
      agent: agent,
      changeset: changeset,
      ai_suggestions: [],
      validating: false
    )

    {:ok, socket}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    changeset = validate_form(params)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> maybe_get_ai_suggestions(params)

    {:noreply, socket}
  end

  def handle_event("submit", %{"form" => params}, socket) do
    changeset = validate_form(params)

    if changeset.valid? do
      # Process form submission
      {:noreply, put_flash(socket, :info, "Form submitted successfully!")}
    else
      {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp validate_form(params) do
    types = %{name: :string, email: :string, message: :string}

    {%{}, types}
    |> cast(params, [:name, :email, :message])
    |> validate_required([:name, :email, :message])
    |> validate_format(:email, ~r/@/)
    |> validate_length(:message, min: 10)
  end

  defp maybe_get_ai_suggestions(socket, params) do
    if should_suggest?(params) and not socket.assigns.validating do
      parent = self()

      spawn_link(fn ->
        prompt = """
        User is filling out a contact form with:
        Name: "#{params["name"]}"
        Email: "#{params["email"]}"
        Message: "#{params["message"]}"

        Provide helpful, concise suggestions for improvement.
        Only suggest if there are clear issues or improvements.
        """

        case Nous.run(socket.assigns.agent, prompt) do
          {:ok, result} -> send(parent, {:ai_suggestions, result.output})
          {:error, _} -> send(parent, {:ai_suggestions, ""})
        end
      end)

      assign(socket, :validating, true)
    else
      socket
    end
  end

  def handle_info({:ai_suggestions, suggestions}, socket) do
    socket =
      socket
      |> assign(:ai_suggestions, parse_suggestions(suggestions))
      |> assign(:validating, false)

    {:noreply, socket}
  end

  defp should_suggest?(params) do
    # Only suggest when user has entered substantial content
    String.length(params["message"] || "") > 20
  end

  defp parse_suggestions(""), do: []
  defp parse_suggestions(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.take(3)  # Limit to 3 suggestions
  end
end
```

---

## Streaming Patterns

### Basic Text Streaming

```elixir
defmodule MyAppWeb.StreamingChatLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    socket = assign(socket,
      messages: [],
      input: "",
      streaming: false,
      current_response: "",
      stream_task: nil
    )

    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if not socket.assigns.streaming do
      user_msg = %{role: :user, content: message, id: generate_id()}
      messages = socket.assigns.messages ++ [user_msg]

      # Start streaming
      parent = self()
      task = Task.async(fn ->
        stream_ai_response(parent, message)
      end)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> assign(:streaming, true)
        |> assign(:current_response, "")
        |> assign(:stream_task, task)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stop_streaming", _params, socket) do
    if socket.assigns.stream_task do
      Task.shutdown(socket.assigns.stream_task, :brutal_kill)
    end

    # Save partial response
    if socket.assigns.current_response != "" do
      partial_msg = %{
        role: :assistant,
        content: socket.assigns.current_response <> "\n\n_(stopped)_",
        id: generate_id()
      }
      messages = socket.assigns.messages ++ [partial_msg]

      socket = assign(socket, :messages, messages)
    end

    socket =
      socket
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:stream_task, nil)

    {:noreply, socket}
  end

  # Stream chunk received
  def handle_info({:stream_chunk, text}, socket) do
    new_response = socket.assigns.current_response <> text

    socket =
      socket
      |> assign(:current_response, new_response)
      |> push_event("stream_text", %{text: text})

    {:noreply, socket}
  end

  # Stream completed
  def handle_info({:stream_complete, usage}, socket) do
    final_msg = %{
      role: :assistant,
      content: socket.assigns.current_response,
      id: generate_id(),
      usage: usage
    }

    messages = socket.assigns.messages ++ [final_msg]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:stream_task, nil)
      |> push_event("scroll_to_bottom", %{})

    {:noreply, socket}
  end

  # Stream error
  def handle_info({:stream_error, error}, socket) do
    error_msg = %{
      role: :error,
      content: "Stream error: #{inspect(error)}",
      id: generate_id()
    }

    messages = socket.assigns.messages ++ [error_msg]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:stream_task, nil)

    {:noreply, socket}
  end

  # Task completion/crash handling
  def handle_info({ref, _result}, socket) when socket.assigns.stream_task.ref == ref do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns.stream_task && socket.assigns.stream_task.ref == ref do
      error_msg = %{
        role: :error,
        content: "Connection lost: #{inspect(reason)}",
        id: generate_id()
      }

      messages = socket.assigns.messages ++ [error_msg]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming, false)
        |> assign(:current_response, "")
        |> assign(:stream_task, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp stream_ai_response(parent, prompt) do
    agent = Nous.new("anthropic:claude-3-5-sonnet")

    try do
      Nous.run_stream(agent, prompt)
      |> Stream.each(fn
        {:text_delta, text} ->
          send(parent, {:stream_chunk, text})

        {:finish, result} ->
          usage = if result, do: Map.from_struct(result.usage), else: %{}
          send(parent, {:stream_complete, usage})

        {:error, error} ->
          send(parent, {:stream_error, error})

        _ -> :ok
      end)
      |> Stream.run()
    rescue
      error ->
        send(parent, {:stream_error, error})
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64()
end
```

### Advanced Streaming with Buffering

```elixir
defmodule MyAppWeb.BufferedStreamingLive do
  use Phoenix.LiveView

  @buffer_size 50  # Characters to buffer before UI update
  @buffer_timeout 100  # Max ms to wait before flushing buffer

  def mount(_params, _session, socket) do
    socket = assign(socket,
      messages: [],
      streaming: false,
      buffer: "",
      buffer_timer: nil,
      chars_buffered: 0
    )

    {:ok, socket}
  end

  def handle_info({:stream_chunk, text}, socket) do
    new_buffer = socket.assigns.buffer <> text
    chars_buffered = socket.assigns.chars_buffered + String.length(text)

    socket = assign(socket, :buffer, new_buffer, :chars_buffered, chars_buffered)

    cond do
      # Buffer is full - flush immediately
      chars_buffered >= @buffer_size ->
        flush_buffer(socket)

      # First chunk - start timer
      socket.assigns.buffer_timer == nil ->
        timer = Process.send_after(self(), :flush_buffer, @buffer_timeout)
        assign(socket, :buffer_timer, timer)

      # Buffer accumulating - wait for timer or full buffer
      true ->
        socket
    end
    |> then(&{:noreply, &1})
  end

  def handle_info(:flush_buffer, socket) do
    {:noreply, flush_buffer(socket)}
  end

  def handle_info({:stream_complete, usage}, socket) do
    # Final flush and cleanup
    socket = flush_buffer(socket)

    # Mark streaming as complete
    socket = assign(socket, :streaming, false)
    {:noreply, socket}
  end

  defp flush_buffer(socket) do
    if socket.assigns.buffer != "" do
      # Cancel existing timer
      if socket.assigns.buffer_timer do
        Process.cancel_timer(socket.assigns.buffer_timer)
      end

      # Send buffered text to UI
      socket =
        socket
        |> push_event("append_text", %{text: socket.assigns.buffer})
        |> assign(:buffer, "")
        |> assign(:buffer_timer, nil)
        |> assign(:chars_buffered, 0)

      socket
    else
      socket
    end
  end
end
```

---

## GenServer Agent Management

### Stateful Agent Server

```elixir
defmodule MyApp.AgentServer do
  @moduledoc """
  GenServer that manages a persistent AI agent with conversation history.

  Features:
  - Persistent conversation history
  - Configurable agent settings
  - Automatic context management
  - Usage tracking
  """

  use GenServer
  require Logger

  defstruct [
    :agent,
    :conversation_id,
    :user_id,
    messages: [],
    total_tokens: 0,
    last_activity: nil,
    settings: %{}
  ]

  ## Client API

  def start_link(opts) do
    {user_id, opts} = Keyword.pop!(opts, :user_id)
    {conversation_id, opts} = Keyword.pop!(opts, :conversation_id)

    name = via_tuple({user_id, conversation_id})
    GenServer.start_link(__MODULE__, {user_id, conversation_id, opts}, name: name)
  end

  def send_message(user_id, conversation_id, message, opts \\ []) do
    case get_or_start_agent(user_id, conversation_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:send_message, message, opts}, 30_000)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message_stream(user_id, conversation_id, message, stream_to, opts \\ []) do
    case get_or_start_agent(user_id, conversation_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:send_message_stream, message, stream_to, opts}, 30_000)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_conversation(user_id, conversation_id) do
    case get_agent(user_id, conversation_id) do
      {:ok, pid} ->
        GenServer.call(pid, :get_conversation)

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_settings(user_id, conversation_id, settings) do
    case get_or_start_agent(user_id, conversation_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:update_settings, settings})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop_agent(user_id, conversation_id) do
    case get_agent(user_id, conversation_id) do
      {:ok, pid} ->
        GenServer.stop(pid)

      {:error, _} ->
        :ok
    end
  end

  ## Server Implementation

  def init({user_id, conversation_id, opts}) do
    # Load existing conversation if any
    messages = load_conversation(user_id, conversation_id)

    # Create agent with default or custom settings
    agent_settings = Keyword.get(opts, :agent_settings, default_agent_settings())
    agent = create_agent(agent_settings)

    state = %__MODULE__{
      agent: agent,
      user_id: user_id,
      conversation_id: conversation_id,
      messages: messages,
      total_tokens: calculate_total_tokens(messages),
      last_activity: DateTime.utc_now(),
      settings: agent_settings
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("Started agent server for user=#{user_id}, conversation=#{conversation_id}")
    {:ok, state}
  end

  def handle_call({:send_message, message, opts}, _from, state) do
    # Add user message to history
    user_msg = %{
      role: :user,
      content: message,
      timestamp: DateTime.utc_now(),
      id: generate_id()
    }

    messages = state.messages ++ [user_msg]

    # Get AI response
    case Nous.run(state.agent, messages) do
      {:ok, result} ->
        ai_msg = %{
          role: :assistant,
          content: result.output,
          timestamp: DateTime.utc_now(),
          id: generate_id(),
          usage: result.usage
        }

        new_messages = messages ++ [ai_msg]
        new_total = state.total_tokens + (result.usage.total_tokens || 0)

        # Persist conversation
        save_conversation(state.user_id, state.conversation_id, new_messages)

        new_state = %{state |
          messages: new_messages,
          total_tokens: new_total,
          last_activity: DateTime.utc_now()
        }

        {:reply, {:ok, ai_msg}, new_state}

      {:error, reason} ->
        Logger.error("Agent error: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message_stream, message, stream_to, opts}, _from, state) do
    # Add user message
    user_msg = %{
      role: :user,
      content: message,
      timestamp: DateTime.utc_now(),
      id: generate_id()
    }

    messages = state.messages ++ [user_msg]

    # Start streaming in separate process
    parent = self()
    stream_id = generate_id()

    spawn_link(fn ->
      stream_response(parent, stream_to, state.agent, messages, stream_id)
    end)

    # Return immediately with stream ID
    new_state = %{state |
      messages: messages,
      last_activity: DateTime.utc_now()
    }

    {:reply, {:ok, stream_id}, new_state}
  end

  def handle_call({:update_settings, settings}, _from, state) do
    new_agent = create_agent(settings)

    new_state = %{state |
      agent: new_agent,
      settings: settings,
      last_activity: DateTime.utc_now()
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:get_conversation, _from, state) do
    conversation = %{
      messages: state.messages,
      total_tokens: state.total_tokens,
      last_activity: state.last_activity,
      settings: state.settings
    }

    {:reply, {:ok, conversation}, state}
  end

  def handle_info({:stream_complete, stream_id, ai_message, usage}, state) do
    # Add completed message to history
    new_messages = state.messages ++ [ai_message]
    new_total = state.total_tokens + (usage.total_tokens || 0)

    # Persist updated conversation
    save_conversation(state.user_id, state.conversation_id, new_messages)

    new_state = %{state |
      messages: new_messages,
      total_tokens: new_total,
      last_activity: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  def handle_info(:cleanup_check, state) do
    # Check if agent should be stopped due to inactivity
    idle_time = DateTime.diff(DateTime.utc_now(), state.last_activity, :millisecond)

    if idle_time > idle_timeout() do
      Logger.info("Stopping idle agent: user=#{state.user_id}, conversation=#{state.conversation_id}")
      {:stop, :normal, state}
    else
      schedule_cleanup()
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp via_tuple({user_id, conversation_id}) do
    {:via, Registry, {MyApp.AgentRegistry, {user_id, conversation_id}}}
  end

  defp get_agent(user_id, conversation_id) do
    case Registry.lookup(MyApp.AgentRegistry, {user_id, conversation_id}) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp get_or_start_agent(user_id, conversation_id) do
    case get_agent(user_id, conversation_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        case MyApp.AgentSupervisor.start_agent(user_id: user_id, conversation_id: conversation_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp create_agent(settings) do
    model = Map.get(settings, :model, "anthropic:claude-3-5-sonnet")
    instructions = Map.get(settings, :instructions, "You are a helpful assistant.")

    Nous.new(model,
      instructions: instructions,
      model_settings: Map.get(settings, :model_settings, %{})
    )
  end

  defp stream_response(parent, stream_to, agent, messages, stream_id) do
    accumulated = ""

    try do
      Nous.run_stream(agent, messages)
      |> Stream.reduce("", fn
        {:text_delta, text}, acc ->
          new_acc = acc <> text
          send(stream_to, {:stream_chunk, stream_id, text})
          new_acc

        {:finish, result}, acc ->
          ai_message = %{
            role: :assistant,
            content: acc,
            timestamp: DateTime.utc_now(),
            id: generate_id(),
            usage: result.usage
          }

          send(stream_to, {:stream_complete, stream_id, ai_message})
          send(parent, {:stream_complete, stream_id, ai_message, result.usage})
          acc

        {:error, error}, acc ->
          send(stream_to, {:stream_error, stream_id, error})
          acc
      end)
    rescue
      error ->
        send(stream_to, {:stream_error, stream_id, error})
    end
  end

  # Configuration
  defp default_agent_settings do
    %{
      model: "anthropic:claude-3-5-sonnet",
      instructions: "You are a helpful assistant.",
      model_settings: %{temperature: 0.7}
    }
  end

  defp idle_timeout, do: 30 * 60 * 1000  # 30 minutes

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_check, 5 * 60 * 1000)  # Check every 5 minutes
  end

  # Persistence (implement based on your storage)
  defp load_conversation(_user_id, _conversation_id), do: []

  defp save_conversation(_user_id, _conversation_id, _messages), do: :ok

  defp calculate_total_tokens(messages) do
    messages
    |> Enum.filter(&Map.has_key?(&1, :usage))
    |> Enum.map(& &1.usage.total_tokens)
    |> Enum.sum()
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64()
end
```

### Agent Supervisor

```elixir
defmodule MyApp.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for managing AI agent processes.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_agent(opts) do
    child_spec = {MyApp.AgentServer, opts}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def stop_agent(user_id, conversation_id) do
    MyApp.AgentServer.stop_agent(user_id, conversation_id)
  end

  def list_agents do
    DynamicSupervisor.which_children(__MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 1000)
  end
end
```

---

## Nous.PubSub Integration

Nous provides a built-in PubSub abstraction (`Nous.PubSub`) that unifies all agent event broadcasting. Configure it once and all `AgentServer` instances, `Callbacks`, and Research Coordinator will broadcast events automatically.

### Configuration

```elixir
# config/config.exs
config :nous, pubsub: MyApp.PubSub
```

With this configuration, you no longer need to pass `pubsub: MyApp.PubSub` to every `AgentServer` — it's read automatically.

### Using AgentServer with Nous.PubSub

```elixir
defmodule MyAppWeb.ChatLive do
  use Phoenix.LiveView

  def mount(%{"session_id" => session_id}, _session, socket) do
    if connected?(socket) do
      # Subscribe to agent events (topic: "agent:{session_id}")
      Nous.PubSub.subscribe(MyApp.PubSub, "agent:#{session_id}")
    end

    # pubsub defaults to Nous.PubSub.configured_pubsub()
    {:ok, pid} = Nous.AgentServer.start_link(
      session_id: session_id,
      agent_config: %{model: "openai:gpt-4", instructions: "Be helpful."}
    )

    {:ok, assign(socket, agent: pid, session_id: session_id)}
  end

  # Events arrive automatically via PubSub
  def handle_info({:agent_delta, text}, socket), do: ...
  def handle_info({:agent_complete, result}, socket), do: ...
  def handle_info({:tool_call, call}, socket), do: ...
end
```

### Async HITL Approval

For tools that require human approval, `Nous.PubSub.Approval` provides an async approval handler compatible with `Nous.Plugins.HumanInTheLoop`:

```elixir
# In your agent setup:
deps = %{
  hitl_config: %{
    tools: ["send_email", "delete_record"],
    handler: Nous.PubSub.Approval.handler(
      session_id: session_id,
      timeout: :timer.minutes(5)
    )
  }
}

# In your LiveView:
def handle_info({:approval_required, info}, socket) do
  # info: %{tool_call_id: ..., name: ..., arguments: ..., session_id: ...}
  {:noreply, assign(socket, pending_approval: info)}
end

def handle_event("approve", _params, socket) do
  info = socket.assigns.pending_approval
  Nous.PubSub.Approval.respond(MyApp.PubSub, info.session_id, info.tool_call_id, :approve)
  {:noreply, assign(socket, pending_approval: nil)}
end

def handle_event("reject", _params, socket) do
  info = socket.assigns.pending_approval
  Nous.PubSub.Approval.respond(MyApp.PubSub, info.session_id, info.tool_call_id, :reject)
  {:noreply, assign(socket, pending_approval: nil)}
end
```

### Topic Builders

Nous provides standardized topic builders:

| Function | Topic Format | Used By |
|----------|-------------|---------|
| `Nous.PubSub.agent_topic(id)` | `"nous:agent:{id}"` | Agent events |
| `Nous.PubSub.research_topic(id)` | `"nous:research:{id}"` | Research progress |
| `Nous.PubSub.approval_topic(id)` | `"nous:approval:{id}"` | HITL responses |

Note: `AgentServer` uses the topic `"agent:{session_id}"` (without the `nous:` prefix) for backward compatibility.

---

## PubSub Multi-User Coordination

### Room-Based Chat with AI Moderation

```elixir
defmodule MyAppWeb.RoomChatLive do
  use Phoenix.LiveView
  alias Phoenix.PubSub

  def mount(%{"room_id" => room_id}, %{"user_id" => user_id}, socket) do
    if connected?(socket) do
      # Subscribe to room updates
      PubSub.subscribe(MyApp.PubSub, "room:#{room_id}")
      PubSub.subscribe(MyApp.PubSub, "room:#{room_id}:user:#{user_id}")

      # Join the room
      MyApp.RoomManager.join_room(room_id, user_id)
    end

    socket = assign(socket,
      room_id: room_id,
      user_id: user_id,
      messages: [],
      participants: [],
      input: "",
      ai_agent_active: true,
      user_typing: MapSet.new()
    )

    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if String.trim(message) != "" do
      # Broadcast message to room
      MyApp.RoomManager.send_message(
        socket.assigns.room_id,
        socket.assigns.user_id,
        message
      )

      {:noreply, assign(socket, :input, "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("typing", %{"typing" => typing}, socket) do
    # Broadcast typing indicator
    PubSub.broadcast(MyApp.PubSub, "room:#{socket.assigns.room_id}", {
      :user_typing,
      socket.assigns.user_id,
      typing
    })

    {:noreply, socket}
  end

  def handle_event("toggle_ai", _params, socket) do
    new_status = not socket.assigns.ai_agent_active

    MyApp.RoomManager.toggle_ai_agent(socket.assigns.room_id, new_status)

    {:noreply, assign(socket, :ai_agent_active, new_status)}
  end

  # New message in room
  def handle_info({:new_message, message}, socket) do
    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, :messages, messages)}
  end

  # AI response
  def handle_info({:ai_response, message}, socket) do
    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, :messages, messages)}
  end

  # Stream chunk from AI
  def handle_info({:ai_stream_chunk, chunk_id, text}, socket) do
    {:noreply, push_event(socket, "ai_stream_chunk", %{chunk_id: chunk_id, text: text})}
  end

  # AI stream complete
  def handle_info({:ai_stream_complete, message}, socket) do
    messages = socket.assigns.messages ++ [message]
    {:noreply, assign(socket, :messages, messages)}
  end

  # User typing indicators
  def handle_info({:user_typing, user_id, typing}, socket) do
    user_typing = if typing do
      MapSet.put(socket.assigns.user_typing, user_id)
    else
      MapSet.delete(socket.assigns.user_typing, user_id)
    end

    {:noreply, assign(socket, :user_typing, user_typing)}
  end

  # Participants updated
  def handle_info({:participants_updated, participants}, socket) do
    {:noreply, assign(socket, :participants, participants)}
  end

  def terminate(_reason, socket) do
    if socket.assigns[:room_id] && socket.assigns[:user_id] do
      MyApp.RoomManager.leave_room(socket.assigns.room_id, socket.assigns.user_id)
    end
    :ok
  end
end
```

### Room Manager with AI Agent

```elixir
defmodule MyApp.RoomManager do
  @moduledoc """
  Manages chat rooms with AI agent integration.
  """

  use GenServer
  alias Phoenix.PubSub

  defstruct [
    :room_id,
    participants: MapSet.new(),
    messages: [],
    ai_agent_active: true,
    ai_agent: nil,
    message_count: 0,
    last_ai_response: nil
  ]

  ## Client API

  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via_tuple(room_id))
  end

  def join_room(room_id, user_id) do
    ensure_room_exists(room_id)
    GenServer.call(via_tuple(room_id), {:join, user_id})
  end

  def leave_room(room_id, user_id) do
    case get_room(room_id) do
      {:ok, pid} -> GenServer.call(pid, {:leave, user_id})
      {:error, _} -> :ok
    end
  end

  def send_message(room_id, user_id, content) do
    ensure_room_exists(room_id)
    GenServer.call(via_tuple(room_id), {:send_message, user_id, content})
  end

  def toggle_ai_agent(room_id, active) do
    ensure_room_exists(room_id)
    GenServer.call(via_tuple(room_id), {:toggle_ai_agent, active})
  end

  ## Server Implementation

  def init(room_id) do
    # Create AI agent for this room
    agent = Nous.new("anthropic:claude-3-5-sonnet",
      instructions: """
      You are an AI assistant in a group chat room.
      - Be helpful and engaging
      - Only respond when directly addressed or when the conversation needs guidance
      - Keep responses concise for chat format
      - Be respectful and moderate if needed
      - Use the participants' names when possible
      """
    )

    state = %__MODULE__{
      room_id: room_id,
      ai_agent: agent
    }

    {:ok, state}
  end

  def handle_call({:join, user_id}, _from, state) do
    if not MapSet.member?(state.participants, user_id) do
      new_participants = MapSet.put(state.participants, user_id)

      # Broadcast participant update
      broadcast_participants(state.room_id, new_participants)

      # Send recent messages to new participant
      send_message_history(user_id, state.room_id, state.messages)

      {:reply, :ok, %{state | participants: new_participants}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:leave, user_id}, _from, state) do
    new_participants = MapSet.delete(state.participants, user_id)

    broadcast_participants(state.room_id, new_participants)

    new_state = %{state | participants: new_participants}

    # Stop room if empty
    if MapSet.size(new_participants) == 0 do
      {:stop, :normal, :ok, new_state}
    else
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:send_message, user_id, content}, _from, state) do
    message = %{
      id: generate_id(),
      user_id: user_id,
      content: content,
      timestamp: DateTime.utc_now(),
      type: :user
    }

    new_messages = state.messages ++ [message]
    new_message_count = state.message_count + 1

    # Broadcast message to room
    broadcast_message(state.room_id, message)

    new_state = %{state |
      messages: new_messages,
      message_count: new_message_count
    }

    # Check if AI should respond
    new_state = maybe_trigger_ai_response(new_state, message)

    {:reply, :ok, new_state}
  end

  def handle_call({:toggle_ai_agent, active}, _from, state) do
    new_state = %{state | ai_agent_active: active}
    {:reply, :ok, new_state}
  end

  def handle_info({:ai_stream_chunk, chunk_id, text}, state) do
    # Broadcast AI stream chunk
    PubSub.broadcast(MyApp.PubSub, "room:#{state.room_id}", {
      :ai_stream_chunk,
      chunk_id,
      text
    })

    {:noreply, state}
  end

  def handle_info({:ai_stream_complete, message, usage}, state) do
    # Add AI message to history
    new_messages = state.messages ++ [message]

    # Broadcast complete message
    broadcast_message(state.room_id, message)

    new_state = %{state |
      messages: new_messages,
      last_ai_response: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  ## Private Functions

  defp via_tuple(room_id) do
    {:via, Registry, {MyApp.RoomRegistry, room_id}}
  end

  defp get_room(room_id) do
    case Registry.lookup(MyApp.RoomRegistry, room_id) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp ensure_room_exists(room_id) do
    case get_room(room_id) do
      {:ok, _pid} -> :ok
      {:error, :not_found} ->
        MyApp.RoomSupervisor.start_room(room_id)
        :ok
    end
  end

  defp maybe_trigger_ai_response(state, message) do
    if should_ai_respond?(state, message) do
      trigger_ai_response(state, message)
    else
      state
    end
  end

  defp should_ai_respond?(state, message) do
    state.ai_agent_active and (
      # AI mentioned by name
      String.contains?(String.downcase(message.content), ["ai", "assistant", "help"]) or
      # Question directed at group
      String.contains?(message.content, "?") or
      # First message in a while
      time_since_last_ai_response(state) > 300_000  # 5 minutes
    )
  end

  defp trigger_ai_response(state, trigger_message) do
    # Get recent conversation context
    recent_messages = Enum.take(state.messages, -10)

    # Create context prompt
    context = build_ai_context(recent_messages, state.participants)

    # Start streaming AI response
    parent = self()
    chunk_id = generate_id()

    spawn_link(fn ->
      stream_ai_response(parent, state.ai_agent, context, chunk_id)
    end)

    state
  end

  defp build_ai_context(messages, participants) do
    participant_list = participants |> Enum.join(", ")

    conversation = messages
    |> Enum.map(fn msg ->
      "#{msg.user_id}: #{msg.content}"
    end)
    |> Enum.join("\n")

    """
    You're in a chat room with participants: #{participant_list}

    Recent conversation:
    #{conversation}

    Respond helpfully and naturally to the conversation.
    """
  end

  defp stream_ai_response(parent, agent, context, chunk_id) do
    accumulated = ""

    Nous.run_stream(agent, context)
    |> Stream.reduce("", fn
      {:text_delta, text}, acc ->
        new_acc = acc <> text
        send(parent, {:ai_stream_chunk, chunk_id, text})
        new_acc

      {:finish, result}, acc ->
        ai_message = %{
          id: generate_id(),
          user_id: "AI Assistant",
          content: acc,
          timestamp: DateTime.utc_now(),
          type: :ai,
          usage: result.usage
        }

        send(parent, {:ai_stream_complete, ai_message, result.usage})
        acc

      _, acc -> acc
    end)
  end

  defp broadcast_message(room_id, message) do
    PubSub.broadcast(MyApp.PubSub, "room:#{room_id}", {:new_message, message})
  end

  defp broadcast_participants(room_id, participants) do
    participant_list = MapSet.to_list(participants)
    PubSub.broadcast(MyApp.PubSub, "room:#{room_id}", {:participants_updated, participant_list})
  end

  defp send_message_history(user_id, room_id, messages) do
    # Send recent messages to new participant
    recent_messages = Enum.take(messages, -20)

    Enum.each(recent_messages, fn message ->
      PubSub.broadcast(MyApp.PubSub, "room:#{room_id}:user:#{user_id}", {:new_message, message})
    end)
  end

  defp time_since_last_ai_response(state) do
    if state.last_ai_response do
      DateTime.diff(DateTime.utc_now(), state.last_ai_response, :millisecond)
    else
      999_999_999  # Very large number if no previous response
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64()
end
```

---

## Production Patterns

### Connection Resilience

```elixir
defmodule MyAppWeb.ResilientChatLive do
  use Phoenix.LiveView

  # Automatic reconnection and state recovery
  def mount(_params, session, socket) do
    socket = if connected?(socket) do
      # Restore state from session or database
      restore_chat_state(socket, session)
    else
      # Initial server render
      assign_default_state(socket)
    end

    {:ok, socket}
  end

  def handle_info({:connection_lost, reason}, socket) do
    socket =
      socket
      |> put_flash(:error, "Connection lost. Attempting to reconnect...")
      |> assign(:connection_status, :disconnected)
      |> push_event("connection_lost", %{reason: reason})

    # Attempt to reconnect AI agent
    schedule_reconnection()

    {:noreply, socket}
  end

  def handle_info(:attempt_reconnection, socket) do
    case reconnect_agent(socket.assigns.agent_config) do
      {:ok, agent} ->
        socket =
          socket
          |> put_flash(:info, "Reconnected successfully!")
          |> assign(:agent, agent)
          |> assign(:connection_status, :connected)

        {:noreply, socket}

      {:error, _reason} ->
        # Try again later
        schedule_reconnection()
        {:noreply, socket}
    end
  end

  defp restore_chat_state(socket, session) do
    # Implement state restoration logic
    socket
  end

  defp schedule_reconnection do
    Process.send_after(self(), :attempt_reconnection, 5000)
  end
end
```

### Performance Optimization

```elixir
defmodule MyAppWeb.OptimizedChatLive do
  use Phoenix.LiveView

  # Implement message pagination and virtual scrolling
  def mount(_params, _session, socket) do
    socket = assign(socket,
      messages: [],
      page_size: 50,
      current_page: 0,
      loading_messages: false,
      has_more_messages: true
    )

    # Load initial messages
    {:ok, load_messages(socket, 0)}
  end

  def handle_event("load_more_messages", _params, socket) do
    if socket.assigns.has_more_messages and not socket.assigns.loading_messages do
      next_page = socket.assigns.current_page + 1
      socket =
        socket
        |> assign(:loading_messages, true)
        |> load_messages(next_page)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Debounced typing indicators
  def handle_event("typing", %{"typing" => true}, socket) do
    # Cancel previous typing timer
    if socket.assigns[:typing_timer] do
      Process.cancel_timer(socket.assigns.typing_timer)
    end

    # Broadcast typing start
    broadcast_typing(socket.assigns.room_id, socket.assigns.user_id, true)

    # Set stop typing timer
    timer = Process.send_after(self(), :stop_typing, 3000)

    {:noreply, assign(socket, :typing_timer, timer)}
  end

  def handle_info(:stop_typing, socket) do
    broadcast_typing(socket.assigns.room_id, socket.assigns.user_id, false)
    {:noreply, assign(socket, :typing_timer, nil)}
  end

  # Message batching for high-frequency updates
  def handle_info({:batch_messages, messages}, socket) do
    new_messages = socket.assigns.messages ++ messages
    {:noreply, assign(socket, :messages, new_messages)}
  end

  defp load_messages(socket, page) do
    # Simulate loading from database with pagination
    case MyApp.Messages.get_room_messages(
      socket.assigns.room_id,
      page,
      socket.assigns.page_size
    ) do
      {messages, has_more} ->
        all_messages = if page == 0 do
          messages
        else
          messages ++ socket.assigns.messages
        end

        assign(socket,
          messages: all_messages,
          current_page: page,
          loading_messages: false,
          has_more_messages: has_more
        )
    end
  end
end
```

### Resource Management

```elixir
defmodule MyApp.ResourceManager do
  @moduledoc """
  Manages AI agent resources and prevents resource exhaustion.
  """

  use GenServer

  defstruct [
    active_agents: 0,
    max_agents: 100,
    agent_queue: :queue.new(),
    rate_limiter: %{},
    memory_monitor: nil
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def request_agent(user_id, priority \\ :normal) do
    GenServer.call(__MODULE__, {:request_agent, user_id, priority}, 10_000)
  end

  def release_agent(user_id) do
    GenServer.cast(__MODULE__, {:release_agent, user_id})
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def init(_) do
    # Start memory monitoring
    {:ok, memory_monitor} = :memsup.start_link()

    state = %__MODULE__{
      memory_monitor: memory_monitor
    }

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup, 60_000)

    {:ok, state}
  end

  def handle_call({:request_agent, user_id, priority}, from, state) do
    cond do
      # Check rate limiting
      rate_limited?(state, user_id) ->
        {:reply, {:error, :rate_limited}, state}

      # Check resource limits
      state.active_agents >= state.max_agents ->
        # Queue the request
        new_queue = :queue.in({from, user_id, priority}, state.agent_queue)
        {:noreply, %{state | agent_queue: new_queue}}

      # Resources available
      true ->
        new_state = %{state |
          active_agents: state.active_agents + 1,
          rate_limiter: update_rate_limiter(state.rate_limiter, user_id)
        }

        {:reply, {:ok, :agent_granted}, new_state}
    end
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      active_agents: state.active_agents,
      max_agents: state.max_agents,
      queued_requests: :queue.len(state.agent_queue),
      memory_usage: get_memory_usage()
    }

    {:reply, stats, state}
  end

  def handle_cast({:release_agent, user_id}, state) do
    new_state = %{state | active_agents: max(0, state.active_agents - 1)}

    # Process queue if space available
    new_state = process_agent_queue(new_state)

    {:noreply, new_state}
  end

  def handle_info(:cleanup, state) do
    # Clean up rate limiter
    now = System.system_time(:second)
    new_rate_limiter = Map.filter(state.rate_limiter, fn {_user, last_time} ->
      now - last_time < 300  # Keep entries for 5 minutes
    end)

    new_state = %{state | rate_limiter: new_rate_limiter}

    # Schedule next cleanup
    Process.send_after(self(), :cleanup, 60_000)

    {:noreply, new_state}
  end

  defp rate_limited?(state, user_id) do
    case Map.get(state.rate_limiter, user_id) do
      nil -> false
      last_request_time ->
        System.system_time(:second) - last_request_time < 10  # 10 second cooldown
    end
  end

  defp update_rate_limiter(rate_limiter, user_id) do
    Map.put(rate_limiter, user_id, System.system_time(:second))
  end

  defp process_agent_queue(state) do
    if state.active_agents < state.max_agents and not :queue.is_empty(state.agent_queue) do
      case :queue.out(state.agent_queue) do
        {{:value, {from, user_id, _priority}}, new_queue} ->
          GenServer.reply(from, {:ok, :agent_granted})

          %{state |
            active_agents: state.active_agents + 1,
            agent_queue: new_queue,
            rate_limiter: update_rate_limiter(state.rate_limiter, user_id)
          }

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp get_memory_usage do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        total = Keyword.get(data, :total_memory, 0)
        free = Keyword.get(data, :free_memory, 0)
        used = total - free

        %{
          total: total,
          used: used,
          free: free,
          usage_percent: if total > 0, do: Float.round(used / total * 100, 2), else: 0
        }

      _ ->
        %{total: 0, used: 0, free: 0, usage_percent: 0}
    end
  end
end
```

---

## Error Handling & Recovery

### Comprehensive Error Handling

```elixir
defmodule MyAppWeb.ErrorResilientChatLive do
  use Phoenix.LiveView
  require Logger

  def mount(_params, _session, socket) do
    # Set up error recovery
    socket = assign(socket,
      error_count: 0,
      last_error: nil,
      recovery_strategy: :automatic,
      max_retries: 3
    )

    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    case send_message_with_retry(socket, message) do
      {:ok, new_socket} ->
        # Reset error count on success
        {:noreply, assign(new_socket, :error_count, 0)}

      {:error, reason, new_socket} ->
        {:noreply, handle_message_error(new_socket, reason)}
    end
  end

  def handle_event("retry_last_action", _params, socket) do
    # Implement retry logic
    {:noreply, socket}
  end

  defp send_message_with_retry(socket, message, attempt \\ 1) do
    try do
      # Your message sending logic here
      case MyApp.AgentServer.send_message_stream(
        socket.assigns.user_id,
        socket.assigns.conversation_id,
        message,
        self()
      ) do
        {:ok, stream_id} ->
          new_socket =
            socket
            |> assign(:streaming, true)
            |> assign(:current_stream_id, stream_id)

          {:ok, new_socket}

        {:error, reason} when attempt < socket.assigns.max_retries ->
          # Exponential backoff
          :timer.sleep(attempt * 1000)
          send_message_with_retry(socket, message, attempt + 1)

        {:error, reason} ->
          {:error, reason, socket}
      end

    rescue
      error ->
        Logger.error("Message sending error: #{inspect(error)}")

        if attempt < socket.assigns.max_retries do
          :timer.sleep(attempt * 1000)
          send_message_with_retry(socket, message, attempt + 1)
        else
          {:error, error, socket}
        end
    end
  end

  defp handle_message_error(socket, reason) do
    error_count = socket.assigns.error_count + 1

    socket =
      socket
      |> assign(:error_count, error_count)
      |> assign(:last_error, reason)

    cond do
      error_count >= socket.assigns.max_retries ->
        socket
        |> put_flash(:error, "Multiple failures detected. Please refresh the page.")
        |> assign(:recovery_strategy, :manual)

      is_recoverable_error?(reason) ->
        socket
        |> put_flash(:warning, "Temporary issue detected. Retrying automatically...")
        |> schedule_recovery()

      true ->
        socket
        |> put_flash(:error, "Error: #{format_error(reason)}")
        |> assign(:recovery_strategy, :manual)
    end
  end

  defp is_recoverable_error?(reason) do
    case reason do
      %{message: message} when is_binary(message) ->
        String.contains?(message, ["timeout", "connection", "temporary"])

      {:timeout, _} -> true
      {:error, :timeout} -> true
      {:error, :connection_failed} -> true

      _ -> false
    end
  end

  defp schedule_recovery(socket) do
    Process.send_after(self(), :attempt_recovery, 5000)
    assign(socket, :recovery_scheduled, true)
  end

  def handle_info(:attempt_recovery, socket) do
    # Implement recovery logic
    socket =
      socket
      |> assign(:recovery_scheduled, false)
      |> clear_flash()

    {:noreply, socket}
  end

  defp format_error(error) do
    case error do
      %{message: message} -> message
      atom when is_atom(atom) -> Atom.to_string(atom)
      binary when is_binary(binary) -> binary
      _ -> "An unexpected error occurred"
    end
  end
end
```

### Circuit Breaker Pattern

```elixir
defmodule MyApp.AgentCircuitBreaker do
  @moduledoc """
  Circuit breaker for AI agent calls to prevent cascade failures.
  """

  use GenServer

  defstruct [
    state: :closed,  # :closed, :open, :half_open
    failure_count: 0,
    failure_threshold: 5,
    recovery_timeout: 30_000,
    last_failure_time: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def call_agent(fun) when is_function(fun) do
    GenServer.call(__MODULE__, {:call_agent, fun})
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def init(opts) do
    state = %__MODULE__{
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      recovery_timeout: Keyword.get(opts, :recovery_timeout, 30_000)
    }

    {:ok, state}
  end

  def handle_call({:call_agent, fun}, _from, state) do
    case state.state do
      :closed ->
        execute_call(fun, state)

      :open ->
        if should_attempt_reset?(state) do
          # Try half-open state
          new_state = %{state | state: :half_open}
          execute_call(fun, new_state)
        else
          {:reply, {:error, :circuit_open}, state}
        end

      :half_open ->
        execute_call(fun, state)
    end
  end

  def handle_call(:get_state, _from, state) do
    circuit_state = %{
      state: state.state,
      failure_count: state.failure_count,
      last_failure_time: state.last_failure_time
    }

    {:reply, circuit_state, state}
  end

  def handle_call(:reset, _from, state) do
    new_state = %{state |
      state: :closed,
      failure_count: 0,
      last_failure_time: nil
    }

    {:reply, :ok, new_state}
  end

  defp execute_call(fun, state) do
    try do
      result = fun.()

      # Success - close circuit
      new_state = %{state |
        state: :closed,
        failure_count: 0,
        last_failure_time: nil
      }

      {:reply, {:ok, result}, new_state}

    rescue
      error ->
        handle_failure(state, error)
    end
  end

  defp handle_failure(state, error) do
    new_failure_count = state.failure_count + 1

    new_state = %{state |
      failure_count: new_failure_count,
      last_failure_time: System.monotonic_time(:millisecond)
    }

    new_state = if new_failure_count >= state.failure_threshold do
      %{new_state | state: :open}
    else
      new_state
    end

    {:reply, {:error, error}, new_state}
  end

  defp should_attempt_reset?(state) do
    if state.last_failure_time do
      elapsed = System.monotonic_time(:millisecond) - state.last_failure_time
      elapsed >= state.recovery_timeout
    else
      true
    end
  end
end
```

---

## Testing Strategies

### LiveView Testing

```elixir
defmodule MyAppWeb.ChatLiveTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    # Set up test data
    user = create_user()
    conversation = create_conversation(user)

    %{user: user, conversation: conversation}
  end

  describe "chat functionality" do
    test "renders chat interface", %{conn: conn, user: user, conversation: conversation} do
      {:ok, view, html} = live(conn, "/chat/#{conversation.id}")

      assert html =~ "Chat"
      assert has_element?(view, "#message-input")
      assert has_element?(view, "[phx-click='send_message']")
    end

    test "sends and receives messages", %{conn: conn, conversation: conversation} do
      # Mock AI responses
      mock_agent_response()

      {:ok, view, _html} = live(conn, "/chat/#{conversation.id}")

      # Send a message
      view
      |> form("#chat-form", message: "Hello, AI!")
      |> render_submit()

      # Check user message appears
      assert has_element?(view, "[data-role='user']", "Hello, AI!")

      # Wait for AI response
      assert_receive {:ai_response, _message}, 5000

      # Check AI response appears
      assert has_element?(view, "[data-role='assistant']")
    end

    test "handles streaming responses", %{conn: conn, conversation: conversation} do
      mock_streaming_response()

      {:ok, view, _html} = live(conn, "/chat/#{conversation.id}")

      # Send message that triggers streaming
      view
      |> form("#chat-form", message: "Tell me a story")
      |> render_submit()

      # Check streaming indicator appears
      assert has_element?(view, ".streaming-indicator")

      # Simulate stream chunks
      send(view.pid, {:stream_chunk, "Once upon a time"})
      send(view.pid, {:stream_chunk, ", there was a brave"})
      send(view.pid, {:stream_complete, %{content: "Once upon a time, there was a brave knight."}})

      # Check final message
      assert has_element?(view, "[data-role='assistant']", "Once upon a time, there was a brave knight.")
      refute has_element?(view, ".streaming-indicator")
    end

    test "handles connection errors gracefully", %{conn: conn, conversation: conversation} do
      mock_agent_error()

      {:ok, view, _html} = live(conn, "/chat/#{conversation.id}")

      # Send message that will cause error
      view
      |> form("#chat-form", message: "This will cause an error")
      |> render_submit()

      # Check error message appears
      assert has_element?(view, ".error-message")
      assert has_element?(view, "[phx-click='retry_message']")
    end

    test "prevents multiple concurrent requests", %{conn: conn, conversation: conversation} do
      mock_slow_agent_response()

      {:ok, view, _html} = live(conn, "/chat/#{conversation.id}")

      # Send first message
      view
      |> form("#chat-form", message: "First message")
      |> render_submit()

      # Try to send second message while first is processing
      view
      |> form("#chat-form", message: "Second message")
      |> render_submit()

      # Check that input is disabled and second message is not sent
      assert has_element?(view, "#message-input[disabled]")
    end
  end

  describe "real-time features" do
    test "updates when other users send messages", %{conn: conn, conversation: conversation} do
      {:ok, view, _html} = live(conn, "/chat/#{conversation.id}")

      # Simulate message from another user
      other_user_message = %{
        id: "msg-123",
        user_id: "other-user",
        content: "Hello from another user",
        timestamp: DateTime.utc_now(),
        role: :user
      }

      send(view.pid, {:new_message, other_user_message})

      # Check message appears
      assert has_element?(view, "[data-message-id='msg-123']", "Hello from another user")
    end

    test "shows typing indicators", %{conn: conn, conversation: conversation} do
      {:ok, view, _html} = live(conn, "/chat/#{conversation.id}")

      # Simulate typing from another user
      send(view.pid, {:user_typing, "other-user", true})

      assert has_element?(view, ".typing-indicator", "other-user is typing...")

      # Stop typing
      send(view.pid, {:user_typing, "other-user", false})

      refute has_element?(view, ".typing-indicator")
    end
  end

  # Test helpers
  defp mock_agent_response do
    response = %{
      output: "Hello! How can I help you?",
      usage: %{total_tokens: 25}
    }

    Mox.stub(MockAgent, :run, fn _agent, _message -> {:ok, response} end)
  end

  defp mock_streaming_response do
    Mox.stub(MockAgent, :run_stream, fn _agent, _message ->
      [
        {:text_delta, "Hello!"},
        {:text_delta, " How can I"},
        {:text_delta, " help you?"},
        {:finish, %{output: "Hello! How can I help you?", usage: %{total_tokens: 25}}}
      ]
    end)
  end

  defp mock_agent_error do
    Mox.stub(MockAgent, :run, fn _agent, _message ->
      {:error, "Connection timeout"}
    end)
  end

  defp mock_slow_agent_response do
    Mox.stub(MockAgent, :run, fn _agent, _message ->
      Process.sleep(1000)
      {:ok, %{output: "Slow response", usage: %{total_tokens: 10}}}
    end)
  end
end
```

### GenServer Testing

```elixir
defmodule MyApp.AgentServerTest do
  use ExUnit.Case
  alias MyApp.AgentServer

  setup do
    user_id = "test-user"
    conversation_id = "test-conversation"

    {:ok, pid} = AgentServer.start_link(user_id: user_id, conversation_id: conversation_id)

    %{pid: pid, user_id: user_id, conversation_id: conversation_id}
  end

  describe "message handling" do
    test "sends and receives messages", %{pid: pid} do
      message = "Hello, AI!"

      assert {:ok, response} = GenServer.call(pid, {:send_message, message, []})
      assert response.role == :assistant
      assert is_binary(response.content)
      assert response.timestamp
    end

    test "maintains conversation history", %{pid: pid} do
      # Send multiple messages
      GenServer.call(pid, {:send_message, "First message", []})
      GenServer.call(pid, {:send_message, "Second message", []})

      {:ok, conversation} = GenServer.call(pid, :get_conversation)

      assert length(conversation.messages) == 4  # 2 user + 2 assistant
      assert Enum.at(conversation.messages, 0).content == "First message"
      assert Enum.at(conversation.messages, 2).content == "Second message"
    end

    test "handles streaming messages", %{pid: pid} do
      parent = self()
      message = "Tell me a story"

      assert {:ok, stream_id} = GenServer.call(pid, {:send_message_stream, message, parent, []})
      assert is_binary(stream_id)

      # Should receive stream events
      assert_receive {:stream_chunk, ^stream_id, _text}, 5000
      assert_receive {:stream_complete, ^stream_id, response}, 10000

      assert response.role == :assistant
      assert is_binary(response.content)
    end
  end

  describe "settings management" do
    test "updates agent settings", %{pid: pid} do
      new_settings = %{
        model: "anthropic:claude-3-5-sonnet",
        instructions: "Be very formal",
        model_settings: %{temperature: 0.1}
      }

      assert :ok = GenServer.call(pid, {:update_settings, new_settings})

      {:ok, conversation} = GenServer.call(pid, :get_conversation)
      assert conversation.settings == new_settings
    end
  end

  describe "error handling" do
    test "handles agent errors gracefully", %{pid: pid} do
      # Mock an error in the agent
      with_mock_agent_error(fn ->
        assert {:error, _reason} = GenServer.call(pid, {:send_message, "Error message", []})
      end)

      # Agent should still be responsive
      assert Process.alive?(pid)
    end

    test "recovers from temporary failures", %{pid: pid} do
      # Simulate temporary failure followed by success
      with_mock_agent_temporary_failure(fn ->
        # First call fails
        assert {:error, _} = GenServer.call(pid, {:send_message, "Fail", []})

        # Second call succeeds
        assert {:ok, _} = GenServer.call(pid, {:send_message, "Success", []})
      end)
    end
  end

  describe "cleanup and shutdown" do
    test "cleans up resources on shutdown", %{pid: pid} do
      # Add some conversation history
      GenServer.call(pid, {:send_message, "Test message", []})

      # Stop the process
      GenServer.stop(pid)

      # Should not be alive
      refute Process.alive?(pid)
    end

    test "times out inactive agents" do
      # This would require mocking the idle timeout
      # and controlling time, implementation depends on your specific setup
    end
  end

  # Test helper functions
  defp with_mock_agent_error(fun) do
    # Implementation depends on your mocking strategy
    fun.()
  end

  defp with_mock_agent_temporary_failure(fun) do
    # Implementation depends on your mocking strategy
    fun.()
  end
end
```

---

## Complete Examples

### Full-Featured Chat Application

```elixir
# Complete single-file chat application with all features
defmodule MyAppWeb.CompleteChatLive do
  use Phoenix.LiveView
  alias Phoenix.PubSub

  # State management
  def mount(%{"room_id" => room_id}, session, socket) do
    user_id = get_user_id(session)

    if connected?(socket) do
      # Subscribe to room and user-specific events
      PubSub.subscribe(MyApp.PubSub, "room:#{room_id}")
      PubSub.subscribe(MyApp.PubSub, "room:#{room_id}:user:#{user_id}")

      # Join room
      MyApp.RoomManager.join_room(room_id, user_id)

      # Load conversation history
      {:ok, conversation} = MyApp.AgentServer.get_conversation(user_id, room_id)
    end

    socket = assign(socket,
      # Core state
      room_id: room_id,
      user_id: user_id,
      messages: conversation[:messages] || [],
      participants: [],

      # Input state
      input: "",
      uploading_file: false,

      # Streaming state
      streaming: false,
      current_response: "",
      stream_id: nil,

      # UI state
      typing_users: MapSet.new(),
      scroll_position: :bottom,
      show_participants: false,

      # Error state
      connection_status: :connected,
      last_error: nil,
      retry_count: 0
    )

    {:ok, socket}
  end

  # Message handling
  def handle_event("send_message", %{"message" => message}, socket) do
    if can_send_message?(socket, message) do
      case MyApp.AgentServer.send_message_stream(
        socket.assigns.user_id,
        socket.assigns.room_id,
        message,
        self()
      ) do
        {:ok, stream_id} ->
          user_msg = create_user_message(message, socket.assigns.user_id)

          socket =
            socket
            |> add_message(user_msg)
            |> assign(:input, "")
            |> assign(:streaming, true)
            |> assign(:stream_id, stream_id)
            |> assign(:current_response, "")
            |> assign(:retry_count, 0)

          {:noreply, socket}

        {:error, reason} ->
          socket = handle_send_error(socket, reason)
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Input management
  def handle_event("update_input", %{"value" => value}, socket) do
    socket = assign(socket, :input, value)

    # Handle typing indicators
    socket = handle_typing_indicator(socket, value != "")

    {:noreply, socket}
  end

  def handle_event("key_down", %{"key" => "Enter", "shiftKey" => false}, socket) do
    handle_event("send_message", %{"message" => socket.assigns.input}, socket)
  end

  def handle_event("key_down", _params, socket), do: {:noreply, socket}

  # File upload
  def handle_event("file_upload", params, socket) do
    # Handle file upload logic
    {:noreply, socket}
  end

  # Message actions
  def handle_event("delete_message", %{"message_id" => message_id}, socket) do
    new_messages = Enum.reject(socket.assigns.messages, &(&1.id == message_id))
    {:noreply, assign(socket, :messages, new_messages)}
  end

  def handle_event("edit_message", %{"message_id" => message_id, "content" => content}, socket) do
    new_messages = update_message_content(socket.assigns.messages, message_id, content)
    {:noreply, assign(socket, :messages, new_messages)}
  end

  # UI controls
  def handle_event("toggle_participants", _params, socket) do
    {:noreply, assign(socket, :show_participants, not socket.assigns.show_participants)}
  end

  def handle_event("scroll_to_bottom", _params, socket) do
    {:noreply, push_event(socket, "scroll_to_bottom", %{})}
  end

  def handle_event("stop_streaming", _params, socket) do
    # Cancel current stream
    if socket.assigns.streaming do
      MyApp.AgentServer.cancel_stream(socket.assigns.stream_id)

      socket =
        socket
        |> assign(:streaming, false)
        |> assign(:current_response, "")
        |> assign(:stream_id, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Real-time events
  def handle_info({:new_message, message}, socket) do
    socket = add_message(socket, message)
    {:noreply, socket}
  end

  def handle_info({:stream_chunk, stream_id, text}, socket) do
    if stream_id == socket.assigns.stream_id do
      new_response = socket.assigns.current_response <> text

      socket =
        socket
        |> assign(:current_response, new_response)
        |> push_event("stream_text", %{text: text})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_complete, stream_id, message}, socket) do
    if stream_id == socket.assigns.stream_id do
      socket =
        socket
        |> add_message(message)
        |> assign(:streaming, false)
        |> assign(:current_response, "")
        |> assign(:stream_id, nil)
        |> push_event("scroll_to_bottom", %{})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_error, stream_id, error}, socket) do
    if stream_id == socket.assigns.stream_id do
      socket = handle_stream_error(socket, error)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:user_typing, user_id, typing}, socket) do
    typing_users = if typing do
      MapSet.put(socket.assigns.typing_users, user_id)
    else
      MapSet.delete(socket.assigns.typing_users, user_id)
    end

    {:noreply, assign(socket, :typing_users, typing_users)}
  end

  def handle_info({:participants_updated, participants}, socket) do
    {:noreply, assign(socket, :participants, participants)}
  end

  def handle_info({:connection_status, status}, socket) do
    {:noreply, assign(socket, :connection_status, status)}
  end

  # Cleanup
  def terminate(_reason, socket) do
    if socket.assigns[:room_id] && socket.assigns[:user_id] do
      MyApp.RoomManager.leave_room(socket.assigns.room_id, socket.assigns.user_id)
    end
    :ok
  end

  # Render function with complete UI
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-gray-900 text-gray-100">
      <!-- Sidebar with participants (if shown) -->
      <div class={"transition-all duration-300 #{if @show_participants, do: "w-64", else: "w-0"} overflow-hidden bg-gray-800 border-r border-gray-700"}>
        <div class="p-4">
          <h3 class="text-lg font-semibold mb-4">Participants</h3>
          <div class="space-y-2">
            <%= for participant <- @participants do %>
              <div class="flex items-center space-x-2">
                <div class="w-3 h-3 bg-green-400 rounded-full"></div>
                <span class="text-sm"><%= participant %></span>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Main chat area -->
      <div class="flex-1 flex flex-col">
        <!-- Header -->
        <div class="bg-gray-800 border-b border-gray-700 px-6 py-4">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-xl font-semibold">Room <%= @room_id %></h1>
              <div class="flex items-center space-x-4 text-sm text-gray-400">
                <span class={"flex items-center space-x-1 #{connection_status_class(@connection_status)}"}>
                  <div class="w-2 h-2 rounded-full bg-current"></div>
                  <span><%= connection_status_text(@connection_status) %></span>
                </span>

                <%= if @streaming do %>
                  <span class="text-yellow-400 animate-pulse">AI is responding...</span>
                <% end %>
              </div>
            </div>

            <div class="flex items-center space-x-2">
              <button
                phx-click="toggle_participants"
                class="p-2 rounded-lg bg-gray-700 hover:bg-gray-600 transition-colors"
              >
                👥
              </button>

              <%= if @streaming do %>
                <button
                  phx-click="stop_streaming"
                  class="px-3 py-2 bg-red-600 hover:bg-red-700 rounded-lg text-sm transition-colors"
                >
                  Stop
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Messages area -->
        <div
          id="messages-container"
          class="flex-1 overflow-y-auto p-6 space-y-4"
          phx-hook="ChatScroll"
        >
          <%= if Enum.empty?(@messages) do %>
            <div class="text-center text-gray-400 py-20">
              <div class="text-4xl mb-4">💬</div>
              <p>Start a conversation!</p>
            </div>
          <% else %>
            <%= for message <- @messages do %>
              <div class={message_container_class(message)}>
                <%= render_message(assigns, message) %>
              </div>
            <% end %>
          <% end %>

          <!-- Current streaming response -->
          <%= if @streaming and @current_response != "" do %>
            <div class="flex justify-start">
              <%= render_streaming_message(assigns) %>
            </div>
          <% end %>

          <!-- Typing indicators -->
          <%= if not Enum.empty?(@typing_users) do %>
            <div class="text-sm text-gray-400 italic">
              <%= format_typing_users(@typing_users) %>
            </div>
          <% end %>
        </div>

        <!-- Error banner -->
        <%= if @last_error do %>
          <div class="bg-red-900 border-t border-red-700 px-6 py-3">
            <div class="flex items-center justify-between">
              <span class="text-sm text-red-100"><%= @last_error %></span>
              <button
                phx-click="retry_last_message"
                class="text-sm bg-red-700 hover:bg-red-600 px-3 py-1 rounded"
              >
                Retry
              </button>
            </div>
          </div>
        <% end %>

        <!-- Input area -->
        <div class="bg-gray-800 border-t border-gray-700 p-6">
          <form phx-submit="send_message" class="flex space-x-4">
            <div class="flex-1">
              <textarea
                name="message"
                value={@input}
                phx-change="update_input"
                phx-keydown="key_down"
                placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
                rows="2"
                disabled={@streaming}
                class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg
                       text-gray-100 placeholder-gray-400 resize-none
                       focus:ring-2 focus:ring-blue-500 focus:border-transparent
                       disabled:bg-gray-600 disabled:cursor-not-allowed"
              ><%= @input %></textarea>
            </div>

            <div class="flex flex-col space-y-2">
              <!-- File upload button -->
              <button
                type="button"
                class="p-3 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
                title="Attach file"
              >
                📎
              </button>

              <!-- Send button -->
              <button
                type="submit"
                disabled={@input == "" or @streaming}
                class="p-3 bg-blue-600 text-white rounded-lg
                       hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed
                       transition-colors flex items-center justify-center"
              >
                <%= if @streaming do %>
                  <div class="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                <% else %>
                  ➤
                <% end %>
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp can_send_message?(socket, message) do
    String.trim(message) != "" and
    not socket.assigns.streaming and
    socket.assigns.connection_status == :connected
  end

  defp create_user_message(content, user_id) do
    %{
      id: generate_id(),
      role: :user,
      user_id: user_id,
      content: content,
      timestamp: DateTime.utc_now()
    }
  end

  defp add_message(socket, message) do
    new_messages = socket.assigns.messages ++ [message]
    assign(socket, :messages, new_messages)
  end

  defp handle_typing_indicator(socket, typing) do
    # Broadcast typing status
    PubSub.broadcast(MyApp.PubSub, "room:#{socket.assigns.room_id}", {
      :user_typing,
      socket.assigns.user_id,
      typing
    })

    socket
  end

  defp handle_send_error(socket, reason) do
    retry_count = socket.assigns.retry_count + 1

    socket
    |> assign(:last_error, format_error(reason))
    |> assign(:retry_count, retry_count)
    |> assign(:connection_status, if(retry_count >= 3, do: :error, else: :connected))
  end

  defp handle_stream_error(socket, error) do
    socket
    |> assign(:streaming, false)
    |> assign(:current_response, "")
    |> assign(:stream_id, nil)
    |> assign(:last_error, "Stream error: #{format_error(error)}")
  end

  # UI helper functions
  defp message_container_class(message) do
    base = "flex"
    case message.role do
      :user -> "#{base} justify-end"
      :assistant -> "#{base} justify-start"
      :system -> "#{base} justify-center"
      _ -> base
    end
  end

  defp connection_status_class(:connected), do: "text-green-400"
  defp connection_status_class(:connecting), do: "text-yellow-400"
  defp connection_status_class(:disconnected), do: "text-red-400"
  defp connection_status_class(:error), do: "text-red-400"

  defp connection_status_text(:connected), do: "Connected"
  defp connection_status_text(:connecting), do: "Connecting..."
  defp connection_status_text(:disconnected), do: "Disconnected"
  defp connection_status_text(:error), do: "Connection Error"

  defp format_typing_users(users) do
    user_list = users |> Enum.take(3) |> Enum.join(", ")
    count = Enum.count(users)

    cond do
      count == 1 -> "#{user_list} is typing..."
      count <= 3 -> "#{user_list} are typing..."
      true -> "#{user_list} and #{count - 3} others are typing..."
    end
  end

  defp format_error(error) do
    case error do
      %{message: msg} -> msg
      atom when is_atom(atom) -> Atom.to_string(atom)
      binary when is_binary(binary) -> binary
      _ -> "Unknown error"
    end
  end

  defp get_user_id(session) do
    # Implementation depends on your authentication system
    session["user_id"] || "anonymous-#{:rand.uniform(1000)}"
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64()

  # Additional render helpers
  defp render_message(assigns, message) do
    # Implementation for rendering different message types
  end

  defp render_streaming_message(assigns) do
    # Implementation for streaming message UI
  end

  defp update_message_content(messages, message_id, new_content) do
    Enum.map(messages, fn msg ->
      if msg.id == message_id do
        %{msg | content: new_content, edited: true}
      else
        msg
      end
    end)
  end
end
```

This comprehensive guide covers all aspects of integrating Nous AI with Phoenix LiveView, from basic patterns to production-ready systems. The examples are designed to be practical and can be adapted to your specific use cases.

Key takeaways:
1. **Start simple** with basic LiveView integration
2. **Add streaming** for better user experience
3. **Use GenServer** for stateful agent management
4. **Leverage PubSub** for multi-user coordination
5. **Plan for errors** and implement recovery strategies
6. **Test thoroughly** with proper mocking
7. **Optimize for scale** with resource management

The patterns shown here provide a solid foundation for building production AI applications with Phoenix LiveView.
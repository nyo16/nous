#!/usr/bin/env elixir

# Nous AI - LiveView Integration
# Building interactive AI chat interfaces with Phoenix LiveView

IO.puts("=== Nous AI - LiveView Integration ===\n")

# ============================================================================
# Overview
# ============================================================================

IO.puts("""
This example demonstrates how to integrate Nous with Phoenix LiveView
for building interactive AI chat interfaces.

Patterns covered:
1. Non-streaming mode (simple request/response)
2. Streaming mode (real-time text updates)
3. Tool call visualization
4. Cancellation support
5. Error handling
6. Conversation history

Note: This is a documentation example. For a working implementation,
copy these patterns into your Phoenix LiveView application.
""")

# ============================================================================
# Pattern 1: Non-Streaming LiveView
# ============================================================================

IO.puts("--- Pattern 1: Non-Streaming ---")

IO.puts("""
# Simple request/response pattern - good for quick responses

defmodule MyAppWeb.ChatLive.NonStreaming do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    agent = Nous.new("lmstudio:qwen3",
      instructions: "You are a helpful assistant."
    )

    {:ok, assign(socket,
      agent: agent,
      messages: [],
      loading: false,
      error: nil
    )}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    # Add user message to history
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Start async task for AI response
    task = Task.async(fn ->
      Nous.run(socket.assigns.agent, message,
        context: socket.assigns[:context]
      )
    end)

    {:noreply, assign(socket,
      messages: messages,
      loading: true,
      current_task: task
    )}
  end

  def handle_info({ref, {:ok, result}}, socket) when socket.assigns.current_task.ref == ref do
    Process.demonitor(ref, [:flush])

    messages = socket.assigns.messages ++ [%{role: :assistant, content: result.output}]

    {:noreply, assign(socket,
      messages: messages,
      context: result.context,  # Carry forward for multi-turn
      loading: false,
      current_task: nil
    )}
  end

  def handle_info({ref, {:error, error}}, socket) when socket.assigns.current_task.ref == ref do
    Process.demonitor(ref, [:flush])

    {:noreply, assign(socket,
      error: inspect(error),
      loading: false,
      current_task: nil
    )}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, assign(socket, loading: false, current_task: nil)}
  end
end
""")

# ============================================================================
# Pattern 2: Streaming LiveView (Recommended)
# ============================================================================

IO.puts("--- Pattern 2: Streaming (Recommended) ---")

IO.puts("""
# Real-time streaming using notify_pid - provides the best UX

defmodule MyAppWeb.ChatLive.Streaming do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    agent = Nous.new("lmstudio:qwen3",
      instructions: "You are a helpful assistant."
    )

    {:ok, assign(socket,
      agent: agent,
      messages: [],
      current_response: "",
      streaming: false,
      error: nil
    )}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Start streaming with notify_pid
    Task.start(fn ->
      Nous.run(socket.assigns.agent, message,
        context: socket.assigns[:context],
        notify_pid: socket.root_pid  # Send events to this LiveView
      )
    end)

    {:noreply, assign(socket,
      messages: messages,
      current_response: "",
      streaming: true
    )}
  end

  # Handle streaming text chunks
  def handle_info({:agent_delta, text}, socket) do
    {:noreply, assign(socket,
      current_response: socket.assigns.current_response <> text
    )}
  end

  # Handle tool call start
  def handle_info({:tool_call, %{name: name, arguments: args}}, socket) do
    # Optionally show tool calls in UI
    IO.puts("Tool called: #{name}")
    {:noreply, socket}
  end

  # Handle tool result
  def handle_info({:tool_result, %{name: name, result: result}}, socket) do
    IO.puts("Tool result: #{name} -> #{inspect(result)}")
    {:noreply, socket}
  end

  # Handle completion
  def handle_info({:agent_complete, result}, socket) do
    messages = socket.assigns.messages ++ [
      %{role: :assistant, content: result.output}
    ]

    {:noreply, assign(socket,
      messages: messages,
      current_response: "",
      context: result.context,
      streaming: false
    )}
  end

  # Handle errors
  def handle_info({:agent_error, error}, socket) do
    {:noreply, assign(socket,
      error: inspect(error),
      streaming: false
    )}
  end

  # Render shows current_response while streaming
  def render(assigns) do
    ~H\"\"\"
    <div class="chat-container">
      <%= for msg <- @messages do %>
        <div class={"message " <> to_string(msg.role)}>
          <%= msg.content %>
        </div>
      <% end %>

      <!-- Show streaming response -->
      <%= if @streaming and @current_response != "" do %>
        <div class="message assistant streaming">
          <%= @current_response %>
          <span class="cursor">|</span>
        </div>
      <% end %>

      <%= if @error do %>
        <div class="error"><%= @error %></div>
      <% end %>

      <form phx-submit="send_message">
        <input name="message" disabled={@streaming} />
        <button type="submit" disabled={@streaming}>Send</button>
      </form>
    </div>
    \"\"\"
  end
end
""")

# ============================================================================
# Pattern 3: With Tool Visualization
# ============================================================================

IO.puts("--- Pattern 3: Tool Call Visualization ---")

IO.puts("""
# Show tool calls and results in the chat UI

defmodule MyAppWeb.ChatLive.WithTools do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    get_weather = fn _ctx, %{"city" => city} ->
      # Simulate API call
      Process.sleep(500)
      %{city: city, temperature: 72, conditions: "sunny"}
    end

    search = fn _ctx, %{"query" => query} ->
      Process.sleep(300)
      %{results: ["Result 1 for #{query}", "Result 2 for #{query}"]}
    end

    agent = Nous.new("lmstudio:qwen3",
      instructions: "You have weather and search tools. Use them when appropriate.",
      tools: [get_weather, search]
    )

    {:ok, assign(socket,
      agent: agent,
      messages: [],
      current_response: "",
      tool_calls: [],  # Track active tool calls
      streaming: false
    )}
  end

  # ... handle_event for send_message same as above ...

  # Show tool call started
  def handle_info({:tool_call, call}, socket) do
    tool_call = %{
      id: call.id,
      name: call.name,
      arguments: call.arguments,
      status: :running,
      result: nil
    }

    {:noreply, assign(socket,
      tool_calls: socket.assigns.tool_calls ++ [tool_call]
    )}
  end

  # Show tool result
  def handle_info({:tool_result, %{id: id, result: result}}, socket) do
    tool_calls = Enum.map(socket.assigns.tool_calls, fn tc ->
      if tc.id == id do
        %{tc | status: :completed, result: result}
      else
        tc
      end
    end)

    {:noreply, assign(socket, tool_calls: tool_calls)}
  end

  # Clear tool calls on completion
  def handle_info({:agent_complete, result}, socket) do
    messages = socket.assigns.messages ++ [
      %{role: :assistant, content: result.output, tool_calls: socket.assigns.tool_calls}
    ]

    {:noreply, assign(socket,
      messages: messages,
      tool_calls: [],
      context: result.context,
      streaming: false
    )}
  end

  # In template, show tool calls:
  # <%= for tc <- @tool_calls do %>
  #   <div class="tool-call">
  #     <span class="tool-name"><%= tc.name %></span>
  #     <span class="tool-args"><%= inspect(tc.arguments) %></span>
  #     <%= if tc.status == :completed do %>
  #       <span class="tool-result"><%= inspect(tc.result) %></span>
  #     <% else %>
  #       <span class="loading">Running...</span>
  #     <% end %>
  #   </div>
  # <% end %>
end
""")

# ============================================================================
# Pattern 4: Cancellation Support
# ============================================================================

IO.puts("--- Pattern 4: Cancellation Support ---")

IO.puts("""
# Allow users to cancel generation mid-stream

defmodule MyAppWeb.ChatLive.WithCancellation do
  use MyAppWeb, :live_view

  # ... mount same as above ...

  def handle_event("send_message", %{"message" => message}, socket) do
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Store task reference for cancellation
    task = Task.async(fn ->
      Nous.run(socket.assigns.agent, message,
        context: socket.assigns[:context],
        notify_pid: socket.root_pid
      )
    end)

    {:noreply, assign(socket,
      messages: messages,
      current_response: "",
      streaming: true,
      current_task: task
    )}
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns[:current_task] do
      Task.shutdown(socket.assigns.current_task, :brutal_kill)
    end

    # Save partial response if any
    messages = if socket.assigns.current_response != "" do
      socket.assigns.messages ++ [
        %{role: :assistant, content: socket.assigns.current_response <> " [cancelled]"}
      ]
    else
      socket.assigns.messages
    end

    {:noreply, assign(socket,
      messages: messages,
      current_response: "",
      streaming: false,
      current_task: nil
    )}
  end

  # In template:
  # <%= if @streaming do %>
  #   <button phx-click="cancel">Stop generating</button>
  # <% end %>
end
""")

# ============================================================================
# Pattern 5: Using AgentServer (Production)
# ============================================================================

IO.puts("--- Pattern 5: AgentServer (Production) ---")

IO.puts("""
# For production apps, use AgentServer with Nous.PubSub
#
# Configure once in config/config.exs:
#   config :nous, pubsub: MyApp.PubSub
#
# All AgentServers will automatically use it.

defmodule MyAppWeb.ChatLive.Production do
  use MyAppWeb, :live_view

  def mount(%{"session_id" => session_id}, _session, socket) do
    # Start or connect to existing AgentServer
    {:ok, agent_pid} = ensure_agent_server(session_id)

    # Subscribe to agent events via Nous.PubSub
    Nous.PubSub.subscribe(MyApp.PubSub, "agent:#{session_id}")

    {:ok, assign(socket,
      session_id: session_id,
      agent_pid: agent_pid,
      messages: [],
      current_response: "",
      streaming: false
    )}
  end

  defp ensure_agent_server(session_id) do
    case Registry.lookup(MyApp.AgentRegistry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        # pubsub defaults to Nous.PubSub.configured_pubsub()
        Nous.AgentServer.start_link(
          session_id: session_id,
          agent_config: %{
            model: "lmstudio:qwen3",
            instructions: "You are a helpful assistant."
          }
        )
    end
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # AgentServer handles the run
    Nous.AgentServer.send_message(socket.assigns.agent_pid, message)

    {:noreply, assign(socket, messages: messages, streaming: true)}
  end

  def handle_event("cancel", _params, socket) do
    Nous.AgentServer.cancel_execution(socket.assigns.agent_pid)
    {:noreply, socket}
  end

  # PubSub events from AgentServer
  def handle_info({:agent_delta, text}, socket) do
    {:noreply, assign(socket,
      current_response: socket.assigns.current_response <> text
    )}
  end

  def handle_info({:agent_complete, result}, socket) do
    messages = socket.assigns.messages ++ [
      %{role: :assistant, content: result.output}
    ]

    {:noreply, assign(socket,
      messages: messages,
      current_response: "",
      streaming: false
    )}
  end

  def handle_info({:agent_cancelled, _reason}, socket) do
    {:noreply, assign(socket,
      current_response: "",
      streaming: false
    )}
  end

  def handle_info({:agent_error, error}, socket) do
    {:noreply, assign(socket,
      error: inspect(error),
      streaming: false
    )}
  end
end
""")

# ============================================================================
# Pattern 6: Map Callbacks Alternative
# ============================================================================

IO.puts("--- Pattern 6: Map Callbacks Alternative ---")

IO.puts("""
# If you prefer callbacks over process messages

defmodule MyAppWeb.ChatLive.MapCallbacks do
  use MyAppWeb, :live_view

  def handle_event("send_message", %{"message" => message}, socket) do
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]
    lv_pid = self()

    Task.start(fn ->
      Nous.run(socket.assigns.agent, message,
        context: socket.assigns[:context],
        callbacks: %{
          on_llm_new_delta: fn _event, delta ->
            send(lv_pid, {:stream_delta, delta})
          end,

          on_tool_call: fn _event, call ->
            send(lv_pid, {:tool_started, call})
          end,

          on_tool_result: fn _event, result ->
            send(lv_pid, {:tool_finished, result})
          end,

          on_complete: fn _event, result ->
            send(lv_pid, {:generation_complete, result})
          end,

          on_error: fn _event, error ->
            send(lv_pid, {:generation_error, error})
          end
        }
      )
    end)

    {:noreply, assign(socket, messages: messages, streaming: true)}
  end

  def handle_info({:stream_delta, delta}, socket) do
    {:noreply, assign(socket,
      current_response: socket.assigns.current_response <> delta
    )}
  end

  # ... similar handlers for other events ...
end
""")

# ============================================================================
# Complete Working Example Template
# ============================================================================

IO.puts("--- Complete Template ---")

IO.puts("""
# Copy this template to get started quickly

defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    agent = Nous.new("lmstudio:qwen3",
      instructions: "You are a helpful assistant. Be concise."
    )

    {:ok, assign(socket,
      agent: agent,
      messages: [],
      current_response: "",
      streaming: false,
      error: nil,
      form: to_form(%{"message" => ""})
    )}
  end

  @impl true
  def handle_event("send", %{"message" => message}, socket) when message != "" do
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    Task.start(fn ->
      Nous.run(socket.assigns.agent, message,
        context: socket.assigns[:context],
        notify_pid: socket.root_pid
      )
    end)

    {:noreply,
     socket
     |> assign(messages: messages, current_response: "", streaming: true, error: nil)
     |> assign(form: to_form(%{"message" => ""}))}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:agent_delta, text}, socket) do
    {:noreply, assign(socket, current_response: socket.assigns.current_response <> text)}
  end

  def handle_info({:agent_complete, result}, socket) do
    messages = socket.assigns.messages ++ [%{role: :assistant, content: result.output}]
    {:noreply, assign(socket, messages: messages, current_response: "", context: result.context, streaming: false)}
  end

  def handle_info({:agent_error, error}, socket) do
    {:noreply, assign(socket, error: inspect(error), streaming: false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H\"\"\"
    <div class="max-w-2xl mx-auto p-4">
      <div class="space-y-4 mb-4">
        <%= for msg <- @messages do %>
          <div class={["p-3 rounded-lg", msg.role == :user && "bg-blue-100 ml-8", msg.role == :assistant && "bg-gray-100 mr-8"]}>
            <div class="font-semibold text-sm text-gray-600 mb-1">
              <%= if msg.role == :user, do: "You", else: "Assistant" %>
            </div>
            <div class="whitespace-pre-wrap"><%= msg.content %></div>
          </div>
        <% end %>

        <%= if @streaming and @current_response != "" do %>
          <div class="p-3 rounded-lg bg-gray-100 mr-8">
            <div class="font-semibold text-sm text-gray-600 mb-1">Assistant</div>
            <div class="whitespace-pre-wrap"><%= @current_response %><span class="animate-pulse">|</span></div>
          </div>
        <% end %>

        <%= if @error do %>
          <div class="p-3 rounded-lg bg-red-100 text-red-700"><%= @error %></div>
        <% end %>
      </div>

      <.form for={@form} phx-submit="send" class="flex gap-2">
        <input
          type="text"
          name="message"
          value={@form[:message].value}
          placeholder="Type your message..."
          disabled={@streaming}
          class="flex-1 p-2 border rounded"
          autocomplete="off"
        />
        <button type="submit" disabled={@streaming} class="px-4 py-2 bg-blue-500 text-white rounded disabled:opacity-50">
          <%= if @streaming, do: "...", else: "Send" %>
        </button>
      </.form>
    </div>
    \"\"\"
  end
end
""")

# ============================================================================
# Best Practices
# ============================================================================

IO.puts("""
--- Best Practices ---

1. Use notify_pid for streaming:
   - Simpler than map callbacks
   - Native LiveView message handling
   - Easy to extend

2. Handle all message types:
   - :agent_delta - streaming text
   - :agent_complete - final result
   - :agent_error - error handling
   - :tool_call / :tool_result - optional

3. Preserve context for multi-turn:
   - Store result.context in socket assigns
   - Pass context: on subsequent runs

4. Cancel support:
   - Store Task reference
   - Use Task.shutdown for cancellation
   - Save partial response if needed

5. Production considerations:
   - Use AgentServer for state management
   - Subscribe via PubSub for events
   - Handle reconnection gracefully
   - Add rate limiting

6. Error handling:
   - Display user-friendly error messages
   - Log detailed errors server-side
   - Provide retry option

7. UI/UX tips:
   - Show streaming indicator
   - Disable input while streaming
   - Auto-scroll to new messages
   - Add typing indicator
""")

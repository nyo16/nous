defmodule NousWeb.AgentChatLive do
  @moduledoc """
  Single-page LiveView chat interface with Nous agent.

  Features:
  - Spawns agent GenServer linked to LiveView process
  - Real-time chat via PubSub
  - Conversation history
  - Agent status indicators (thinking, ready, error)
  - Support for both standard and ReAct agents
  - Auto-scroll to latest message
  - Token usage tracking

  ## Setup

  1. Add to your Phoenix router:

      live "/chat", NousWeb.AgentChatLive

  2. Ensure PubSub is configured in application.ex:

      {Phoenix.PubSub, name: MyApp.PubSub}

  3. Start your Phoenix server and visit /chat

  ## Customization

  Change the agent configuration in mount/3:
  - model: "lmstudio:qwen/qwen3-30b" or "openai:gpt-4"
  - type: :standard or :react
  - instructions: Custom system prompt
  - tools: List of custom tools

  """

  use Phoenix.LiveView
  require Logger

  alias Nous.AgentServer

  # ===================================================================
  # LiveView Callbacks
  # ===================================================================

  @impl true
  def mount(_params, _session, socket) do
    # Generate unique session ID
    session_id = generate_session_id()

    # Subscribe to agent messages
    Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:#{session_id}")

    # Agent configuration
    agent_config = %{
      model: "lmstudio:qwen/qwen3-30b-a3b-2507",
      type: :react,  # Use ReAct agent for structured planning
      instructions: """
      You are a helpful AI assistant with access to various tools.
      Be concise but thorough in your responses.
      When solving complex problems, break them down step by step.
      """,
      tools: [
        # Add your custom tools here
        # &MyTools.search/2,
        # &MyTools.calculate/2,
      ],
      model_settings: %{
        temperature: 0.7,
        max_tokens: 2000
      }
    }

    # Start agent GenServer linked to this LiveView
    {:ok, agent_pid} = AgentServer.start_link(
      session_id: session_id,
      agent_config: agent_config,
      pubsub: MyApp.PubSub
    )

    # Monitor agent process
    Process.monitor(agent_pid)

    Logger.info("Chat LiveView mounted with session: #{session_id}")

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:agent_pid, agent_pid)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:agent_status, :ready)
      |> assign(:total_tokens, 0)
      |> assign(:agent_type, agent_config.type)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" do
      # Add user message to UI immediately
      user_msg = %{
        role: :user,
        content: message,
        timestamp: DateTime.utc_now()
      }

      messages = socket.assigns.messages ++ [user_msg]

      # Send to agent via PubSub
      Phoenix.PubSub.broadcast(
        MyApp.PubSub,
        "agent:#{socket.assigns.session_id}",
        {:user_message, message}
      )

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> push_event("scroll_to_bottom", %{})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  @impl true
  def handle_event("clear_chat", _params, socket) do
    AgentServer.clear_history(socket.assigns.agent_pid)

    socket =
      socket
      |> assign(:messages, [])
      |> assign(:total_tokens, 0)

    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => "Enter", "shiftKey" => false}, socket) do
    # Send message on Enter (without Shift)
    if socket.assigns.input != "" do
      handle_event("send_message", %{"message" => socket.assigns.input}, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("keydown", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_status, status}, socket) do
    {:noreply, assign(socket, :agent_status, status)}
  end

  @impl true
  def handle_info({:agent_response, content, metadata}, socket) do
    # Add assistant message to UI
    assistant_msg = %{
      role: :assistant,
      content: content,
      timestamp: DateTime.utc_now(),
      usage: metadata[:usage]
    }

    messages = socket.assigns.messages ++ [assistant_msg]

    # Update total tokens
    total_tokens = socket.assigns.total_tokens +
      (get_in(metadata, [:usage, :total_tokens]) || 0)

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:agent_status, :ready)
      |> assign(:total_tokens, total_tokens)
      |> push_event("scroll_to_bottom", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_error, error_msg}, socket) do
    # Add error message to UI
    error_msg_map = %{
      role: :error,
      content: "Error: #{error_msg}",
      timestamp: DateTime.utc_now()
    }

    messages = socket.assigns.messages ++ [error_msg_map]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:agent_status, :error)
      |> push_event("scroll_to_bottom", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    Logger.warning("Agent process died: #{inspect(reason)}")

    socket =
      socket
      |> assign(:agent_status, :error)
      |> put_flash(:error, "Agent disconnected. Please refresh the page.")

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ===================================================================
  # Render
  # ===================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-gray-50">
      <!-- Header -->
      <div class="bg-white shadow-sm border-b border-gray-200 px-6 py-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">
              🤖 Nous AI Chat
            </h1>
            <p class="text-sm text-gray-500 mt-1">
              <%= if @agent_type == :react do %>
                ReAct Agent • Structured Planning & Task Management
              <% else %>
                Standard Agent • Fast & Flexible
              <% end %>
            </p>
          </div>

          <div class="flex items-center space-x-4">
            <!-- Token Counter -->
            <div class="text-right">
              <div class="text-xs text-gray-500">Total Tokens</div>
              <div class="text-lg font-semibold text-indigo-600">
                <%= @total_tokens %>
              </div>
            </div>

            <!-- Agent Status -->
            <div class="flex items-center space-x-2">
              <div class={"h-3 w-3 rounded-full #{status_color(@agent_status)}"}>
              </div>
              <span class="text-sm text-gray-600">
                <%= status_text(@agent_status) %>
              </span>
            </div>

            <!-- Clear Button -->
            <button
              phx-click="clear_chat"
              class="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
            >
              Clear Chat
            </button>
          </div>
        </div>
      </div>

      <!-- Messages Area -->
      <div
        id="messages-container"
        class="flex-1 overflow-y-auto px-6 py-4 space-y-4"
        phx-hook="ScrollToBottom"
      >
        <%= if Enum.empty?(@messages) do %>
          <div class="flex items-center justify-center h-full">
            <div class="text-center">
              <div class="text-6xl mb-4">💬</div>
              <h2 class="text-xl font-semibold text-gray-700 mb-2">
                Start a conversation
              </h2>
              <p class="text-gray-500">
                Ask me anything! I can help with research, calculations, and more.
              </p>
            </div>
          </div>
        <% else %>
          <%= for message <- @messages do %>
            <div class={"flex #{if message.role == :user, do: "justify-end", else: "justify-start"}"}>
              <div class={"max-w-3xl rounded-lg px-4 py-3 #{message_style(message.role)}"}>
                <!-- Message Header -->
                <div class="flex items-center space-x-2 mb-1">
                  <span class="text-xs font-semibold">
                    <%= message_author(message.role) %>
                  </span>
                  <span class="text-xs text-gray-500">
                    <%= format_time(message.timestamp) %>
                  </span>
                  <%= if message[:usage] do %>
                    <span class="text-xs text-gray-500 ml-2">
                      • <%= message.usage.total_tokens %> tokens
                    </span>
                  <% end %>
                </div>

                <!-- Message Content -->
                <div class="prose prose-sm max-w-none">
                  <%= raw(format_message(message.content)) %>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>

        <!-- Typing Indicator -->
        <%= if @agent_status == :thinking do %>
          <div class="flex justify-start">
            <div class="bg-gray-200 rounded-lg px-4 py-3">
              <div class="flex space-x-2">
                <div class="w-2 h-2 bg-gray-500 rounded-full animate-bounce"></div>
                <div class="w-2 h-2 bg-gray-500 rounded-full animate-bounce" style="animation-delay: 0.1s"></div>
                <div class="w-2 h-2 bg-gray-500 rounded-full animate-bounce" style="animation-delay: 0.2s"></div>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Input Area -->
      <div class="bg-white border-t border-gray-200 px-6 py-4">
        <form phx-submit="send_message" class="flex space-x-4">
          <div class="flex-1">
            <textarea
              name="message"
              value={@input}
              phx-change="update_input"
              phx-keydown="keydown"
              placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
              rows="2"
              class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-indigo-500 focus:border-transparent resize-none"
              disabled={@agent_status == :thinking}
            ><%= @input %></textarea>
          </div>

          <button
            type="submit"
            disabled={@agent_status == :thinking || @input == ""}
            class="px-6 py-2 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
          >
            <%= if @agent_status == :thinking do %>
              Thinking...
            <% else %>
              Send
            <% end %>
          </button>
        </form>

        <div class="mt-2 text-xs text-gray-500 text-center">
          Session: <%= @session_id %> •
          Powered by <span class="font-semibold">Nous AI</span>
        </div>
      </div>
    </div>
    """
  end

  # ===================================================================
  # Private Functions
  # ===================================================================

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp status_color(:ready), do: "bg-green-500 animate-pulse"
  defp status_color(:thinking), do: "bg-yellow-500 animate-pulse"
  defp status_color(:error), do: "bg-red-500"
  defp status_color(_), do: "bg-gray-400"

  defp status_text(:ready), do: "Ready"
  defp status_text(:thinking), do: "Thinking..."
  defp status_text(:error), do: "Error"
  defp status_text(_), do: "Unknown"

  defp message_style(:user), do: "bg-indigo-600 text-white"
  defp message_style(:assistant), do: "bg-white border border-gray-300 text-gray-900"
  defp message_style(:error), do: "bg-red-100 border border-red-300 text-red-900"
  defp message_style(_), do: "bg-gray-100 text-gray-900"

  defp message_author(:user), do: "You"
  defp message_author(:assistant), do: "AI Assistant"
  defp message_author(:error), do: "System"
  defp message_author(_), do: "Unknown"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
  end

  defp format_message(content) do
    content
    |> String.replace("\n", "<br>")
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end

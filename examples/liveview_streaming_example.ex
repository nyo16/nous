defmodule NousWeb.StreamingChatLive do
  @moduledoc """
  LiveView chat with real-time streaming responses.

  Watch AI responses appear character by character in real-time.
  Includes stop button to cancel generation mid-stream.

  ## Features

  - Real-time streaming with character-by-character display
  - Stop generation button
  - Automatic cleanup when LiveView closes
  - Token usage tracking
  - Works with any streaming-capable provider

  ## Setup

  1. Add to your Phoenix router:

      live "/streaming-chat", NousWeb.StreamingChatLive

  2. Visit /streaming-chat and start chatting!

  """

  use Phoenix.LiveView
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:agent_pid, nil)
      |> assign(:total_tokens, 0)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" and not socket.assigns.streaming do
      # Add user message
      user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [user_msg]

      # Start streaming in linked process
      parent = self()

      agent_pid =
        spawn_link(fn ->
          stream_response(parent, message)
        end)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> assign(:streaming, true)
        |> assign(:current_response, "")
        |> assign(:agent_pid, agent_pid)
        |> push_event("scroll_to_bottom", %{})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_streaming", _params, socket) do
    if socket.assigns.agent_pid && Process.alive?(socket.assigns.agent_pid) do
      Process.exit(socket.assigns.agent_pid, :kill)
    end

    # Save partial response as message
    if socket.assigns.current_response != "" do
      partial_msg = %{
        role: :assistant,
        content: socket.assigns.current_response <> "\n\n_(generation stopped)_",
        timestamp: DateTime.utc_now()
      }

      messages = socket.assigns.messages ++ [partial_msg]
      {:noreply, assign(socket, messages: messages, streaming: false, current_response: "", agent_pid: nil)}
    else
      {:noreply, assign(socket, streaming: false, current_response: "", agent_pid: nil)}
    end
  end

  @impl true
  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  @impl true
  def handle_event("clear_chat", _params, socket) do
    {:noreply, assign(socket, messages: [], total_tokens: 0)}
  end

  @impl true
  def handle_event("keydown", %{"key" => "Enter", "shiftKey" => false}, socket) do
    if socket.assigns.input != "" and not socket.assigns.streaming do
      handle_event("send_message", %{"message" => socket.assigns.input}, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  # Streaming handlers
  @impl true
  def handle_info({:stream_chunk, text}, socket) do
    new_response = socket.assigns.current_response <> text

    socket =
      socket
      |> assign(:current_response, new_response)
      |> push_event("append_text", %{text: text})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_complete, usage}, socket) do
    # Add complete message to history
    assistant_msg = %{
      role: :assistant,
      content: socket.assigns.current_response,
      timestamp: DateTime.utc_now(),
      usage: usage
    }

    messages = socket.assigns.messages ++ [assistant_msg]
    total_tokens = socket.assigns.total_tokens + (usage[:total_tokens] || 0)

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:agent_pid, nil)
      |> assign(:total_tokens, total_tokens)
      |> push_event("scroll_to_bottom", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_error, error}, socket) do
    Logger.error("Stream error: #{inspect(error)}")

    error_msg = %{
      role: :error,
      content: "Error: #{inspect(error)}",
      timestamp: DateTime.utc_now()
    }

    messages = socket.assigns.messages ++ [error_msg]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:agent_pid, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Cleanup when LiveView terminates
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:agent_pid] && Process.alive?(socket.assigns.agent_pid) do
      Process.exit(socket.assigns.agent_pid, :shutdown)
    end

    :ok
  end

  # ===================================================================
  # Streaming Logic
  # ===================================================================

  defp stream_response(parent, message) do
    # Create agent - change provider as needed
    agent =
      Nous.new("anthropic:claude-sonnet-4-5-20250929",
        instructions: "Be helpful and concise. Format responses with markdown when appropriate.",
        model_settings: %{
          temperature: 0.7,
          max_tokens: 2000
        }
      )

    case Nous.run_stream(agent, message) do
      {:ok, stream} ->
        usage_ref = make_ref()

        stream
        |> Stream.each(fn event ->
          case event do
            {:text_delta, text} ->
              send(parent, {:stream_chunk, text})

            {:finish, result} ->
              usage = if result, do: Map.from_struct(result.usage), else: %{}
              send(parent, {:stream_complete, usage})

            {:error, reason} ->
              send(parent, {:stream_error, reason})

            _ ->
              :ok
          end
        end)
        |> Stream.run()

      {:error, reason} ->
        send(parent, {:stream_error, reason})
    end
  end

  # ===================================================================
  # Render
  # ===================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-gray-900 text-gray-100">
      <!-- Header -->
      <div class="bg-gray-800 border-b border-gray-700 px-6 py-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-white">
              ⚡ Streaming Chat
            </h1>
            <p class="text-sm text-gray-400 mt-1">
              Real-time AI responses • Watch text appear live
            </p>
          </div>

          <div class="flex items-center space-x-4">
            <!-- Token Counter -->
            <div class="text-right">
              <div class="text-xs text-gray-500">Total Tokens</div>
              <div class="text-lg font-semibold text-indigo-400">
                <%= @total_tokens %>
              </div>
            </div>

            <!-- Status Indicator -->
            <div class="flex items-center space-x-2">
              <div class={"h-3 w-3 rounded-full #{if @streaming, do: "bg-yellow-500 animate-pulse", else: "bg-green-500"}"}>
              </div>
              <span class="text-sm text-gray-400">
                <%= if @streaming, do: "Streaming...", else: "Ready" %>
              </span>
            </div>

            <!-- Clear Button -->
            <button
              phx-click="clear_chat"
              class="px-4 py-2 text-sm font-medium text-gray-300 bg-gray-700 border border-gray-600 rounded-md hover:bg-gray-600"
            >
              Clear
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
        <%= if Enum.empty?(@messages) and @current_response == "" do %>
          <div class="flex items-center justify-center h-full">
            <div class="text-center">
              <div class="text-6xl mb-4">⚡</div>
              <h2 class="text-xl font-semibold text-gray-300 mb-2">
                Streaming Chat Demo
              </h2>
              <p class="text-gray-500">
                Watch AI responses appear in real-time, character by character.
              </p>
            </div>
          </div>
        <% else %>
          <%= for message <- @messages do %>
            <div class={"flex #{if message.role == :user, do: "justify-end", else: "justify-start"}"}>
              <div class={"max-w-3xl rounded-lg px-4 py-3 #{message_style(message.role)}"}>
                <div class="flex items-center space-x-2 mb-1">
                  <span class="text-xs font-semibold opacity-75">
                    <%= message_author(message.role) %>
                  </span>
                  <span class="text-xs opacity-50">
                    <%= format_time(message.timestamp) %>
                  </span>
                  <%= if message[:usage] do %>
                    <span class="text-xs opacity-50">
                      • <%= message.usage.total_tokens %> tokens
                    </span>
                  <% end %>
                </div>
                <div class="prose prose-sm prose-invert max-w-none">
                  <%= raw(format_message(message.content)) %>
                </div>
              </div>
            </div>
          <% end %>

          <!-- Current streaming response -->
          <%= if @streaming and @current_response != "" do %>
            <div class="flex justify-start">
              <div class="max-w-3xl rounded-lg px-4 py-3 bg-gray-800 border border-gray-700">
                <div class="flex items-center space-x-2 mb-1">
                  <span class="text-xs font-semibold text-indigo-400">AI Assistant</span>
                  <span class="text-xs text-yellow-500 animate-pulse">● streaming</span>
                </div>
                <div id="streaming-text" class="prose prose-sm prose-invert max-w-none" phx-hook="StreamingText">
                  <%= raw(format_message(@current_response)) %><span class="animate-pulse">▊</span>
                </div>
              </div>
            </div>
          <% end %>

          <!-- Typing indicator when starting -->
          <%= if @streaming and @current_response == "" do %>
            <div class="flex justify-start">
              <div class="bg-gray-800 border border-gray-700 rounded-lg px-4 py-3">
                <div class="flex space-x-2">
                  <div class="w-2 h-2 bg-indigo-500 rounded-full animate-bounce"></div>
                  <div class="w-2 h-2 bg-indigo-500 rounded-full animate-bounce" style="animation-delay: 0.1s"></div>
                  <div class="w-2 h-2 bg-indigo-500 rounded-full animate-bounce" style="animation-delay: 0.2s"></div>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>

      <!-- Input Area -->
      <div class="bg-gray-800 border-t border-gray-700 px-6 py-4">
        <form phx-submit="send_message" class="flex space-x-4">
          <div class="flex-1">
            <textarea
              name="message"
              value={@input}
              phx-change="update_input"
              phx-keydown="keydown"
              placeholder="Type your message... (Enter to send)"
              rows="2"
              class="w-full px-4 py-2 bg-gray-700 border border-gray-600 rounded-lg text-gray-100 placeholder-gray-400 focus:ring-2 focus:ring-indigo-500 focus:border-transparent resize-none"
              disabled={@streaming}
            ><%= @input %></textarea>
          </div>

          <%= if @streaming do %>
            <button
              type="button"
              phx-click="stop_streaming"
              class="px-6 py-2 bg-red-600 text-white font-medium rounded-lg hover:bg-red-700 transition-colors"
            >
              ⏹ Stop
            </button>
          <% else %>
            <button
              type="submit"
              disabled={@input == ""}
              class="px-6 py-2 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 disabled:bg-gray-600 disabled:cursor-not-allowed transition-colors"
            >
              Send ⚡
            </button>
          <% end %>
        </form>

        <div class="mt-2 text-xs text-gray-500 text-center">
          Powered by <span class="font-semibold text-indigo-400">Nous AI</span> •
          Real-time streaming enabled
        </div>
      </div>
    </div>
    """
  end

  # ===================================================================
  # Helpers
  # ===================================================================

  defp message_style(:user), do: "bg-indigo-600 text-white"
  defp message_style(:assistant), do: "bg-gray-800 border border-gray-700 text-gray-100"
  defp message_style(:error), do: "bg-red-900 border border-red-700 text-red-100"
  defp message_style(_), do: "bg-gray-800 text-gray-100"

  defp message_author(:user), do: "You"
  defp message_author(:assistant), do: "AI Assistant"
  defp message_author(:error), do: "Error"
  defp message_author(_), do: "System"

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

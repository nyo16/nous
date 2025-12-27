#!/usr/bin/env elixir

# Single-File Streaming Chat with LiveView
#
# Complete Phoenix LiveView chat application in one file!
# Features real-time streaming, message history, and modern UI.
#
# To run:
#   mix run examples/tutorials/03-production/single_file_streaming_chat.exs
#
# Then visit: http://localhost:4000

Mix.install([
  {:phoenix, "~> 1.7.0"},
  {:phoenix_live_view, "~> 0.20.0"},
  {:plug_cowboy, "~> 2.6"},
  {:jason, "~> 1.4"},
  {:bandit, "~> 1.0"},
  {:nous, path: "."}  # Use local Nous
])

# =============================================================================
# Streaming Chat Agent
# =============================================================================

defmodule StreamingChatAgent do
  @moduledoc """
  GenServer that handles streaming chat with message-based communication.

  Instead of blocking the LiveView, this agent sends streaming chunks
  via messages to the caller process.
  """

  use GenServer
  require Logger

  # Client API
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def chat_stream(message, caller_pid) do
    GenServer.cast(__MODULE__, {:chat_stream, message, caller_pid})
  end

  # GenServer Implementation
  def init(_) do
    agent = Nous.new(
      System.get_env("LLM_MODEL", "lmstudio:qwen/qwen3-30b"),
      instructions: """
      You are a helpful AI assistant. Be conversational and engaging.
      Use markdown formatting when helpful (bold, italic, code blocks, lists).
      Keep responses reasonably concise but informative.
      """,
      model_settings: %{temperature: 0.7, max_tokens: 1000}
    )

    {:ok, %{agent: agent, conversations: %{}}}
  end

  def handle_cast({:chat_stream, message, caller_pid}, state) do
    # Spawn streaming in separate process to avoid blocking GenServer
    spawn_link(fn ->
      stream_to_caller(state.agent, message, caller_pid)
    end)

    {:noreply, state}
  end

  defp stream_to_caller(agent, message, caller_pid) do
    Logger.info("Starting stream for: #{String.slice(message, 0, 50)}...")

    try do
      Nous.run_stream(agent, message)
      |> Stream.each(fn event ->
        case event do
          {:text_delta, text} ->
            send(caller_pid, {:chunk, text})

          {:finish, result} ->
            usage = if result, do: Map.from_struct(result.usage), else: %{}
            send(caller_pid, {:stream_complete, usage})

          {:error, reason} ->
            send(caller_pid, {:stream_error, reason})

          _ ->
            :ok
        end
      end)
      |> Stream.run()
    rescue
      error ->
        Logger.error("Stream error: #{inspect(error)}")
        send(caller_pid, {:stream_error, "Connection failed: #{inspect(error)}"})
    end
  end
end

# =============================================================================
# LiveView Chat Interface
# =============================================================================

defmodule StreamingChatLive do
  use Phoenix.LiveView
  require Logger

  def mount(_params, _session, socket) do
    # Start the chat agent
    {:ok, _} = StreamingChatAgent.start_link()

    socket = assign(socket,
      messages: [],
      input: "",
      streaming: false,
      current_response: "",
      total_tokens: 0,
      model: System.get_env("LLM_MODEL", "lmstudio:qwen/qwen3-30b")
    )

    {:ok, socket}
  end

  # ===== Event Handlers =====

  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" and not socket.assigns.streaming do
      # Add user message to chat
      user_msg = %{
        role: :user,
        content: message,
        timestamp: DateTime.utc_now()
      }

      # Start streaming response
      StreamingChatAgent.chat_stream(message, self())

      socket =
        socket
        |> assign(:messages, socket.assigns.messages ++ [user_msg])
        |> assign(:input, "")
        |> assign(:streaming, true)
        |> assign(:current_response, "")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("keydown", %{"key" => "Enter", "shiftKey" => false}, socket) do
    if socket.assigns.input != "" and not socket.assigns.streaming do
      handle_event("send_message", %{"message" => socket.assigns.input}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_chat", _params, socket) do
    {:noreply, assign(socket, messages: [], total_tokens: 0)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ===== Stream Message Handlers =====

  def handle_info({:chunk, text}, socket) do
    new_response = socket.assigns.current_response <> text

    socket = assign(socket, :current_response, new_response)
    {:noreply, socket}
  end

  def handle_info({:stream_complete, usage}, socket) do
    # Add complete assistant message
    assistant_msg = %{
      role: :assistant,
      content: socket.assigns.current_response,
      timestamp: DateTime.utc_now(),
      usage: usage
    }

    total_tokens = socket.assigns.total_tokens + (usage[:total_tokens] || 0)

    socket =
      socket
      |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
      |> assign(:streaming, false)
      |> assign(:current_response, "")
      |> assign(:total_tokens, total_tokens)

    {:noreply, socket}
  end

  def handle_info({:stream_error, error}, socket) do
    Logger.error("Chat stream error: #{inspect(error)}")

    error_msg = %{
      role: :error,
      content: "Sorry, there was an error: #{error}",
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> assign(:messages, socket.assigns.messages ++ [error_msg])
      |> assign(:streaming, false)
      |> assign(:current_response, "")

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ===== Render =====

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-gray-100">
      <!-- Header -->
      <div class="bg-gray-800 border-b border-gray-700 px-6 py-4">
        <div class="max-w-4xl mx-auto flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-white flex items-center gap-2">
              ⚡ Nous Streaming Chat
            </h1>
            <p class="text-sm text-gray-400">
              Real-time AI responses • Model: <code class="bg-gray-700 px-2 py-1 rounded"><%= @model %></code>
            </p>
          </div>

          <div class="flex items-center gap-4">
            <!-- Status & Token Counter -->
            <div class="text-right">
              <div class={"flex items-center gap-2 #{if @streaming, do: "text-yellow-400", else: "text-green-400"}"}>
                <div class={"w-2 h-2 rounded-full #{if @streaming, do: "bg-yellow-400 animate-pulse", else: "bg-green-400"}"}></div>
                <span class="text-sm"><%= if @streaming, do: "Streaming...", else: "Ready" %></span>
              </div>
              <div class="text-xs text-gray-500">
                Total: <%= @total_tokens %> tokens
              </div>
            </div>

            <!-- Clear Button -->
            <button
              phx-click="clear_chat"
              class="px-3 py-1 text-sm bg-gray-700 hover:bg-gray-600 rounded transition-colors"
            >
              Clear
            </button>
          </div>
        </div>
      </div>

      <!-- Chat Messages -->
      <div class="max-w-4xl mx-auto px-6 py-6">
        <div class="space-y-6 mb-6">
          <%= if Enum.empty?(@messages) and @current_response == "" do %>
            <!-- Welcome Screen -->
            <div class="text-center py-20">
              <div class="text-6xl mb-4">⚡</div>
              <h2 class="text-2xl font-semibold mb-2">Welcome to Nous Streaming Chat</h2>
              <p class="text-gray-400 text-lg">
                Watch AI responses appear in real-time, character by character
              </p>
            </div>
          <% else %>
            <!-- Message History -->
            <%= for msg <- @messages do %>
              <div class={"flex #{if msg.role == :user, do: "justify-end", else: "justify-start"}"}>
                <div class={"max-w-3xl rounded-lg px-4 py-3 #{message_style(msg.role)}"}>
                  <div class="flex items-center gap-2 mb-1 text-xs opacity-75">
                    <span class="font-semibold"><%= message_author(msg.role) %></span>
                    <span><%= format_time(msg.timestamp) %></span>
                    <%= if msg[:usage] do %>
                      <span>• <%= msg.usage.total_tokens || 0 %> tokens</span>
                    <% end %>
                  </div>
                  <div class="prose prose-invert max-w-none">
                    <%= format_content(msg.content) |> raw() %>
                  </div>
                </div>
              </div>
            <% end %>

            <!-- Current Streaming Response -->
            <%= if @streaming do %>
              <div class="flex justify-start">
                <div class="max-w-3xl rounded-lg px-4 py-3 bg-gray-800 border border-gray-700">
                  <div class="flex items-center gap-2 mb-1 text-xs">
                    <span class="font-semibold text-blue-400">AI Assistant</span>
                    <span class="text-yellow-400 animate-pulse">● streaming</span>
                  </div>
                  <div class="prose prose-invert max-w-none">
                    <%= if @current_response == "" do %>
                      <!-- Typing indicator -->
                      <div class="flex gap-1 py-2">
                        <div class="w-2 h-2 bg-blue-500 rounded-full animate-bounce"></div>
                        <div class="w-2 h-2 bg-blue-500 rounded-full animate-bounce" style="animation-delay: 0.1s"></div>
                        <div class="w-2 h-2 bg-blue-500 rounded-full animate-bounce" style="animation-delay: 0.2s"></div>
                      </div>
                    <% else %>
                      <%= format_content(@current_response) |> raw() %>
                      <span class="animate-pulse">▊</span>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Input Form -->
        <div class="sticky bottom-6">
          <form phx-submit="send_message" class="flex gap-3">
            <div class="flex-1">
              <textarea
                name="message"
                value={@input}
                phx-change="update_input"
                phx-keydown="keydown"
                placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
                rows="2"
                disabled={@streaming}
                class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg
                       text-gray-100 placeholder-gray-400 resize-none
                       focus:ring-2 focus:ring-blue-500 focus:border-transparent
                       disabled:bg-gray-700 disabled:cursor-not-allowed"
              ><%= @input %></textarea>
            </div>

            <button
              type="submit"
              disabled={@input == "" or @streaming}
              class="px-6 py-3 bg-blue-600 text-white font-medium rounded-lg
                     hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed
                     transition-colors flex items-center gap-2"
            >
              <%= if @streaming do %>
                <div class="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                Sending...
              <% else %>
                Send ⚡
              <% end %>
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # ===== Helpers =====

  defp message_style(:user), do: "bg-blue-600 text-white"
  defp message_style(:assistant), do: "bg-gray-800 border border-gray-700"
  defp message_style(:error), do: "bg-red-900 border border-red-700"

  defp message_author(:user), do: "You"
  defp message_author(:assistant), do: "AI Assistant"
  defp message_author(:error), do: "Error"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
  end

  defp format_content(content) do
    content
    |> String.replace(~r/\*\*(.*?)\*\*/, "<strong>\\1</strong>")  # Bold
    |> String.replace(~r/\*(.*?)\*/, "<em>\\1</em>")              # Italic
    |> String.replace(~r/`(.*?)`/, "<code class=\"bg-gray-700 px-1 rounded\">\\1</code>")  # Inline code
    |> String.replace("\n", "<br>")                              # Line breaks
  end
end

# =============================================================================
# Phoenix Application Setup
# =============================================================================

defmodule StreamingChatRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {StreamingChatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", StreamingChatWeb do
    pipe_through :browser
    live "/", StreamingChatLive
  end
end

defmodule StreamingChatWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta http-equiv="X-UA-Compatible" content="IE=edge"/>
        <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
        <title>Nous Streaming Chat</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script defer phx-track-static type="text/javascript" src="https://cdn.jsdelivr.net/npm/phoenix@1.7.0/priv/static/phoenix.min.js"></script>
        <script defer phx-track-static type="text/javascript" src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.0/priv/static/phoenix_live_view.min.js"></script>
        <script>
          window.liveSocket = new window.Phoenix.LiveView.LiveSocket("/live", window.Phoenix.Socket);
          window.liveSocket.connect();
        </script>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end

# =============================================================================
# Application Startup
# =============================================================================

children = [
  {Phoenix.PubSub, name: StreamingChatWeb.PubSub},
  {
    Bandit,
    scheme: :http,
    plug: StreamingChatRouter,
    options: [port: 4000]
  }
]

opts = [strategy: :one_for_one, name: StreamingChatWeb.Supervisor]

case Supervisor.start_link(children, opts) do
  {:ok, _} ->
    IO.puts("""

    🚀 Nous Streaming Chat is running!

    💻 Visit: http://localhost:4000
    🔧 Model: #{System.get_env("LLM_MODEL", "lmstudio:qwen/qwen3-30b")}

    💡 To use a different model:
       LLM_MODEL=anthropic:claude-3-5-sonnet mix run #{__ENV__.file}

    ⚡ Features:
       • Real-time streaming responses
       • Message history with token tracking
       • Modern dark UI with Tailwind CSS
       • Single-file deployment

    Press Ctrl+C to stop
    """)

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("❌ Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
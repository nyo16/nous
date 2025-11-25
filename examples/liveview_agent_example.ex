defmodule MyAppWeb.AgentChatLive do
  @moduledoc """
  LiveView example showing how to spawn and link AI agents.

  This demonstrates:
  - Spawning agent processes from LiveView
  - Proper process linking for cleanup
  - Streaming responses to the UI
  - Graceful shutdown when LiveView dies
  """

  use Phoenix.LiveView

  alias Yggdrasil.Agent

  # ============================================================================
  # LiveView Callbacks
  # ============================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:messages, [])
      |> assign(:agent_pid, nil)
      |> assign(:streaming, false)
      |> assign(:current_response, "")

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => user_message}, socket) do
    # Add user message to chat
    messages = socket.assigns.messages ++ [%{role: "user", content: user_message}]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, true)
      |> assign(:current_response, "")

    # Spawn linked agent process
    parent = self()

    agent_pid =
      spawn_link(fn ->
        run_agent_with_streaming(parent, user_message, socket.assigns.messages)
      end)

    {:noreply, assign(socket, :agent_pid, agent_pid)}
  end

  @impl true
  def handle_event("stop_generation", _params, socket) do
    # Kill the agent process if running
    if socket.assigns.agent_pid && Process.alive?(socket.assigns.agent_pid) do
      Process.exit(socket.assigns.agent_pid, :kill)
    end

    {:noreply, assign(socket, streaming: false, agent_pid: nil)}
  end

  @impl true
  def handle_info({:agent_response_delta, text}, socket) do
    # Stream text chunk to UI
    current = socket.assigns.current_response <> text

    socket =
      socket
      |> assign(:current_response, current)
      |> push_event("stream_text", %{text: text})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_response_complete, full_response, usage}, socket) do
    # Add complete assistant response to messages
    messages =
      socket.assigns.messages ++
        [%{role: "assistant", content: full_response, usage: usage}]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:agent_pid, nil)
      |> assign(:current_response, "")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_error, error}, socket) do
    socket =
      socket
      |> assign(:streaming, false)
      |> assign(:agent_pid, nil)
      |> put_flash(:error, "Agent error: #{inspect(error)}")

    {:noreply, socket}
  end

  # Clean up when LiveView terminates
  @impl true
  def terminate(_reason, socket) do
    # Kill agent process if still running
    if socket.assigns.agent_pid && Process.alive?(socket.assigns.agent_pid) do
      Process.exit(socket.assigns.agent_pid, :shutdown)
    end

    :ok
  end

  # ============================================================================
  # Agent Process Functions
  # ============================================================================

  defp run_agent_with_streaming(parent_pid, prompt, message_history) do
    # Create agent
    agent = create_agent()

    # Run with streaming
    case Agent.run_stream(agent, prompt, message_history: message_history) do
      {:ok, stream} ->
        accumulated_text = ""

        try do
          accumulated_text =
            stream
            |> Stream.each(fn
              {:text_delta, text} ->
                # Send each chunk to LiveView
                send(parent_pid, {:agent_response_delta, text})

              {:finish, _reason} ->
                :ok

              _ ->
                :ok
            end)
            |> Enum.reduce("", fn
              {:text_delta, text}, acc -> acc <> text
              _, acc -> acc
            end)

          # Get final result
          {:ok, final_result} = Agent.run(agent, prompt, message_history: message_history)

          # Send complete response
          send(parent_pid, {:agent_response_complete, final_result.output, final_result.usage})
        rescue
          error ->
            send(parent_pid, {:agent_error, error})
        end

      {:error, error} ->
        send(parent_pid, {:agent_error, error})
    end
  end

  defp create_agent do
    # Choose provider based on environment
    model =
      case System.get_env("ANTHROPIC_API_KEY") do
        nil -> "lmstudio:qwen/qwen3-30b-a3b-2507"
        _key -> "anthropic:claude-sonnet-4-5-20250929"
      end

    Agent.new(model,
      instructions: """
      You are a helpful AI assistant in a chat interface.
      Be concise but friendly. Use markdown formatting when helpful.
      """,
      model_settings: %{
        temperature: 0.7,
        max_tokens: 1000
      }
    )
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="chat-container">
      <div class="messages">
        <%= for message <- @messages do %>
          <div class={"message message-#{message.role}"}>
            <strong><%= message.role %>:</strong>
            <div class="content"><%= message.content %></div>
          </div>
        <% end %>

        <%= if @streaming do %>
          <div class="message message-assistant streaming">
            <strong>assistant:</strong>
            <div class="content">
              <%= @current_response %><span class="cursor">▊</span>
            </div>
          </div>
        <% end %>
      </div>

      <form phx-submit="send_message" class="input-form">
        <input
          type="text"
          name="message"
          placeholder="Type your message..."
          disabled={@streaming}
          autocomplete="off"
        />
        <button type="submit" disabled={@streaming}>
          Send
        </button>

        <%= if @streaming do %>
          <button type="button" phx-click="stop_generation">
            Stop
          </button>
        <% end %>
      </form>
    </div>
    """
  end
end

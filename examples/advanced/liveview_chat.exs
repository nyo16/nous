#!/usr/bin/env elixir

# Nous AI - LiveView Chat Interface
# A full-featured chat UI built with Nous + Phoenix LiveView

IO.puts("=== Nous AI - LiveView Chat Interface ===\n")

# ============================================================================
# Overview
# ============================================================================

IO.puts("""
This example prints a complete, copy-pasteable LiveView chat module.
It is a REFERENCE implementation: the module needs Phoenix and LiveView,
which Nous does not depend on, so it is printed rather than compiled.
Paste it into your own Phoenix application.

It covers the full lifecycle: mount -> user input -> streaming response ->
tool calls -> completion -> multi-turn continuation.

Features:
1. Real-time streaming responses via notify_pid
2. Message history with auto-scroll (JS hook)
3. Tool call / result visualization inline in the chat
4. Session persistence across reconnects (LiveView double-mount)
5. Typing indicator while the agent is generating
6. Error handling with user-friendly retry

Prerequisites:
  - Phoenix ~> 1.7 with LiveView ~> 0.20
  - Nous added to your deps
  - PubSub configured:  config :nous, pubsub: MyApp.PubSub

See also:
  - docs/guides/liveview-integration.md         (full guide)
  - examples/advanced/liveview_integration.exs  (quick patterns)
  - examples/advanced/liveview_multi_agent.exs  (multi-agent dashboard)
""")

# ============================================================================
# The Chat LiveView
# ============================================================================

IO.puts("--- MyAppWeb.ChatLive ---")

IO.puts(~S'''
defmodule MyAppWeb.ChatLive do
  @moduledoc """
  LiveView chat interface backed by a Nous agent.

  Handles the full lifecycle: mount -> user input -> streaming response ->
  tool calls -> completion -> multi-turn continuation.
  """
  use MyAppWeb, :live_view

  # ------------------------------------------------------------------
  # Mount
  # ------------------------------------------------------------------

  @impl true
  def mount(params, session, socket) do
    # LiveView calls mount/3 twice:
    #   1. Static render (disconnected) — no WebSocket yet
    #   2. Connected render — WebSocket established
    #
    # We only initialize the agent on connected mount to avoid
    # creating resources that will be immediately discarded.

    if connected?(socket) do
      mount_connected(params, session, socket)
    else
      # Disconnected (static) render — minimal assigns for initial HTML
      {:ok,
       assign(socket,
         messages: [],
         current_response: "",
         tool_calls: [],
         streaming: false,
         error: nil,
         form: to_form(%{"message" => ""})
       )}
    end
  end

  defp mount_connected(_params, session, socket) do
    session_id = session["session_id"] || generate_session_id()

    # Create the agent. In production you might look up an existing
    # AgentServer via Registry instead of creating a fresh agent.
    agent =
      Nous.new("lmstudio:qwen3",
        instructions: """
        You are a helpful assistant. Be concise and clear.
        When you use tools, explain what you are doing.
        """,
        tools: chat_tools()
      )

    # If you persist conversation history (e.g. in a database), load it here.
    # history = MyApp.Chat.load_history(session_id)
    history = []

    {:ok,
     assign(socket,
       session_id: session_id,
       agent: agent,
       context: nil,
       messages: history,
       current_response: "",
       tool_calls: [],
       streaming: false,
       error: nil,
       current_task: nil,
       form: to_form(%{"message" => ""})
     )}
  end

  # ------------------------------------------------------------------
  # User sends a message
  # ------------------------------------------------------------------

  @impl true
  def handle_event("send", %{"message" => message}, socket)
      when byte_size(message) > 0 do
    # Ignore if already streaming
    if socket.assigns.streaming do
      {:noreply, socket}
    else
      # Append user message to history
      messages = socket.assigns.messages ++ [%{role: :user, content: message}]

      # Launch the agent run in a Task so we don't block the LiveView process.
      # notify_pid sends events (:agent_delta, :agent_complete, etc.) back to us.
      task =
        Task.async(fn ->
          Nous.run(socket.assigns.agent, message,
            context: socket.assigns.context,
            # `stream: true` is what makes on_llm_new_delta / {:agent_delta, _}
            # fire. Without it the run only reports the final message.
            stream: true,
            notify_pid: socket.root_pid
          )
        end)

      {:noreply,
       socket
       |> assign(
         messages: messages,
         current_response: "",
         tool_calls: [],
         streaming: true,
         error: nil,
         current_task: task
       )
       |> assign(form: to_form(%{"message" => ""}))
       |> push_event("scroll_bottom", %{})}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  # ------------------------------------------------------------------
  # Cancel generation
  # ------------------------------------------------------------------

  def handle_event("cancel", _params, socket) do
    if task = socket.assigns[:current_task] do
      Task.shutdown(task, :brutal_kill)
    end

    # Keep partial response if the user wants to see what was generated
    messages =
      if socket.assigns.current_response != "" do
        socket.assigns.messages ++
          [%{role: :assistant, content: socket.assigns.current_response <> " [cancelled]"}]
      else
        socket.assigns.messages
      end

    {:noreply,
     assign(socket,
       messages: messages,
       current_response: "",
       tool_calls: [],
       streaming: false,
       current_task: nil
     )}
  end

  # ------------------------------------------------------------------
  # Retry after error
  # ------------------------------------------------------------------

  def handle_event("retry", _params, socket) do
    # Re-send the last user message
    last_user_msg =
      socket.assigns.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))

    if last_user_msg do
      handle_event("send", %{"message" => last_user_msg.content}, socket)
    else
      {:noreply, socket}
    end
  end

  # ------------------------------------------------------------------
  # Streaming callbacks (handle_info)
  # ------------------------------------------------------------------

  # Text delta — append to the in-progress response
  @impl true
  def handle_info({:agent_delta, text}, socket) do
    {:noreply,
     socket
     |> assign(current_response: socket.assigns.current_response <> text)
     |> push_event("scroll_bottom", %{})}
  end

  # Tool call started — show it in the UI
  def handle_info({:tool_call, call}, socket) do
    tool_call = %{
      id: Map.get(call, :id, generate_session_id()),
      name: call.name,
      arguments: call.arguments,
      status: :running,
      result: nil
    }

    {:noreply, assign(socket, tool_calls: socket.assigns.tool_calls ++ [tool_call])}
  end

  # Tool call finished — update its status
  def handle_info({:tool_result, %{id: id, result: result}}, socket) do
    tool_calls =
      Enum.map(socket.assigns.tool_calls, fn tc ->
        if tc.id == id, do: %{tc | status: :completed, result: result}, else: tc
      end)

    {:noreply, assign(socket, tool_calls: tool_calls)}
  end

  # Generation complete — finalize the assistant message
  def handle_info({:agent_complete, result}, socket) do
    assistant_msg = %{
      role: :assistant,
      content: result.output,
      tool_calls: socket.assigns.tool_calls
    }

    messages = socket.assigns.messages ++ [assistant_msg]

    # Optionally persist: MyApp.Chat.save_history(socket.assigns.session_id, messages)

    {:noreply,
     socket
     |> assign(
       messages: messages,
       current_response: "",
       tool_calls: [],
       context: result.context,
       streaming: false,
       current_task: nil
     )
     |> push_event("scroll_bottom", %{})}
  end

  # Generation error
  def handle_info({:agent_error, error}, socket) do
    {:noreply,
     assign(socket,
       error: format_error(error),
       streaming: false,
       current_task: nil
     )}
  end

  # Task finished (ref message) — clean up the monitor
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  # Task crashed
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    if reason != :normal do
      {:noreply,
       assign(socket,
         error: "Agent process crashed: #{inspect(reason)}",
         streaming: false,
         current_task: nil
       )}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ------------------------------------------------------------------
  # Template
  # ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-4 flex flex-col h-screen">
      <%!-- Message history --%>
      <div id="chat-messages" class="flex-1 overflow-y-auto space-y-4 mb-4" phx-hook="ScrollBottom">
        <%= for msg <- @messages do %>
          <.chat_message message={msg} />
        <% end %>

        <%!-- Streaming response in progress --%>
        <%= if @streaming and @current_response != "" do %>
          <div class="p-3 rounded-lg bg-gray-100 mr-8">
            <div class="font-semibold text-sm text-gray-500 mb-1">Assistant</div>
            <div class="whitespace-pre-wrap"><%= @current_response %><span class="animate-pulse">|</span></div>
          </div>
        <% end %>

        <%!-- Active tool calls --%>
        <%= for tc <- @tool_calls do %>
          <div class="mx-4 p-2 border rounded text-sm bg-yellow-50">
            <span class="font-mono font-bold"><%= tc.name %></span>
            <span class="text-gray-500 ml-2"><%= inspect(tc.arguments) %></span>
            <%= if tc.status == :completed do %>
              <div class="mt-1 text-green-700"><%= inspect(tc.result) %></div>
            <% else %>
              <div class="mt-1 text-gray-400 animate-pulse">Running...</div>
            <% end %>
          </div>
        <% end %>

        <%!-- Typing indicator --%>
        <%= if @streaming and @current_response == "" and @tool_calls == [] do %>
          <div class="p-3 rounded-lg bg-gray-50 mr-8 text-gray-400 animate-pulse">
            Thinking...
          </div>
        <% end %>
      </div>

      <%!-- Error banner --%>
      <%= if @error do %>
        <div class="mb-4 p-3 rounded-lg bg-red-100 text-red-700 flex justify-between items-center">
          <span><%= @error %></span>
          <button phx-click="retry" class="text-sm underline ml-4">Retry</button>
        </div>
      <% end %>

      <%!-- Input form --%>
      <.form for={@form} phx-submit="send" class="flex gap-2">
        <input
          type="text"
          name="message"
          value={@form[:message].value}
          placeholder="Type your message..."
          disabled={@streaming}
          autocomplete="off"
          class="flex-1 p-2 border rounded focus:outline-none focus:ring-2 focus:ring-blue-300"
        />
        <%= if @streaming do %>
          <button type="button" phx-click="cancel" class="px-4 py-2 bg-red-500 text-white rounded">
            Stop
          </button>
        <% else %>
          <button type="submit" class="px-4 py-2 bg-blue-500 text-white rounded">
            Send
          </button>
        <% end %>
      </.form>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Components
  # ------------------------------------------------------------------

  defp chat_message(assigns) do
    ~H"""
    <div class={[
      "p-3 rounded-lg",
      @message.role == :user && "bg-blue-100 ml-8",
      @message.role == :assistant && "bg-gray-100 mr-8"
    ]}>
      <div class="font-semibold text-sm text-gray-500 mb-1">
        <%= if @message.role == :user, do: "You", else: "Assistant" %>
      </div>
      <div class="whitespace-pre-wrap"><%= @message.content %></div>

      <%!-- Show tool calls that were part of this message --%>
      <%= if tool_calls = Map.get(@message, :tool_calls, []) do %>
        <%= for tc <- tool_calls do %>
          <div class="mt-2 p-2 border rounded text-xs bg-white">
            <span class="font-mono"><%= tc.name %></span>
            <span class="text-gray-400 ml-1"><%= inspect(tc.result) %></span>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # JS Hook (add to your app.js)
  # ------------------------------------------------------------------

  # In your app.js, register this hook:
  #
  #   Hooks.ScrollBottom = {
  #     mounted() { this.scrollToBottom() },
  #     updated() { this.scrollToBottom() },
  #     scrollToBottom() {
  #       this.el.scrollTop = this.el.scrollHeight
  #     }
  #   }
  #
  #   let liveSocket = new LiveSocket("/live", Socket, {
  #     hooks: Hooks,
  #     ...
  #   })

  # ------------------------------------------------------------------
  # Example tools
  # ------------------------------------------------------------------

  # Always wrap tool functions with Nous.Tool.from_function/2. A bare
  # function capture carries no parameter schema, so the model never
  # learns which arguments the tool expects.
  defp chat_tools do
    [
      Nous.Tool.from_function(&weather_tool/2,
        name: "get_weather",
        description: "Get the current weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["city"]
        }
      ),
      Nous.Tool.from_function(&search_tool/2,
        name: "search",
        description: "Search for information",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"}
          },
          "required" => ["query"]
        }
      )
    ]
  end

  defp weather_tool(_ctx, %{"city" => city}) do
    # Replace with a real API call
    Process.sleep(300)
    %{city: city, temperature: 72, conditions: "sunny", unit: "F"}
  end

  defp search_tool(_ctx, %{"query" => query}) do
    # Replace with a real search backend
    Process.sleep(200)
    %{results: ["Result 1 for #{query}", "Result 2 for #{query}"]}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp format_error(%{message: msg}), do: msg
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: "Something went wrong: #{inspect(error)}"
end
''')

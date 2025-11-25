defmodule MyApp.AgentServer do
  @moduledoc """
  GenServer example for managing AI agents with proper lifecycle.

  This shows how to:
  - Wrap agents in a GenServer
  - Handle async agent runs
  - Link processes for cleanup
  - Manage conversation state
  - Gracefully shutdown
  """

  use GenServer
  require Logger

  alias Yggdrasil.Agent

  # ============================================================================
  # Client API
  # ============================================================================

  @doc "Start the agent server"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a message to the agent"
  def chat(message, opts \\ []) do
    GenServer.call(__MODULE__, {:chat, message, opts}, 60_000)
  end

  @doc "Send a message with streaming callback"
  def chat_stream(message, callback, opts \\ []) do
    GenServer.call(__MODULE__, {:chat_stream, message, callback, opts}, 120_000)
  end

  @doc "Get conversation history"
  def get_history do
    GenServer.call(__MODULE__, :get_history)
  end

  @doc "Clear conversation history"
  def clear_history do
    GenServer.call(__MODULE__, :clear_history)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Create the agent
    model = Keyword.get(opts, :model, "lmstudio:qwen/qwen3-30b-a3b-2507")
    instructions = Keyword.get(opts, :instructions, "You are a helpful assistant")
    tools = Keyword.get(opts, :tools, [])

    agent =
      Agent.new(model,
        instructions: instructions,
        tools: tools,
        model_settings: %{
          temperature: 0.7,
          max_tokens: 1000
        }
      )

    state = %{
      agent: agent,
      conversation_history: [],
      running_tasks: %{}
    }

    Logger.info("AgentServer started with model: #{model}")

    {:ok, state}
  end

  @impl true
  def handle_call({:chat, message, opts}, from, state) do
    # Spawn linked task to run agent
    task =
      Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
        Logger.debug("Running agent for message: #{String.slice(message, 0..50)}...")

        result =
          Agent.run(state.agent, message,
            message_history: state.conversation_history,
            deps: Keyword.get(opts, :deps)
          )

        Logger.debug("Agent completed")
        result
      end)

    # Store task reference
    new_tasks = Map.put(state.running_tasks, task.ref, from)
    {:noreply, %{state | running_tasks: new_tasks}}
  end

  @impl true
  def handle_call({:chat_stream, message, callback, opts}, from, state) do
    # Spawn linked task for streaming
    task =
      Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
        case Agent.run_stream(state.agent, message,
               message_history: state.conversation_history,
               deps: Keyword.get(opts, :deps)
             ) do
          {:ok, stream} ->
            stream
            |> Stream.each(fn event ->
              case event do
                {:text_delta, text} -> callback.({:delta, text})
                {:finish, _} -> callback.(:complete)
                _ -> :ok
              end
            end)
            |> Stream.run()

            # Get final result
            Agent.run(state.agent, message, message_history: state.conversation_history)

          error ->
            error
        end
      end)

    new_tasks = Map.put(state.running_tasks, task.ref, from)
    {:noreply, %{state | running_tasks: new_tasks}}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.conversation_history, state}
  end

  @impl true
  def handle_call(:clear_history, _from, state) do
    {:reply, :ok, %{state | conversation_history: []}}
  end

  # Handle task completion
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    case Map.pop(state.running_tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {from, remaining_tasks} ->
        # Reply to the caller
        case result do
          {:ok, agent_result} ->
            # Update conversation history
            new_history = state.conversation_history ++ agent_result.new_messages

            GenServer.reply(from, {:ok, agent_result})
            {:noreply, %{state | conversation_history: new_history, running_tasks: remaining_tasks}}

          error ->
            GenServer.reply(from, error)
            {:noreply, %{state | running_tasks: remaining_tasks}}
        end
    end
  end

  # Handle task failure
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.warning("Agent task failed: #{inspect(reason)}")

    case Map.pop(state.running_tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {from, remaining_tasks} ->
        GenServer.reply(from, {:error, {:task_failed, reason}})
        {:noreply, %{state | running_tasks: remaining_tasks}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("AgentServer terminating: #{inspect(reason)}")

    # Cancel all running tasks
    for {ref, _from} <- state.running_tasks do
      Task.Supervisor.terminate_child(MyApp.TaskSupervisor, ref)
    end

    :ok
  end
end

# ============================================================================
# Usage Example
# ============================================================================

defmodule MyApp.AgentExample do
  @moduledoc """
  Example usage of AgentServer.
  """

  def run_example do
    # Start the application supervisor (if not already started)
    # You would normally have this in your application.ex:
    #
    # children = [
    #   {Task.Supervisor, name: MyApp.TaskSupervisor},
    #   {MyApp.AgentServer, model: "anthropic:claude-sonnet-4-5-20250929"}
    # ]

    IO.puts("🤖 AgentServer Example")
    IO.puts("=" |> String.duplicate(70))

    # Chat with the agent
    IO.puts("\nSending message to agent...")

    case MyApp.AgentServer.chat("What is Elixir?") do
      {:ok, result} ->
        IO.puts("\n✅ Response:")
        IO.puts(result.output)
        IO.puts("\n📊 Tokens: #{result.usage.total_tokens}")

      {:error, error} ->
        IO.puts("\n❌ Error: #{inspect(error)}")
    end

    # Streaming example
    IO.puts("\n\nStreaming message to agent...")
    IO.write("Response: ")

    MyApp.AgentServer.chat_stream(
      "Count to 5",
      fn
        {:delta, text} -> IO.write(text)
        :complete -> IO.puts("\n[Complete]")
      end
    )

    IO.puts("\n\n" <> ("=" |> String.duplicate(70)))
  end
end

# ============================================================================
# Simplified LiveView Integration Pattern
# ============================================================================

defmodule MyAppWeb.SimpleChatLive do
  @moduledoc """
  Simplified pattern for LiveView + Agent integration.
  """

  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], input: "")}
  end

  @impl true
  def handle_event("send", %{"message" => msg}, socket) do
    # Update UI immediately
    socket = assign(socket, messages: socket.assigns.messages ++ [{:user, msg}])

    # Spawn linked process to run agent
    parent = self()

    spawn_link(fn ->
      agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")
      {:ok, result} = Yggdrasil.run(agent, msg)

      # Send result back to LiveView
      send(parent, {:agent_done, result.output})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_done, response}, socket) do
    messages = socket.assigns.messages ++ [{:assistant, response}]
    {:noreply, assign(socket, :messages, messages)}
  end

  # LiveView process dies → linked agent process automatically dies
  # No manual cleanup needed thanks to spawn_link/1
end

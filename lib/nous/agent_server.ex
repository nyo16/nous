defmodule Nous.AgentServer do
  @moduledoc """
  GenServer wrapper for Nous agents with PubSub integration.

  This server:
  - Wraps an Nous agent (standard or ReAct)
  - Links to parent process (dies when parent dies)
  - Subscribes to PubSub for incoming messages
  - Publishes responses back via PubSub
  - Maintains conversation history

  ## Usage with LiveView

      defmodule MyAppWeb.ChatLive do
        use MyAppWeb, :live_view

        def mount(_params, _session, socket) do
          # Start agent linked to this LiveView
          {:ok, agent_pid} = AgentServer.start_link(
            session_id: socket.assigns.session_id,
            agent_config: %{
              model: "lmstudio:qwen/qwen3-30b",
              instructions: "You are a helpful assistant",
              tools: []
            }
          )

          # Subscribe to responses
          Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:\#{socket.assigns.session_id}")

          {:ok, assign(socket, agent_pid: agent_pid, messages: [])}
        end

        def handle_event("send_message", %{"message" => msg}, socket) do
          # Send message to agent via PubSub
          Phoenix.PubSub.broadcast(
            MyApp.PubSub,
            "agent:\#{socket.assigns.session_id}",
            {:user_message, msg}
          )

          {:noreply, socket}
        end

        def handle_info({:agent_response, response}, socket) do
          # Receive agent response
          messages = socket.assigns.messages ++ [%{role: :assistant, content: response}]
          {:noreply, assign(socket, messages: messages)}
        end
      end

  """

  use GenServer
  require Logger

  @type agent_config :: %{
          model: String.t(),
          instructions: String.t(),
          tools: list(),
          type: :standard | :react,
          model_settings: map()
        }

  @type state :: %{
          session_id: String.t(),
          agent: Nous.Agent.t() | Nous.ReActAgent.t(),
          conversation_history: list(),
          pubsub: module(),
          topic: String.t(),
          agent_type: :standard | :react,
          current_task: Task.t() | nil,
          cancelled: boolean(),
          subscribe_fn: (any(), String.t() -> :ok | {:error, any()}),
          broadcast_fn: (any(), String.t(), any() -> :ok | {:error, any()})
        }

  # Client API

  @doc """
  Start an AgentServer linked to the calling process.

  ## Options

  - `:session_id` - Unique session identifier (required)
  - `:agent_config` - Agent configuration map (required)
  - `:pubsub` - PubSub module (default: MyApp.PubSub)

  ## Agent Config

  - `:model` - Model string (e.g., "openai:gpt-4")
  - `:instructions` - System instructions
  - `:tools` - List of tool functions
  - `:type` - `:standard` or `:react` (default: :standard)
  - `:model_settings` - Model settings map

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a message to the agent.
  """
  @spec send_message(pid(), String.t()) :: :ok
  def send_message(pid, message) do
    GenServer.cast(pid, {:user_message, message})
  end

  @doc """
  Get conversation history.
  """
  @spec get_history(pid()) :: list()
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  @doc """
  Clear conversation history.
  """
  @spec clear_history(pid()) :: :ok
  def clear_history(pid) do
    GenServer.cast(pid, :clear_history)
  end

  @doc """
  Cancel the current agent execution.

  This will:
  - Shutdown the running task gracefully
  - Broadcast a cancellation message
  - Reset the cancelled flag for future executions
  """
  @spec cancel_execution(pid()) :: :ok
  def cancel_execution(pid) do
    GenServer.call(pid, :cancel_execution)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_config = Keyword.fetch!(opts, :agent_config)
    pubsub = Keyword.get(opts, :pubsub, MyApp.PubSub)

    # Subscribe to messages for this session
    topic = "agent:#{session_id}"

    # Set up PubSub functions based on availability
    {subscribe_fn, broadcast_fn} = setup_pubsub_functions()

    # Subscribe if functions are available
    subscribe_fn.(pubsub, topic)

    # Create agent based on type
    agent_type = Map.get(agent_config, :type, :standard)

    agent = case agent_type do
      :react ->
        Nous.ReActAgent.new(
          agent_config.model,
          instructions: Map.get(agent_config, :instructions, ""),
          tools: Map.get(agent_config, :tools, []),
          model_settings: Map.get(agent_config, :model_settings, %{})
        )

      :standard ->
        Nous.Agent.new(
          agent_config.model,
          instructions: Map.get(agent_config, :instructions, ""),
          tools: Map.get(agent_config, :tools, []),
          model_settings: Map.get(agent_config, :model_settings, %{})
        )
    end

    Logger.info("AgentServer started for session: #{session_id}")

    state = %{
      session_id: session_id,
      agent: agent,
      conversation_history: [],
      pubsub: pubsub,
      topic: topic,
      agent_type: agent_type,
      current_task: nil,
      cancelled: false,
      subscribe_fn: subscribe_fn,
      broadcast_fn: broadcast_fn
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:user_message, message}, state) do
    # Kill any existing task if running
    if state.current_task do
      Logger.warning("Cancelling existing task for new message in session: #{state.session_id}")
      Task.shutdown(state.current_task, :brutal_kill)
    end

    # Broadcast that we're processing
    broadcast(state, {:agent_status, :thinking})

    # Add user message to history
    user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}
    conversation_history = state.conversation_history ++ [user_msg]

    # Reset cancelled flag for new execution
    state = %{state | cancelled: false}

    # Run agent asynchronously and track the task
    server_pid = self()
    task = Task.async(fn ->
      try do
        run_agent_and_respond(server_pid, state, message, conversation_history)
      after
        # Always ensure cleanup message is sent
        send(server_pid, {:agent_task_finished})
      end
    end)

    {:noreply, %{state | conversation_history: conversation_history, current_task: task}}
  end

  @impl true
  def handle_cast(:clear_history, state) do
    Logger.info("Clearing conversation history for session: #{state.session_id}")
    {:noreply, %{state | conversation_history: []}}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.conversation_history, state}
  end

  @impl true
  def handle_call(:cancel_execution, _from, state) do
    case state.current_task do
      nil ->
        Logger.info("No execution to cancel for session: #{state.session_id}")
        {:reply, {:ok, :no_execution}, state}

      task ->
        Logger.info("Cancelling execution for session: #{state.session_id}")

        # Set cancelled flag - the runner will check this
        state = %{state | cancelled: true}

        # Shutdown task gracefully with timeout
        Task.shutdown(task, 5_000)

        # Broadcast cancellation
        broadcast(state, {:agent_cancelled, "Execution cancelled by user"})

        # Clear current task
        state = %{state | current_task: nil, cancelled: false}

        {:reply, {:ok, :cancelled}, state}
    end
  end

  @impl true
  def handle_call(:is_cancelled, _from, state) do
    {:reply, state.cancelled, state}
  end

  @impl true
  def handle_info({:user_message, message}, state) do
    # Handle messages from PubSub
    handle_cast({:user_message, message}, state)
  end

  @impl true
  def handle_info({:agent_response_ready, _assistant_msg, history}, state) do
    # Update state with new history and clear current task
    {:noreply, %{state | conversation_history: history, current_task: nil}}
  end

  @impl true
  def handle_info({:agent_task_completed, _reason}, state) do
    # Task completed (with error or cancellation), clear it
    {:noreply, %{state | current_task: nil}}
  end

  @impl true
  def handle_info({:agent_task_finished}, state) do
    # Task finished (cleanup from try/after), clear it
    {:noreply, %{state | current_task: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task completed or died, clear it
    {:noreply, %{state | current_task: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("AgentServer terminating for session #{state.session_id}: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  defp run_agent_and_respond(server_pid, state, message, current_history) do
    # Check if cancelled before starting
    if state.cancelled do
      Logger.info("Execution cancelled before agent run for session: #{state.session_id}")
      broadcast(state, {:agent_cancelled, "Execution cancelled"})
      :cancelled
    else
      do_agent_run(server_pid, state, message, current_history)
    end
  end

  defp do_agent_run(server_pid, state, message, current_history) do
    # Extract message history for agent
    message_history = extract_message_history(current_history)

    # Run agent with cancellation check
    result = case state.agent_type do
      :react ->
        Nous.ReActAgent.run(state.agent, message,
          message_history: message_history,
          max_iterations: 15,
          cancellation_check: fn -> check_cancelled(server_pid) end
        )

      :standard ->
        Nous.Agent.run(state.agent, message,
          message_history: message_history,
          cancellation_check: fn -> check_cancelled(server_pid) end
        )
    end

    case result do
      {:ok, response} ->
        # Create assistant message
        assistant_msg = %{
          role: :assistant,
          content: response.output,
          timestamp: DateTime.utc_now(),
          usage: response.usage
        }

        # Update history
        new_history = current_history ++ [assistant_msg]

        # Broadcast response
        broadcast(state, {:agent_response, response.output, assistant_msg})
        send(server_pid, {:agent_response_ready, assistant_msg, new_history})

      {:error, %Nous.Errors.ExecutionCancelled{}} ->
        Logger.info("Agent execution was cancelled for session: #{state.session_id}")
        broadcast(state, {:agent_cancelled, "Execution cancelled"})
        # Send completion message to clear task
        send(server_pid, {:agent_task_completed, :cancelled})

      {:error, error} ->
        error_msg = Exception.message(error)
        Logger.error("Agent error in session #{state.session_id}: #{error_msg}")

        # Broadcast error
        broadcast(state, {:agent_error, error_msg})
        # Send completion message to clear task
        send(server_pid, {:agent_task_completed, :error})
    end
  end

  defp check_cancelled(server_pid) do
    # Check if the server's cancelled flag is set
    try do
      case GenServer.call(server_pid, :is_cancelled, 100) do
        true -> throw({:cancelled, "Execution cancelled"})
        false -> :ok
      end
    catch
      :exit, _ -> :ok  # Server might be shutting down, continue
    end
  end

  defp extract_message_history(conversation_history) do
    # Convert our history format to agent's message format
    # Skip the last user message as it will be passed as prompt
    conversation_history
    |> Enum.slice(0..-2//1)
    |> Enum.flat_map(fn msg ->
      case msg.role do
        :user -> [{:user_prompt, msg.content}]
        :assistant -> [{:text, msg.content}]
        _ -> []
      end
    end)
  end

  defp broadcast(state, message) do
    state.broadcast_fn.(state.pubsub, state.topic, message)
  end

  # Set up PubSub functions based on Phoenix.PubSub availability
  defp setup_pubsub_functions do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      # Phoenix.PubSub is available, use real functions with apply/3 to avoid compile-time warnings
      subscribe_fn = fn pubsub, topic ->
        try do
          apply(Phoenix.PubSub, :subscribe, [pubsub, topic])
        catch
          # Handle case where pubsub module doesn't exist
          :error, :undef -> :ok
          :error, _ -> :ok
        end
      end

      broadcast_fn = fn pubsub, topic, message ->
        try do
          apply(Phoenix.PubSub, :broadcast, [pubsub, topic, message])
        catch
          # Handle case where pubsub module doesn't exist
          :error, :undef -> :ok
          :error, _ -> :ok
        end
      end

      {subscribe_fn, broadcast_fn}
    else
      # Phoenix.PubSub not available, use no-op functions
      no_op = fn _, _ -> :ok end
      no_op_broadcast = fn _, _, _ -> :ok end
      {no_op, no_op_broadcast}
    end
  end
end

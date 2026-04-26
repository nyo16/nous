defmodule Nous.AgentServer do
  @moduledoc """
  GenServer wrapper for Nous agents with PubSub integration.

  This server:
  - Wraps a Nous agent (standard or ReAct)
  - Links to parent process (dies when parent dies)
  - Subscribes to PubSub for incoming messages
  - Publishes responses back via PubSub
  - Maintains conversation context for multi-turn conversations

  ## Context-Based State

  Uses `Nous.Agent.Context` to maintain conversation state:
  - Messages accumulate across turns
  - Tool calls are tracked
  - Usage is aggregated
  - Callbacks forward to PubSub

  ## Usage with LiveView

      defmodule MyAppWeb.ChatLive do
        use MyAppWeb, :live_view

        def mount(_params, _session, socket) do
          # Start agent linked to this LiveView
          {:ok, agent_pid} = AgentServer.start_link(
            session_id: socket.assigns.session_id,
            agent_config: %{
              model: "lmstudio:qwen3-vl-4b-thinking-mlx",
              instructions: "You are a helpful assistant",
              tools: []
            }
          )

          # Subscribe to responses
          Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:\#{socket.assigns.session_id}")

          {:ok, assign(socket, agent_pid: agent_pid, messages: [])}
        end

        def handle_event("send_message", %{"message" => msg}, socket) do
          AgentServer.send_message(socket.assigns.agent_pid, msg)
          {:noreply, socket}
        end

        # Receive streaming deltas
        def handle_info({:agent_delta, text}, socket) do
          # Append text to current response
          {:noreply, update(socket, :current_response, &(&1 <> text))}
        end

        # Receive complete response
        def handle_info({:agent_complete, result}, socket) do
          messages = socket.assigns.messages ++ [%{role: :assistant, content: result.output}]
          {:noreply, assign(socket, messages: messages, current_response: "")}
        end

        # Receive tool calls
        def handle_info({:tool_call, call}, socket) do
          # Show tool call in UI
          {:noreply, socket}
        end
      end

  ## Message Interruption

  Calling `send_message/2` while the agent is already processing a request
  automatically cancels the in-flight execution and starts a new one. The
  server uses an `:atomics`-based flag so the running task can detect
  cancellation without message-passing overhead. Both the interrupted
  user message and the new one are preserved in the conversation context,
  so no input is lost.

  ## PubSub Events

  Subscribers on the `"agent:<session_id>"` topic receive the following
  messages:

  | Message                          | Description                             |
  |----------------------------------|-----------------------------------------|
  | `{:agent_status, :thinking}`     | A new run is about to start             |
  | `{:agent_status, :started}`      | The LLM provider acknowledged the call  |
  | `{:agent_delta, text}`           | A streaming text chunk                  |
  | `{:tool_call, call}`             | A tool invocation is in progress        |
  | `{:tool_result, result}`         | A tool returned its result              |
  | `{:agent_response, output}`      | The final text output of the run        |
  | `{:agent_complete, result}`      | The full result struct (output + context + usage) |
  | `{:agent_error, message}`        | An error occurred during execution      |
  | `{:agent_cancelled, reason}`     | The execution was cancelled             |

  ## Lifecycle

  Each server starts an inactivity timer (default 5 minutes, configurable
  via `:inactivity_timeout`). The timer resets on every `send_message/2`
  call. When the timer fires, the server terminates with `:normal`.

  If a `:persistence` backend is configured, the conversation context is
  automatically saved after each successful agent run and restored on
  `start_link/1`.
  """

  use GenServer
  require Logger

  alias Nous.Agent.Context
  alias Nous.Message

  @type agent_config :: %{
          model: String.t(),
          instructions: String.t(),
          tools: list(),
          type: :standard | :react,
          model_settings: map()
        }

  @type state :: %{
          session_id: String.t(),
          agent: Nous.Agent.t(),
          context: Context.t(),
          pubsub: module() | nil,
          topic: String.t(),
          agent_type: :standard | :react,
          current_task: Task.t() | nil,
          cancelled_ref: :atomics.atomics_ref()
        }

  # Client API

  @default_inactivity_timeout :timer.minutes(5)

  @doc """
  Start an AgentServer linked to the calling process.

  ## Options

  - `:session_id` - Unique session identifier (required)
  - `:agent_config` - Agent configuration map (required)
  - `:pubsub` - PubSub module (default: MyApp.PubSub)
  - `:name` - Optional GenServer name (e.g., a Registry via tuple)
  - `:inactivity_timeout` - Inactivity timeout in ms (default: 5 minutes). Set to `:infinity` to disable.
  - `:persistence` - Persistence backend module (e.g., `Nous.Persistence.ETS`). When set, context is auto-saved after each response and restored on init.

  ## Agent Config

  - `:model` - Model string (e.g., "openai:gpt-4")
  - `:instructions` - System instructions
  - `:tools` - List of tool functions
  - `:type` - `:standard` or `:react` (default: :standard)
  - `:model_settings` - Model settings map
  - `:deps` - Initial dependencies for tools

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = split_gen_opts(opts)
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  defp split_gen_opts(opts) do
    case Keyword.pop(opts, :name) do
      {nil, rest} -> {[], rest}
      {name, rest} -> {[name: name], rest}
    end
  end

  @doc """
  Send a message to the agent.

  If a previous execution is still running, it is automatically cancelled
  before the new message is processed. The interrupted message and the new
  one both remain in the conversation context. Returns immediately — the
  agent run happens asynchronously and results are broadcast via PubSub.
  """
  @spec send_message(pid(), String.t()) :: :ok
  def send_message(pid, message) do
    GenServer.cast(pid, {:user_message, message})
  end

  @doc """
  Get conversation context.
  """
  @spec get_context(pid()) :: Context.t()
  def get_context(pid) do
    GenServer.call(pid, :get_context)
  end

  @doc """
  Get conversation history (messages only).
  """
  @spec get_history(pid()) :: list()
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  @doc """
  Clear conversation context and start fresh.

  Resets messages and tool-call history but preserves the configured
  dependencies (`:deps`) and system prompt.
  """
  @spec clear_history(pid()) :: :ok
  def clear_history(pid) do
    GenServer.cast(pid, :clear_history)
  end

  @doc """
  Cancel the current agent execution.

  Returns `{:ok, :cancelled}` when an execution was running and has been
  stopped, or `{:ok, :no_execution}` when there was nothing to cancel.

  The server will:
  - Set the atomics cancellation flag so the task exits at the next check
  - Shut down the running task gracefully (5 s timeout)
  - Broadcast `{:agent_cancelled, reason}` to PubSub subscribers
  - Reset the flag for future executions
  """
  @spec cancel_execution(pid()) :: {:ok, :cancelled} | {:ok, :no_execution}
  def cancel_execution(pid) do
    GenServer.call(pid, :cancel_execution)
  end

  @doc """
  Manually save the current context to the persistence backend.

  Returns `:ok` on success, `{:error, :no_persistence}` if no backend is configured,
  or `{:error, reason}` on failure.
  """
  @spec save_context(pid()) :: :ok | {:error, term()}
  def save_context(pid) do
    GenServer.call(pid, :save_context)
  end

  @doc """
  Load a previously saved context from the persistence backend.

  Replaces the current context with the loaded one. Patches any dangling tool
  calls that may have been interrupted mid-execution.

  Returns `:ok` on success, `{:error, :no_persistence}` if no backend is configured,
  or `{:error, reason}` on failure.
  """
  @spec load_context(pid(), String.t()) :: :ok | {:error, term()}
  def load_context(pid, session_id) do
    GenServer.call(pid, {:load_context, session_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_config = Keyword.fetch!(opts, :agent_config)
    pubsub = Keyword.get(opts, :pubsub) || Nous.PubSub.configured_pubsub()
    inactivity_timeout = Keyword.get(opts, :inactivity_timeout, @default_inactivity_timeout)
    persistence = Keyword.get(opts, :persistence)

    # Subscribe to messages for this session
    topic = "agent:#{session_id}"
    Nous.PubSub.subscribe(pubsub, topic)

    # Create agent based on type
    agent_type = Map.get(agent_config, :type, :standard)

    agent =
      case agent_type do
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

    # Initialize context - try loading from persistence first
    initial_deps = Map.get(agent_config, :deps, %{})

    context =
      case maybe_load_context(persistence, session_id) do
        {:ok, loaded_ctx} ->
          Logger.info("Restored persisted context for session: #{session_id}")
          # Merge initial deps back in (they may contain runtime values like PIDs)
          loaded_ctx
          |> Context.merge_deps(initial_deps)
          |> Context.patch_dangling_tool_calls()
          |> Map.merge(%{pubsub: pubsub, pubsub_topic: topic})

        _ ->
          Context.new(
            deps: initial_deps,
            system_prompt: Map.get(agent_config, :instructions, ""),
            agent_name: "agent_server_#{session_id}",
            pubsub: pubsub,
            pubsub_topic: topic
          )
      end

    Logger.info("AgentServer started for session: #{session_id}")

    # Schedule initial inactivity timer
    inactivity_timer_ref = schedule_inactivity_timeout(inactivity_timeout)

    # Atomics ref for lock-free cancellation checks from the task process
    cancelled_ref = :atomics.new(1, signed: false)

    state = %{
      session_id: session_id,
      agent: agent,
      context: context,
      pubsub: pubsub,
      topic: topic,
      agent_type: agent_type,
      current_task: nil,
      # Monotonic task generation counter. Every spawned task captures the
      # generation it ran under; replies whose generation no longer matches
      # the current one are stale (the user sent a new message, called
      # clear_history, or cancelled) and MUST be discarded - otherwise a
      # task that completed milliseconds before the cancel can clobber the
      # freshly-cleared/updated context. See review finding C-5.
      task_generation: 0,
      cancelled_ref: cancelled_ref,
      inactivity_timeout: inactivity_timeout,
      inactivity_timer_ref: inactivity_timer_ref,
      persistence: persistence
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:user_message, message}, state) do
    # Bumping the generation FIRST means any reply that was already in our
    # mailbox (sent by the just-finishing previous task) is immediately
    # stale and will be filtered by handle_info before it can clobber state.
    state = bump_generation(state)

    # Gracefully shutdown any existing task if running
    state =
      if state.current_task do
        Logger.warning("Cancelling existing task for new message in session: #{state.session_id}")

        # Set cancelled flag to signal the task to stop
        :atomics.put(state.cancelled_ref, 1, 1)

        # Attempt graceful shutdown first
        case Task.shutdown(state.current_task, 2_000) do
          {:ok, _result} ->
            Logger.debug("Previous task completed during shutdown")

          nil ->
            Logger.debug("Previous task already exited")

          {:exit, _reason} ->
            Logger.debug("Previous task exited during shutdown")
        end

        %{state | current_task: nil}
      else
        state
      end

    # Broadcast that we're processing
    broadcast(state, {:agent_status, :thinking})

    # Add user message to context
    context = Context.add_message(state.context, Message.user(message))

    # Reset cancelled flag for new execution and reset inactivity timer
    :atomics.put(state.cancelled_ref, 1, 0)
    state = %{state | context: context}
    state = reset_inactivity_timer(state)

    # Run agent asynchronously and track the task
    server_pid = self()
    cancelled_ref = state.cancelled_ref
    generation = state.task_generation

    task =
      Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
        run_agent_and_respond(server_pid, state, message, cancelled_ref, generation)
      end)

    {:noreply, %{state | current_task: task}}
  end

  @impl true
  def handle_cast(:clear_history, state) do
    Logger.info("Clearing conversation context for session: #{state.session_id}")

    # Bump the generation and signal cancellation BEFORE clearing - otherwise
    # an in-flight task can deliver {:agent_response_ready, ...} after this
    # handler runs and silently re-populate the context we just cleared.
    state = bump_generation(state)
    :atomics.put(state.cancelled_ref, 1, 1)

    state =
      if state.current_task do
        case Task.shutdown(state.current_task, 2_000) do
          _ -> :ok
        end

        %{state | current_task: nil}
      else
        state
      end

    :atomics.put(state.cancelled_ref, 1, 0)

    # Create fresh context preserving deps and system prompt
    new_context =
      Context.new(
        deps: state.context.deps,
        system_prompt: state.context.system_prompt,
        agent_name: state.context.agent_name
      )

    state = %{state | context: new_context}

    # Sync with persistence so stale context isn't restored on restart
    do_save_context(state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_context, _from, state) do
    {:reply, state.context, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    # Return messages from context
    {:reply, state.context.messages, state}
  end

  @impl true
  def handle_call(:cancel_execution, _from, state) do
    case state.current_task do
      nil ->
        Logger.info("No execution to cancel for session: #{state.session_id}")
        {:reply, {:ok, :no_execution}, state}

      task ->
        Logger.info("Cancelling execution for session: #{state.session_id}")

        # Bump generation FIRST so a reply that arrives between :atomics.put
        # and Task.shutdown is filtered as stale rather than overwriting state.
        state = bump_generation(state)

        # Set cancelled flag - the runner will check this via atomics
        :atomics.put(state.cancelled_ref, 1, 1)

        # Shutdown task gracefully with timeout
        shutdown_result = Task.shutdown(task, 5_000)

        case shutdown_result do
          {:ok, _result} ->
            Logger.debug("Task completed before shutdown")

          nil ->
            Logger.debug("Task already exited")

          {:exit, reason} ->
            Logger.debug("Task exited with reason: #{inspect(reason)}")
        end

        # Broadcast cancellation
        broadcast(state, {:agent_cancelled, "Execution cancelled by user"})

        # Clear current task and reset cancelled flag
        state = %{state | current_task: nil}
        :atomics.put(state.cancelled_ref, 1, 0)

        {:reply, {:ok, :cancelled}, state}
    end
  end

  @impl true
  def handle_call(:save_context, _from, state) do
    result = do_save_context(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:load_context, session_id}, _from, state) do
    case state.persistence do
      nil ->
        {:reply, {:error, :no_persistence}, state}

      backend ->
        case backend.load(session_id) do
          {:ok, data} ->
            case Context.deserialize(data) do
              {:ok, ctx} ->
                ctx =
                  ctx
                  |> Context.merge_deps(state.context.deps)
                  |> Context.patch_dangling_tool_calls()

                {:reply, :ok, %{state | context: ctx}}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({:user_message, message}, state) do
    # Handle messages from PubSub
    handle_cast({:user_message, message}, state)
  end

  # Handle events from agent runner via notify_pid
  @impl true
  def handle_info({:agent_delta, text}, state) do
    # Forward streaming delta to PubSub subscribers
    broadcast(state, {:agent_delta, text})
    {:noreply, state}
  end

  @impl true
  def handle_info({:tool_call, call}, state) do
    # Forward tool call to PubSub subscribers
    broadcast(state, {:tool_call, call})
    {:noreply, state}
  end

  @impl true
  def handle_info({:tool_result, result}, state) do
    # Forward tool result to PubSub subscribers
    broadcast(state, {:tool_result, result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_complete, result}, state) do
    # Forward completion to PubSub subscribers
    broadcast(state, {:agent_complete, result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_error, error}, state) do
    # Forward error to PubSub subscribers
    broadcast(state, {:agent_error, error})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_start, _payload}, state) do
    # Forward start event
    broadcast(state, {:agent_status, :started})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_message, _message}, state) do
    # LLM message received - could broadcast if needed
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response_ready, generation, context, _result}, state) do
    if generation == state.task_generation do
      state = %{state | context: context}
      do_save_context(state)
      {:noreply, state}
    else
      # Stale reply from a previous task that completed milliseconds before
      # the user sent a new message / called clear_history / cancelled.
      # Discard - the current state already reflects the newer truth.
      Logger.debug(
        "Discarding stale :agent_response_ready (gen #{generation}, current #{state.task_generation})"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:agent_task_completed, generation, _reason}, state) do
    if generation == state.task_generation do
      {:noreply, %{state | current_task: nil}}
    else
      # Stale completion from a previous task; current_task already points
      # to a newer task, do not clear it.
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{current_task: %Task{ref: ref}} = state
      ) do
    # Our current task's monitor fired; clear the task slot.
    {:noreply, %{state | current_task: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Some other monitor fired (Phoenix.PubSub, future plugin monitor, or a
    # stale ref from a previous task). Don't clear current_task - that would
    # drop our newer task's bookkeeping.
    {:noreply, state}
  end

  @impl true
  def handle_info(:inactivity_timeout, state) do
    Logger.info("AgentServer terminating due to inactivity for session: #{state.session_id}")
    {:stop, :normal, state}
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

  defp schedule_inactivity_timeout(:infinity), do: nil

  defp schedule_inactivity_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    Process.send_after(self(), :inactivity_timeout, timeout)
  end

  defp reset_inactivity_timer(state) do
    # Cancel existing timer if any
    if state.inactivity_timer_ref do
      Process.cancel_timer(state.inactivity_timer_ref)
    end

    # Schedule a new timer
    new_ref = schedule_inactivity_timeout(state.inactivity_timeout)
    %{state | inactivity_timer_ref: new_ref}
  end

  defp do_save_context(%{persistence: nil}), do: {:error, :no_persistence}

  defp do_save_context(%{persistence: backend, session_id: session_id, context: context}) do
    data = Context.serialize(context)

    case backend.save(session_id, data) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error("Failed to save context for session #{session_id}: #{inspect(reason)}")
        err
    end
  end

  defp maybe_load_context(nil, _session_id), do: :skip

  defp maybe_load_context(backend, session_id) do
    case backend.load(session_id) do
      {:ok, data} ->
        Context.deserialize(data)

      {:error, :not_found} ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "Failed to load persisted context for session #{session_id}: #{inspect(reason)}"
        )

        :skip
    end
  end

  defp run_agent_and_respond(server_pid, state, message, cancelled_ref, generation) do
    # Check if cancelled before starting
    if :atomics.get(cancelled_ref, 1) == 1 do
      Logger.info("Execution cancelled before agent run for session: #{state.session_id}")
      broadcast(state, {:agent_cancelled, "Execution cancelled"})
      :cancelled
    else
      do_agent_run(server_pid, state, message, cancelled_ref, generation)
    end
  end

  defp do_agent_run(server_pid, state, message, cancelled_ref, generation) do
    # Run agent with context continuation and notify_pid for events
    result =
      Nous.AgentRunner.run(state.agent, message,
        context: state.context,
        notify_pid: server_pid,
        max_iterations: 15,
        cancellation_check: fn ->
          if :atomics.get(cancelled_ref, 1) == 1 do
            throw({:cancelled, "Execution cancelled"})
          end
        end
      )

    case result do
      {:ok, response} ->
        # Broadcast response
        broadcast(state, {:agent_response, response.output})
        broadcast(state, {:agent_complete, response})

        # Send context update to server, tagged with our generation so it
        # can be discarded if the user has already sent a newer message.
        send(server_pid, {:agent_response_ready, generation, response.context, response})

      {:error, %Nous.Errors.ExecutionCancelled{}} ->
        Logger.info("Agent execution was cancelled for session: #{state.session_id}")
        broadcast(state, {:agent_cancelled, "Execution cancelled"})
        send(server_pid, {:agent_task_completed, generation, :cancelled})

      {:error, error} ->
        error_msg = if is_exception(error), do: Exception.message(error), else: inspect(error)
        Logger.error("Agent error in session #{state.session_id}: #{error_msg}")

        # Broadcast error
        broadcast(state, {:agent_error, error_msg})
        send(server_pid, {:agent_task_completed, generation, :error})
    end
  end

  defp broadcast(state, message) do
    Nous.PubSub.broadcast(state.pubsub, state.topic, message)
  end

  defp bump_generation(state) do
    %{state | task_generation: state.task_generation + 1}
  end
end

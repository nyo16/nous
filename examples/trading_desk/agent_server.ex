defmodule TradingDesk.AgentServer do
  @moduledoc """
  GenServer wrapper for individual trading desk agents.

  Each specialist agent runs in its own process with:
  - Named process (via Registry)
  - Conversation history
  - Async task execution
  """

  use GenServer
  require Logger

  alias Yggdrasil.Agent

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(agent_spec) do
    name = {:via, Registry, {TradingDesk.Registry, agent_spec.id}}
    GenServer.start_link(__MODULE__, agent_spec, name: name)
  end

  @doc "Send a query to an agent"
  def query(agent_id, message, opts \\ []) do
    via_name = {:via, Registry, {TradingDesk.Registry, agent_id}}
    GenServer.call(via_name, {:query, message, opts}, 60_000)
  end

  @doc "Get agent info"
  def info(agent_id) do
    via_name = {:via, Registry, {TradingDesk.Registry, agent_id}}
    GenServer.call(via_name, :info)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(agent_spec) do
    # Create the Yggdrasil agent from spec
    agent =
      Agent.new(agent_spec.model,
        instructions: agent_spec.instructions,
        tools: agent_spec.tools,
        model_settings: %{
          temperature: 0.7,
          max_tokens: 1500
        }
      )

    state = %{
      id: agent_spec.id,
      name: agent_spec.name,
      description: agent_spec.description,
      agent: agent,
      conversation_history: [],
      running_task: nil,
      created_at: DateTime.utc_now()
    }

    Logger.info("[TradingDesk] Started agent: #{agent_spec.name} (#{agent_spec.id})")

    {:ok, state}
  end

  @impl true
  def handle_call({:query, message, opts}, from, state) do
    # Cancel any running task
    if state.running_task && Process.alive?(state.running_task.pid) do
      Task.shutdown(state.running_task, :brutal_kill)
    end

    # Spawn async task to run agent
    task =
      Task.async(fn ->
        Logger.debug("[#{state.id}] Processing query: #{String.slice(message, 0..50)}...")

        result =
          Agent.run(state.agent, message,
            message_history: state.conversation_history,
            deps: Keyword.get(opts, :deps)
          )

        Logger.debug("[#{state.id}] Query complete")
        result
      end)

    # Store task and pending caller
    new_state =
      state
      |> Map.put(:running_task, task)
      |> Map.put(:pending_from, from)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      id: state.id,
      name: state.name,
      description: state.description,
      model: state.agent.model.model,
      provider: state.agent.model.provider,
      messages_in_history: length(state.conversation_history),
      tools_count: length(state.agent.tools),
      created_at: state.created_at,
      is_busy: state.running_task != nil
    }

    {:reply, info, state}
  end

  # Handle task completion
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if state.running_task && state.running_task.ref == ref do
      if pending_from = Map.get(state, :pending_from) do
        case result do
          {:ok, agent_result} ->
            # Update conversation history
            new_history = state.conversation_history ++ agent_result.new_messages

            GenServer.reply(pending_from, {:ok, agent_result})

            new_state =
              state
              |> Map.put(:conversation_history, new_history)
              |> Map.put(:running_task, nil)
              |> Map.delete(:pending_from)

            {:noreply, new_state}

          error ->
            GenServer.reply(pending_from, error)

            new_state =
              state
              |> Map.put(:running_task, nil)
              |> Map.delete(:pending_from)

            {:noreply, new_state}
        end
      else
        {:noreply, %{state | running_task: nil}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("[#{state.id}] Task failed: #{inspect(reason)}")

    if pending_from = Map.get(state, :pending_from) do
      GenServer.reply(pending_from, {:error, {:task_failed, reason}})
    end

    new_state =
      state
      |> Map.put(:running_task, nil)
      |> Map.delete(:pending_from)

    {:noreply, new_state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[TradingDesk] Agent #{state.name} terminating: #{inspect(reason)}")

    if state.running_task && Process.alive?(state.running_task.pid) do
      Task.shutdown(state.running_task, :brutal_kill)
    end

    :ok
  end
end

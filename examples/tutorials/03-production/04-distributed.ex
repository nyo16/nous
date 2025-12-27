defmodule MyApp.DistributedAgent do
  @moduledoc """
  Distributed AI Agent with Registry support for clustered applications.

  This shows how to:
  - Create named agent processes
  - Use Registry for process discovery
  - Support distributed Elixir clusters
  - Enable process monitoring
  - Graceful cleanup
  """

  use GenServer
  require Logger

  alias Nous.Agent

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start a named agent process.

  ## Options
    - `:name` - Unique agent name (required)
    - `:model` - Model string (default: anthropic)
    - `:instructions` - Agent instructions
    - `:tools` - List of tools
    - `:owner_pid` - PID to link to (e.g., LiveView PID)

  ## Examples

      # Start agent for a user
      {:ok, pid} = DistributedAgent.start_agent(
        name: "user:123:chat",
        model: "anthropic:claude-sonnet-4-5-20250929",
        owner_pid: self()
      )

      # Or with via tuple for distribution
      {:ok, pid} = DistributedAgent.start_agent(
        name: {:via, Registry, {MyApp.AgentRegistry, "user:123"}}
      )

  """
  def start_agent(opts) do
    name = Keyword.fetch!(opts, :name)

    # Convert name to via tuple if it's a string
    via_name =
      case name do
        {:via, _, _} = via -> via
        name when is_binary(name) -> {:via, Registry, {MyApp.AgentRegistry, name}}
        name when is_atom(name) -> {:via, Registry, {MyApp.AgentRegistry, name}}
      end

    GenServer.start_link(__MODULE__, opts, name: via_name)
  end

  @doc """
  Send a message to a named agent.

  ## Examples

      # By string name
      {:ok, result} = DistributedAgent.chat("user:123:chat", "Hello!")

      # By via tuple
      {:ok, result} = DistributedAgent.chat(
        {:via, Registry, {MyApp.AgentRegistry, "user:123"}},
        "Hello!"
      )

  """
  def chat(agent_name, message, opts \\ []) do
    via_name = normalize_name(agent_name)
    GenServer.call(via_name, {:chat, message, opts}, 60_000)
  end

  @doc "Stream a message to a named agent"
  def chat_stream(agent_name, message, callback, opts \\ []) do
    via_name = normalize_name(agent_name)
    GenServer.call(via_name, {:chat_stream, message, callback, opts}, 120_000)
  end

  @doc "Get agent info"
  def get_info(agent_name) do
    via_name = normalize_name(agent_name)
    GenServer.call(via_name, :get_info)
  end

  @doc "Stop a named agent"
  def stop_agent(agent_name) do
    via_name = normalize_name(agent_name)
    GenServer.stop(via_name, :normal)
  end

  @doc "Find agent PID by name"
  def whereis(agent_name) do
    case agent_name do
      {:via, Registry, {registry, key}} ->
        case Registry.lookup(registry, key) do
          [{pid, _}] -> {:ok, pid}
          [] -> {:error, :not_found}
        end

      name when is_binary(name) ->
        case Registry.lookup(MyApp.AgentRegistry, name) do
          [{pid, _}] -> {:ok, pid}
          [] -> {:error, :not_found}
        end
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl true
  def init(opts) do
    # Link to owner if provided
    if owner_pid = Keyword.get(opts, :owner_pid) do
      Process.link(owner_pid)
      Logger.info("Agent linked to owner: #{inspect(owner_pid)}")
    end

    # Create the agent
    model = Keyword.get(opts, :model, "anthropic:claude-sonnet-4-5-20250929")
    instructions = Keyword.get(opts, :instructions, "You are a helpful assistant")
    tools = Keyword.get(opts, :tools, [])

    agent_config =
      Agent.new(model,
        instructions: instructions,
        tools: tools,
        model_settings: Keyword.get(opts, :model_settings, %{})
      )

    state = %{
      agent: agent_config,
      conversation_history: [],
      running_task: nil,
      name: Keyword.get(opts, :name),
      created_at: DateTime.utc_now()
    }

    Logger.info("DistributedAgent started: #{inspect(state.name)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:chat, message, opts}, from, state) do
    # Cancel any running task
    if state.running_task && Process.alive?(state.running_task.pid) do
      Task.shutdown(state.running_task, :brutal_kill)
    end

    # Spawn task to run agent
    task =
      Task.async(fn ->
        Agent.run(state.agent, message,
          message_history: state.conversation_history,
          deps: Keyword.get(opts, :deps)
        )
      end)

    # Store task and reply asynchronously
    new_state = %{state | running_task: task}

    # We'll reply when task completes (see handle_info)
    {:noreply, Map.put(new_state, :pending_from, from)}
  end

  @impl true
  def handle_call({:chat_stream, message, callback, opts}, from, state) do
    # Spawn streaming task
    task =
      Task.async(fn ->
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

    new_state = %{state | running_task: task}
    {:noreply, Map.put(new_state, :pending_from, from)}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      name: state.name,
      model: state.agent.model.model,
      provider: state.agent.model.provider,
      messages: length(state.conversation_history),
      created_at: state.created_at,
      running: state.running_task != nil
    }

    {:reply, info, state}
  end

  # Handle task completion
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if state.running_task && state.running_task.ref == ref do
      # Reply to pending caller
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
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.warning("Agent task crashed: #{inspect(reason)}")

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
    Logger.info("DistributedAgent #{inspect(state.name)} terminating: #{inspect(reason)}")

    # Kill running task if any
    if state.running_task && Process.alive?(state.running_task.pid) do
      Task.shutdown(state.running_task, :brutal_kill)
    end

    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp normalize_name({:via, _, _} = via), do: via

  defp normalize_name(name) when is_binary(name) or is_atom(name) do
    {:via, Registry, {MyApp.AgentRegistry, name}}
  end
end

# ============================================================================
# Application Setup
# ============================================================================

defmodule MyApp.Application do
  @moduledoc """
  Example application supervisor setup for distributed agents.
  """

  use Application

  def start(_type, _args) do
    children = [
      # Registry for agent process names
      {Registry, keys: :unique, name: MyApp.AgentRegistry},

      # Task supervisor for agent tasks
      {Task.Supervisor, name: MyApp.TaskSupervisor},

      # Dynamic supervisor for spawning agents on demand
      {DynamicSupervisor, name: MyApp.AgentSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

# ============================================================================
# LiveView Integration
# ============================================================================

defmodule MyAppWeb.DistributedChatLive do
  @moduledoc """
  LiveView using distributed named agents.
  """

  use Phoenix.LiveView
  alias MyApp.DistributedAgent

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    # Create unique agent name for this user
    agent_name = "chat:user:#{user_id}"

    # Start agent linked to LiveView
    {:ok, agent_pid} =
      DistributedAgent.start_agent(
        name: agent_name,
        model: "anthropic:claude-sonnet-4-5-20250929",
        owner_pid: self(),
        instructions: "You are a helpful assistant"
      )

    # Monitor the agent
    Process.monitor(agent_pid)

    socket =
      socket
      |> assign(:agent_name, agent_name)
      |> assign(:agent_pid, agent_pid)
      |> assign(:messages, [])
      |> assign(:user_id, user_id)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"text" => text}, socket) do
    # Send to named agent (can be on any node in cluster!)
    Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
      case DistributedAgent.chat(socket.assigns.agent_name, text) do
        {:ok, result} ->
          send(self(), {:agent_response, result.output})

        {:error, error} ->
          send(self(), {:agent_error, error})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_response, response}, socket) do
    messages = socket.assigns.messages ++ [{:assistant, response}]
    {:noreply, assign(socket, :messages, messages)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    Logger.warning("Agent process died: #{inspect(reason)}")
    # Could restart agent here if needed
    {:noreply, put_flash(socket, :error, "Agent disconnected")}
  end

  @impl true
  def terminate(_reason, socket) do
    # Agent will die automatically because it's linked
    # But we can also explicitly stop it
    if socket.assigns[:agent_name] do
      DistributedAgent.stop_agent(socket.assigns.agent_name)
    end

    :ok
  end
end

# ============================================================================
# Usage Examples
# ============================================================================

defmodule Examples do
  alias MyApp.DistributedAgent

  @doc "Example 1: Simple named agent"
  def example_named_agent do
    # Start agent with simple name
    {:ok, _pid} = DistributedAgent.start_agent(name: "my-agent")

    # Chat with it
    {:ok, result} = DistributedAgent.chat("my-agent", "Hello!")
    IO.puts(result.output)

    # Stop it
    DistributedAgent.stop_agent("my-agent")
  end

  @doc "Example 2: User-specific agents"
  def example_user_agent(user_id) do
    # Each user gets their own agent
    agent_name = "chat:user:#{user_id}"

    {:ok, _pid} =
      DistributedAgent.start_agent(
        name: agent_name,
        model: "anthropic:claude-sonnet-4-5-20250929"
      )

    # Chat maintains conversation per user
    {:ok, r1} = DistributedAgent.chat(agent_name, "My name is Alice")
    {:ok, r2} = DistributedAgent.chat(agent_name, "What's my name?")
    # => "Your name is Alice"

    DistributedAgent.stop_agent(agent_name)
  end

  @doc "Example 3: Find agent across cluster"
  def example_cluster_agent do
    agent_name = "global-agent"

    # Start on any node
    {:ok, pid} = DistributedAgent.start_agent(name: agent_name)

    # Find it (works across cluster)
    {:ok, ^pid} = DistributedAgent.whereis(agent_name)

    # Chat with it from any node
    {:ok, result} = DistributedAgent.chat(agent_name, "Hello from node!")
    IO.puts("Response: #{result.output}")
  end

  @doc "Example 4: LiveView with linked agent"
  def example_liveview_linked do
    # In LiveView mount:
    liveview_pid = self()

    # Start agent linked to LiveView
    {:ok, agent_pid} =
      DistributedAgent.start_agent(
        name: "chat:session:#{make_ref()}",
        owner_pid: liveview_pid
      )

    # When LiveView dies → agent dies automatically due to link
    # No orphaned processes!

    agent_pid
  end
end

# ============================================================================
# Registry Helpers
# ============================================================================

defmodule MyApp.AgentRegistry.Helpers do
  @moduledoc "Helper functions for agent registry"

  @doc "List all running agents"
  def list_agents do
    Registry.select(MyApp.AgentRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "Count running agents"
  def count_agents do
    Registry.count(MyApp.AgentRegistry)
  end

  @doc "Stop all agents matching pattern"
  def stop_agents_matching(pattern) do
    MyApp.AgentRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {name, _pid} ->
      case name do
        name when is_binary(name) -> String.contains?(name, pattern)
        _ -> false
      end
    end)
    |> Enum.each(fn {name, pid} ->
      Process.exit(pid, :shutdown)
    end)
  end

  @doc "Get agent info by pattern"
  def find_agents(pattern) do
    MyApp.AgentRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {name, _pid} ->
      case name do
        name when is_binary(name) -> String.contains?(name, pattern)
        _ -> false
      end
    end)
    |> Enum.map(fn {name, pid} ->
      info = GenServer.call(pid, :get_info)
      {name, pid, info}
    end)
  end
end

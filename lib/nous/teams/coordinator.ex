defmodule Nous.Teams.Coordinator do
  @moduledoc """
  Team lifecycle GenServer that manages agent processes within a team.

  The Coordinator is responsible for spawning, stopping, and monitoring agent
  processes. It registers agents in the `Nous.AgentRegistry` with team-scoped
  keys and sets up PubSub subscriptions.

  ## Architecture

  Each team has exactly one Coordinator, started as part of `Nous.Teams.Supervisor`.
  The Coordinator uses the team's DynamicSupervisor to start `AgentServer` processes.

      Teams.Supervisor
      ├── Coordinator (this module)
      ├── SharedState
      ├── RateLimiter (optional)
      └── DynamicSupervisor (for agents)
          ├── AgentServer ("alice")
          └── AgentServer ("bob")

  ## Quick Start

      {:ok, pid} = Coordinator.start_link(
        team_id: "team_1",
        team_name: "Research Team",
        pubsub: MyApp.PubSub,
        agent_supervisor: agent_sup_pid,
        shared_state: shared_state_pid
      )

      {:ok, agent_pid} = Coordinator.spawn_agent(pid, "alice", %{
        model: "openai:gpt-4",
        instructions: "You are a researcher"
      })

      agents = Coordinator.list_agents(pid)
      Coordinator.stop_agent(pid, "alice")
      Coordinator.dissolve(pid)
  """

  use GenServer
  require Logger

  alias Nous.Teams.Comms

  @type agent_info :: %{
          name: String.t(),
          pid: pid(),
          status: :running | :stopped
        }

  # Client API

  @doc """
  Start a Coordinator for a team.

  ## Options

  - `:team_id` (required) — unique identifier for the team
  - `:team_name` — human-readable team name (default: team_id)
  - `:pubsub` — PubSub module for messaging
  - `:agent_supervisor` — pid of the team's DynamicSupervisor for agents
  - `:shared_state` — pid of the team's SharedState process
  - `:rate_limiter` — pid of the team's RateLimiter process (optional)
  - `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = split_gen_opts(opts)
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Spawn a new agent within the team.

  The agent is started under the team's DynamicSupervisor, registered in
  `Nous.AgentRegistry` with a `{:team, team_id, name}` key, and subscribed
  to team PubSub topics.

  ## Options

  - `:role` — a `Nous.Teams.Role` struct to apply
  - `:plugins` — list of plugin modules for the agent

  ## Examples

      {:ok, pid} = Coordinator.spawn_agent(coordinator, "alice", %{
        model: "openai:gpt-4",
        instructions: "Research specialist"
      })
  """
  @spec spawn_agent(pid(), String.t(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent(pid, agent_name, agent_config, opts \\ []) do
    GenServer.call(pid, {:spawn_agent, agent_name, agent_config, opts})
  end

  @doc """
  Stop an agent by name.

  ## Examples

      :ok = Coordinator.stop_agent(coordinator, "alice")
  """
  @spec stop_agent(pid(), String.t()) :: :ok | {:error, :not_found}
  def stop_agent(pid, agent_name) do
    GenServer.call(pid, {:stop_agent, agent_name})
  end

  @doc """
  List all agents in the team.

  Returns a list of maps with `:name`, `:pid`, and `:status` keys.

  ## Examples

      agents = Coordinator.list_agents(coordinator)
      # [%{name: "alice", pid: #PID<0.123.0>, status: :running}]
  """
  @spec list_agents(pid()) :: [agent_info()]
  def list_agents(pid) do
    GenServer.call(pid, :list_agents)
  end

  @doc """
  Get the team's current status.

  Returns a map with `:team_id`, `:team_name`, `:agent_count`, and `:agents` keys.

  ## Examples

      status = Coordinator.team_status(coordinator)
      # %{team_id: "team_1", team_name: "Research", agent_count: 2, agents: [...]}
  """
  @spec team_status(pid()) :: map()
  def team_status(pid) do
    GenServer.call(pid, :team_status)
  end

  @doc """
  Dissolve the team by stopping all agents and cleaning up.

  ## Examples

      :ok = Coordinator.dissolve(coordinator)
  """
  @spec dissolve(pid()) :: :ok
  def dissolve(pid) do
    GenServer.call(pid, :dissolve)
  end

  # Server

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    team_name = Keyword.get(opts, :team_name, team_id)
    pubsub = Keyword.get(opts, :pubsub)
    agent_supervisor = Keyword.get(opts, :agent_supervisor)
    shared_state = Keyword.get(opts, :shared_state)
    rate_limiter = Keyword.get(opts, :rate_limiter)

    Logger.info("Team Coordinator started for team: #{team_name} (#{team_id})")

    state = %{
      team_id: team_id,
      team_name: team_name,
      pubsub: pubsub,
      agent_supervisor: agent_supervisor,
      shared_state: shared_state,
      rate_limiter: rate_limiter,
      agents: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:spawn_agent, agent_name, agent_config, opts}, _from, state) do
    if Map.has_key?(state.agents, agent_name) do
      {:reply, {:error, :already_exists}, state}
    else
      session_id = "team:#{state.team_id}:#{agent_name}"
      registry_key = {:team, state.team_id, agent_name}

      # Build deps with team context
      base_deps = Map.get(agent_config, :deps, %{})

      team_deps =
        Map.merge(base_deps, %{
          team_id: state.team_id,
          team_name: state.team_name,
          team_role: Keyword.get(opts, :role),
          shared_state_pid: state.shared_state,
          rate_limiter_pid: state.rate_limiter,
          team_coordinator_pid: self(),
          agent_name: agent_name
        })

      enriched_config = Map.put(agent_config, :deps, team_deps)

      child_spec =
        {Nous.AgentServer,
         session_id: session_id,
         agent_config: enriched_config,
         pubsub: state.pubsub,
         name: Nous.AgentRegistry.via_tuple(registry_key),
         inactivity_timeout: :infinity}

      case DynamicSupervisor.start_child(state.agent_supervisor, child_spec) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          agents = Map.put(state.agents, agent_name, %{pid: pid, status: :running})
          monitors = Map.put(state.monitors, ref, agent_name)

          Logger.info("Spawned agent '#{agent_name}' in team '#{state.team_name}'")

          Comms.broadcast_team(state.pubsub, state.team_id, {:agent_joined, agent_name})

          {:reply, {:ok, pid}, %{state | agents: agents, monitors: monitors}}

        {:error, reason} = error ->
          Logger.error(
            "Failed to spawn agent '#{agent_name}' in team '#{state.team_name}': #{inspect(reason)}"
          )

          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:stop_agent, agent_name}, _from, state) do
    case Map.get(state.agents, agent_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid} ->
        DynamicSupervisor.terminate_child(state.agent_supervisor, pid)

        {state, _} = remove_agent(state, agent_name)

        Comms.broadcast_team(state.pubsub, state.team_id, {:agent_left, agent_name})
        Logger.info("Stopped agent '#{agent_name}' in team '#{state.team_name}'")

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    agents =
      Enum.map(state.agents, fn {name, info} ->
        %{name: name, pid: info.pid, status: info.status}
      end)

    {:reply, agents, state}
  end

  @impl true
  def handle_call(:team_status, _from, state) do
    agents =
      Enum.map(state.agents, fn {name, info} ->
        %{name: name, pid: info.pid, status: info.status}
      end)

    status = %{
      team_id: state.team_id,
      team_name: state.team_name,
      agent_count: map_size(state.agents),
      agents: agents
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:dissolve, _from, state) do
    Logger.info("Dissolving team '#{state.team_name}' (#{state.team_id})")

    # Stop all agents
    for {_name, %{pid: pid}} <- state.agents do
      DynamicSupervisor.terminate_child(state.agent_supervisor, pid)
    end

    # Demonitor all
    for {ref, _name} <- state.monitors do
      Process.demonitor(ref, [:flush])
    end

    Comms.broadcast_team(state.pubsub, state.team_id, {:team_dissolved, state.team_id})

    {:reply, :ok, %{state | agents: %{}, monitors: %{}}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      agent_name ->
        Logger.warning(
          "Agent '#{agent_name}' in team '#{state.team_name}' went down: #{inspect(reason)}"
        )

        Comms.broadcast_team(
          state.pubsub,
          state.team_id,
          {:agent_crashed, agent_name, reason}
        )

        {state, _} = remove_agent(state, agent_name)
        state = %{state | monitors: Map.delete(state.monitors, ref)}

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp split_gen_opts(opts) do
    case Keyword.pop(opts, :name) do
      {nil, rest} -> {[], rest}
      {name, rest} -> {[name: name], rest}
    end
  end

  defp remove_agent(state, agent_name) do
    {removed, agents} = Map.pop(state.agents, agent_name)

    # Remove monitor by finding the ref for this agent
    monitors =
      state.monitors
      |> Enum.reject(fn {_ref, name} -> name == agent_name end)
      |> Map.new()

    {%{state | agents: agents, monitors: monitors}, removed}
  end
end

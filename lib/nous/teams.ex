defmodule Nous.Teams do
  @moduledoc """
  Top-level API for multi-agent team orchestration.

  Provides functions to create teams, spawn agents within teams, communicate
  between agents, and dissolve teams. Each team gets its own supervision tree
  with a Coordinator, SharedState, optional RateLimiter, and a DynamicSupervisor
  for agent processes.

  ## Architecture

      Nous.AgentDynamicSupervisor
      └── Nous.Teams.Supervisor (per team)
          ├── Nous.Teams.Coordinator
          ├── Nous.Teams.SharedState
          ├── Nous.Teams.RateLimiter (optional)
          └── DynamicSupervisor (agents)

  ## Quick Start

      # Create a team
      {:ok, team_id} = Nous.Teams.create(name: "Research Team", pubsub: MyApp.PubSub)

      # Spawn agents
      {:ok, _pid} = Nous.Teams.spawn_agent(team_id, "alice", %{
        model: "openai:gpt-4",
        instructions: "Research specialist"
      }, role: Nous.Teams.Role.researcher())

      {:ok, _pid} = Nous.Teams.spawn_agent(team_id, "bob", %{
        model: "openai:gpt-4",
        instructions: "Code specialist"
      }, role: Nous.Teams.Role.coder())

      # Check status
      Nous.Teams.team_status(team_id)

      # Communicate
      Nous.Teams.send_message(team_id, "alice", {:user_message, "Start researching"})

      # Dissolve when done
      Nous.Teams.dissolve(team_id)
  """

  require Logger

  alias Nous.Teams.{Coordinator, Comms}

  # Team lifecycle

  @doc """
  Create a new team.

  Starts a `Nous.Teams.Supervisor` under `Nous.AgentDynamicSupervisor` with
  the given options. Returns `{:ok, team_id}`.

  ## Options

  - `:name` — human-readable team name (default: auto-generated)
  - `:team_id` — explicit team ID (default: auto-generated)
  - `:pubsub` — PubSub module (default: configured PubSub)
  - `:budget` — team budget in USD (enables RateLimiter)
  - `:per_agent_budget` — per-agent budget in USD
  - `:rpm` — requests per minute limit
  - `:tpm` — tokens per minute limit

  ## Examples

      {:ok, team_id} = Nous.Teams.create(name: "Research Team")
      {:ok, team_id} = Nous.Teams.create(name: "Budget Team", budget: 10.0)
  """
  @spec create(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(opts \\ []) do
    team_id = Keyword.get(opts, :team_id, generate_team_id())
    team_name = Keyword.get(opts, :name, team_id)

    supervisor_opts =
      Keyword.merge(opts,
        team_id: team_id,
        team_name: team_name,
        name: team_supervisor_name(team_id)
      )

    # Remove our own keys that aren't valid for the supervisor
    supervisor_opts = Keyword.drop(supervisor_opts, [:name_prefix])

    child_spec = {Nous.Teams.Supervisor, supervisor_opts}

    case DynamicSupervisor.start_child(Nous.AgentDynamicSupervisor, child_spec) do
      {:ok, _pid} ->
        Logger.info("Created team '#{team_name}' (#{team_id})")
        {:ok, team_id}

      {:error, reason} = error ->
        Logger.error("Failed to create team '#{team_name}': #{inspect(reason)}")
        error
    end
  end

  @doc """
  Spawn an agent within an existing team.

  ## Options

  - `:role` — a `Nous.Teams.Role` struct to apply
  - `:plugins` — list of plugin modules

  ## Examples

      {:ok, pid} = Nous.Teams.spawn_agent(team_id, "alice", %{
        model: "openai:gpt-4",
        instructions: "Research specialist"
      })
  """
  @spec spawn_agent(String.t(), String.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_agent(team_id, agent_name, agent_config, opts \\ []) do
    case find_coordinator(team_id) do
      {:ok, pid} -> Coordinator.spawn_agent(pid, agent_name, agent_config, opts)
      error -> error
    end
  end

  @doc """
  Dissolve a team, stopping all agents and cleaning up.

  ## Examples

      :ok = Nous.Teams.dissolve(team_id)
  """
  @spec dissolve(String.t()) :: :ok | {:error, term()}
  def dissolve(team_id) do
    case find_coordinator(team_id) do
      {:ok, pid} ->
        Coordinator.dissolve(pid)

        # Stop the team supervisor
        sup_name = team_supervisor_name(team_id)

        case Process.whereis(sup_name) do
          nil -> :ok
          sup_pid -> DynamicSupervisor.terminate_child(Nous.AgentDynamicSupervisor, sup_pid)
        end

      error ->
        error
    end
  end

  # Queries

  @doc """
  List all agents in a team.

  ## Examples

      agents = Nous.Teams.list_agents(team_id)
      # [%{name: "alice", pid: #PID<0.123.0>, status: :running}]
  """
  @spec list_agents(String.t()) :: [map()] | {:error, term()}
  def list_agents(team_id) do
    case find_coordinator(team_id) do
      {:ok, pid} -> Coordinator.list_agents(pid)
      error -> error
    end
  end

  @doc """
  Get the current status of a team.

  ## Examples

      status = Nous.Teams.team_status(team_id)
      # %{team_id: "...", team_name: "...", agent_count: 2, agents: [...]}
  """
  @spec team_status(String.t()) :: map() | {:error, term()}
  def team_status(team_id) do
    case find_coordinator(team_id) do
      {:ok, pid} -> Coordinator.team_status(pid)
      error -> error
    end
  end

  # Communication

  @doc """
  Send a message to a specific agent in a team.

  ## Examples

      Nous.Teams.send_message(team_id, "alice", {:user_message, "Start research"})
  """
  @spec send_message(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def send_message(team_id, agent_name, message) do
    pubsub = Nous.PubSub.configured_pubsub()
    Comms.send_to_agent(pubsub, team_id, agent_name, message)
  end

  @doc """
  Broadcast a message to all agents in a team.

  ## Examples

      Nous.Teams.broadcast(team_id, {:announcement, "New task available"})
  """
  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(team_id, message) do
    pubsub = Nous.PubSub.configured_pubsub()
    Comms.broadcast_team(pubsub, team_id, message)
  end

  # Private

  defp find_coordinator(team_id) do
    coordinator_name = :"team_coordinator_#{team_id}"

    case Process.whereis(coordinator_name) do
      nil -> {:error, :team_not_found}
      pid -> {:ok, pid}
    end
  end

  defp team_supervisor_name(team_id) do
    :"team_supervisor_#{team_id}"
  end

  defp generate_team_id do
    "team_#{:erlang.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()}"
  end
end

defmodule Nous.Teams.Supervisor do
  @moduledoc """
  Per-team Supervisor that manages team infrastructure processes.

  Started dynamically under `Nous.AgentDynamicSupervisor` for each team.
  Supervises the Coordinator, SharedState, optional RateLimiter, and the
  team's agent DynamicSupervisor.

  ## Architecture

      Nous.AgentDynamicSupervisor (existing)
      └── Nous.Teams.Supervisor (one per team)
          ├── Nous.Teams.Coordinator
          ├── Nous.Teams.SharedState
          ├── Nous.Teams.RateLimiter (optional)
          └── DynamicSupervisor (team's agent processes)

  ## Quick Start

      {:ok, pid} = Nous.Teams.Supervisor.start_link(
        team_id: "team_1",
        team_name: "Research Team",
        pubsub: MyApp.PubSub
      )
  """

  use Supervisor

  @doc """
  Start the team supervisor.

  ## Options

  - `:team_id` (required) — unique identifier for the team
  - `:team_name` — human-readable team name (default: team_id)
  - `:pubsub` — PubSub module for messaging
  - `:budget` — team budget in USD (enables RateLimiter)
  - `:per_agent_budget` — per-agent budget in USD
  - `:rpm` — requests per minute limit
  - `:tpm` — tokens per minute limit
  - `:name` — optional Supervisor name
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    sup_opts = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, opts, sup_opts)
  end

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    team_name = Keyword.get(opts, :team_name, team_id)
    pubsub = Keyword.get(opts, :pubsub) || Nous.PubSub.configured_pubsub()

    # Names for team-internal processes
    agent_sup_name = :"team_agent_sup_#{team_id}"
    shared_state_name = :"team_shared_state_#{team_id}"
    coordinator_name = :"team_coordinator_#{team_id}"

    # Build rate limiter config
    budget = Keyword.get(opts, :budget)
    has_rate_limiter = budget != nil

    rate_limiter_name = :"team_rate_limiter_#{team_id}"

    children =
      [
        # Agent DynamicSupervisor
        {DynamicSupervisor, strategy: :one_for_one, name: agent_sup_name},

        # SharedState
        {Nous.Teams.SharedState, team_id: team_id, name: shared_state_name},

        # RateLimiter (optional)
        if has_rate_limiter do
          {Nous.Teams.RateLimiter,
           team_id: team_id,
           budget: budget,
           per_agent_budget: Keyword.get(opts, :per_agent_budget),
           rpm: Keyword.get(opts, :rpm),
           tpm: Keyword.get(opts, :tpm),
           name: rate_limiter_name}
        end,

        # Coordinator (started last so it can reference other processes)
        {Nous.Teams.Coordinator,
         team_id: team_id,
         team_name: team_name,
         pubsub: pubsub,
         agent_supervisor: agent_sup_name,
         shared_state: shared_state_name,
         rate_limiter: if(has_rate_limiter, do: rate_limiter_name),
         name: coordinator_name}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_all)
  end
end

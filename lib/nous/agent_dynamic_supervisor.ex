defmodule Nous.AgentDynamicSupervisor do
  @moduledoc """
  `DynamicSupervisor` that owns the lifecycle of every `Nous.AgentServer`.

  Started by `Nous.Application` alongside `Nous.AgentRegistry`: this process
  supervises the agents, the registry names them. Each child is an
  `AgentServer` for one session, started with
  `Nous.AgentRegistry.via_tuple(session_id)` as its `:name`, so the two are
  always in step — start an agent here and it becomes resolvable there;
  when it exits, the registry entry disappears with it.

  Restart intensity is deliberately loosened to `max_restarts: 100` in
  `max_seconds: 10`. The `:one_for_one` default of 3-in-5 means one user's
  crash-looping agent would collapse the supervisor and take every other
  tenant's agent with it; the wider budget still trips if the whole layer is
  broken, but not for a single bad session.

  Children are transient in practice, not pre-declared: nothing is started at
  boot, and you add agents at runtime with `start_agent/3`.

  ## Examples

      # `agent_config` is a plain map (see `t:Nous.AgentServer.agent_config/0`),
      # not a built `%Nous.Agent{}` — the server constructs the agent itself.
      config = %{
        model: "openai:gpt-4o-mini",
        instructions: "You are a helpful assistant.",
        tools: [&Nous.Tools.DateTimeTools.current_date/2]
      }

      {:ok, pid} = Nous.AgentDynamicSupervisor.start_agent("session-42", config)

      # The session ID is the handle from here on
      {:ok, ^pid} = Nous.AgentDynamicSupervisor.find_agent("session-42")
      Nous.AgentServer.send_message(pid, "What day is it?")

      # Session IDs are unique; a second start returns the running process
      Nous.AgentDynamicSupervisor.start_agent("session-42", config)
      #=> {:error, {:already_started, pid}}

      :ok = Nous.AgentDynamicSupervisor.stop_agent("session-42")
      Nous.AgentDynamicSupervisor.find_agent("session-42")
      #=> {:error, :not_found}
  """

  use DynamicSupervisor

  @doc """
  Start the supervisor. Called by `Nous.Application`; you do not need this.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Tuned for multi-tenant blast radius: defaults are max_restarts: 3,
    # max_seconds: 5 - 3 crashes in 5s in any one child collapses the
    # whole DynamicSupervisor and takes down every other user's agent.
    # 100 in 10s is more than generous for a per-user crash loop while
    # still tripping if the entire layer is misbehaving.
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 10
    )
  end

  @doc """
  Start an AgentServer under this supervisor, registered in AgentRegistry.

  `agent_config` is the map described by `t:Nous.AgentServer.agent_config/0`.
  Returns `{:error, {:already_started, pid}}` if `session_id` already has a
  live agent.

  ## Options

  Accepts all options supported by `Nous.AgentServer.start_link/1`.
  """
  @spec start_agent(String.t(), Nous.AgentServer.agent_config(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_agent(session_id, agent_config, opts \\ []) do
    child_spec =
      {Nous.AgentServer,
       Keyword.merge(opts,
         session_id: session_id,
         agent_config: agent_config,
         name: Nous.AgentRegistry.via_tuple(session_id)
       )}

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Stop an agent by session ID.

  Returns `{:error, :not_found}` when no agent is registered for that session.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(session_id) do
    case Nous.AgentRegistry.lookup(session_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      {:error, _} = err -> err
    end
  end

  @doc """
  Find an agent process by session ID.

  A thin alias for `Nous.AgentRegistry.lookup/1`.
  """
  @spec find_agent(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find_agent(session_id) do
    Nous.AgentRegistry.lookup(session_id)
  end
end

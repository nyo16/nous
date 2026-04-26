defmodule Nous.AgentDynamicSupervisor do
  @moduledoc "DynamicSupervisor for starting and managing AgentServer processes."

  use DynamicSupervisor

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

  ## Options

  Accepts all options supported by `Nous.AgentServer.start_link/1`.
  """
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
  """
  def stop_agent(session_id) do
    case Nous.AgentRegistry.lookup(session_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      {:error, _} = err -> err
    end
  end

  @doc """
  Find an agent process by session ID.
  """
  def find_agent(session_id) do
    Nous.AgentRegistry.lookup(session_id)
  end
end

defmodule Nous.AgentDynamicSupervisor do
  @moduledoc "DynamicSupervisor for starting and managing AgentServer processes."

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
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

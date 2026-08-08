defmodule Nous.AgentRegistry do
  @moduledoc "Registry for looking up agent processes by session ID."

  @typedoc """
  A registry key. Usually a session id, but `Nous.Teams.Coordinator` registers
  team members under a `{:team, team_name, agent_name}` tuple, and `Registry`
  itself accepts any term.
  """
  @type key :: term()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    # Partition across schedulers so high-concurrency lookups (e.g. a
    # LiveView fan-in calling Nous.AgentRegistry.lookup/1 from many sockets)
    # don't serialize on a single ETS-backed partition. Registry defaults to
    # partitions: 1 which becomes a contention point at scale.
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end

  @spec via_tuple(key()) :: {:via, module(), {module(), key()}}
  def via_tuple(session_id) do
    {:via, Registry, {__MODULE__, session_id}}
  end

  @spec lookup(key()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id) do
    case Registry.lookup(__MODULE__, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end

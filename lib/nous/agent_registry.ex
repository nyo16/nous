defmodule Nous.AgentRegistry do
  @moduledoc "Registry for looking up agent processes by session ID."

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

  def via_tuple(session_id) do
    {:via, Registry, {__MODULE__, session_id}}
  end

  def lookup(session_id) do
    case Registry.lookup(__MODULE__, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end

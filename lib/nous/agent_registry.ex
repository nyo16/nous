defmodule Nous.AgentRegistry do
  @moduledoc """
  Unique-key `Registry` mapping session IDs to running `Nous.AgentServer` processes.

  This is one of the two processes Nous starts in its own supervision tree
  (see `Nous.Application`): the registry names agents, and
  `Nous.AgentDynamicSupervisor` owns their lifecycle. Nothing registers here
  directly — `Nous.AgentDynamicSupervisor.start_agent/3` passes
  `via_tuple(session_id)` as the child's `:name`, so an `AgentServer` is
  registered by `Registry` at start and unregistered automatically when it
  exits. Keys are `:unique`, so a session ID can only ever have one live
  agent; starting a second one for the same ID returns
  `{:error, {:already_started, pid}}`.

  The registry is partitioned across `System.schedulers_online/0`, because the
  read path is a hot one: a LiveView fan-in resolves the session's agent on
  every event, from a different process each time.

  ## Examples

      config = %{model: "openai:gpt-4o-mini", instructions: "You are helpful."}
      {:ok, _pid} = Nous.AgentDynamicSupervisor.start_agent("session-42", config)

      # Resolve the pid when you need it
      {:ok, pid} = Nous.AgentRegistry.lookup("session-42")
      Nous.AgentServer.send_message(pid, "Hello")

      # ...or let Registry route a GenServer call for you
      GenServer.call(Nous.AgentRegistry.via_tuple("session-42"), :get_history)

      Nous.AgentRegistry.lookup("no-such-session")
      #=> {:error, :not_found}
  """

  @doc """
  Child spec for the supervision tree; started by `Nous.Application`.
  """
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

  @typedoc """
  A registry key.

  Usually a session id string. `Nous.Teams.Coordinator` registers team members
  under a `{:team, team_id, member_name}` tuple, so the key is any term the
  caller can reproduce — not just a binary.
  """
  @type key :: String.t() | tuple()

  @doc """
  Build the `:via` tuple that names the agent process for `key`.

  Pass it as `:name` when starting an `AgentServer`, or as the server
  reference to any `GenServer` call.
  """
  @spec via_tuple(key()) :: {:via, Registry, {module(), key()}}
  def via_tuple(key) do
    {:via, Registry, {__MODULE__, key}}
  end

  @doc """
  Look up the running agent process registered under `key`.
  """
  @spec lookup(key()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id) do
    case Registry.lookup(__MODULE__, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end

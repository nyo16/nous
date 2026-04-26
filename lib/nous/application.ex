defmodule Nous.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Nous.Finch, pools: %{default: [size: 10, count: 1]}},
      # Task supervisor for async agent tasks
      {Task.Supervisor, name: Nous.TaskSupervisor},
      # Agent process registry and dynamic supervisor
      Nous.AgentRegistry,
      Nous.AgentDynamicSupervisor,
      # ETS persistence table owner - keeps the :nous_persistence table
      # alive across transient agent processes. Without this the table
      # dies with whichever process happens to call save/load first.
      Nous.Persistence.ETS
    ]

    # Tuned restart limits to match AgentDynamicSupervisor - default 3-in-5
    # would cascade to take Nous.AgentRegistry + the dynamic supervisor down
    # together if a Finch / Task.Supervisor restart trips the limit.
    opts = [
      strategy: :one_for_one,
      name: Nous.Supervisor,
      max_restarts: 100,
      max_seconds: 10
    ]

    Supervisor.start_link(children, opts)
  end
end

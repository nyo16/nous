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
      Nous.AgentDynamicSupervisor
    ]

    opts = [strategy: :one_for_one, name: Nous.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

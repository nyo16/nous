defmodule Nous.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    configure_hackney_pool()

    children =
      [
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
      ] ++ optional_bumblebee_children()

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

  # Bumblebee is an optional dep. When loaded, the embedding provider
  # uses a Registry + DynamicSupervisor to keep one ServingHolder
  # GenServer per model_name (M-7). When not loaded, no children are
  # added and the placeholder Bumblebee module returns errors at runtime.
  if Code.ensure_loaded?(Bumblebee) do
    defp optional_bumblebee_children do
      [
        {Registry, keys: :unique, name: Nous.Memory.Embedding.Bumblebee.Registry},
        Nous.Memory.Embedding.Bumblebee.ServingSupervisor
      ]
    end
  else
    defp optional_bumblebee_children, do: []
  end

  # Reconfigure hackney's `:default` pool from app config. Used by both the
  # streaming pipeline (`HTTP.stream/4`) and the Hackney HTTP backend
  # (`Nous.HTTP.Backend.Hackney`). Defaults match hackney's stock defaults
  # (50 max connections, 2s idle keepalive). Override via:
  #
  #     config :nous, :hackney_pool,
  #       max_connections: 200,
  #       timeout: 1_500   # idle keepalive in ms (hackney 4 caps at 2_000)
  #
  # Apps that want a fully isolated pool should pass `pool: :my_pool` per
  # call after starting it with `:hackney_pool.start_pool/2` rather than
  # mutating the shared `:default` pool here.
  defp configure_hackney_pool do
    case Application.get_env(:nous, :hackney_pool) do
      nil ->
        :ok

      opts when is_list(opts) ->
        Application.ensure_all_started(:hackney)

        if max = Keyword.get(opts, :max_connections) do
          :hackney_pool.set_max_connections(:default, max)
        end

        if timeout = Keyword.get(opts, :timeout) do
          :hackney_pool.set_timeout(:default, timeout)
        end

        :ok
    end
  end
end

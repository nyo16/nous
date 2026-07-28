defmodule Nous.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    configure_hackney_pool()

    children =
      [
        {Finch, name: Nous.Finch, pools: finch_pools()},
        # Task supervisor for async agent tasks
        {Task.Supervisor, name: Nous.TaskSupervisor},
        # Agent process registry and dynamic supervisor
        Nous.AgentRegistry,
        Nous.AgentDynamicSupervisor,
        # ETS persistence table owner - keeps the :nous_persistence table
        # alive across transient agent processes. Without this the table
        # dies with whichever process happens to call save/load first.
        Nous.Persistence.ETS,
        # Same ownership pattern for the workflow checkpoint table — without
        # a supervised owner, suspended workflows could vanish whenever the
        # process that saved them exited.
        Nous.Workflow.Checkpoint.ETS
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

  # Finch pool sizing (P-2). This was `size: 10, count: 1`, which capped the
  # whole node at 10 in-flight requests per provider host — below Finch's own
  # default of 50 — and funnelled every checkout through a single pool process,
  # which is precisely the contention `parallel_tool_calls` exists to avoid.
  #
  # - `size: 50` is Finch's stock default: 50 connections per pool per
  #   destination. Five times the old ceiling, and a number Finch itself
  #   considers safe as a default.
  # - `count: min(schedulers_online(), 4)` shards checkouts across up to four
  #   pool processes so the pool manager is no longer a single serialization
  #   point. Capped at 4 rather than one-per-scheduler because a checkout is
  #   pinned to the shard it picked: more shards fragment the connection pool
  #   (a request waits on its own shard while another shard sits idle), and on
  #   a 64-core box one-per-scheduler would imply a 3200-connection ceiling per
  #   provider host, which no provider wants.
  #
  # Connections are opened lazily, so `size * count` is a ceiling, not an
  # allocation. Finch keys pools by destination, so every provider host gets
  # its own pool instance from this one spec — the numbers are shared, the
  # connections are not. Per-host tuning goes in the same map:
  #
  #     config :nous, :finch_pools, %{
  #       "https://api.openai.com" => [size: 200, count: 8],
  #       default: [size: 50, count: 4]
  #     }
  # Public (but @doc false) so the config contract is testable without
  # restarting the application supervisor.
  @doc false
  def finch_pools do
    Application.get_env(:nous, :finch_pools, %{
      default: [size: 50, count: min(System.schedulers_online(), 4)]
    })
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
        configure_hackney_pool(opts)
    end
  end

  defp configure_hackney_pool(opts) do
    # hackney is optional: only touch the pool if it actually started. A bare
    # `:hackney_pool.set_max_connections/2` against a missing app crashes boot,
    # so guard on a successful start instead of ignoring the return value.
    case Application.ensure_all_started(:hackney) do
      {:ok, _started} ->
        if max = Keyword.get(opts, :max_connections) do
          :hackney_pool.set_max_connections(:default, max)
        end

        if timeout = Keyword.get(opts, :timeout) do
          :hackney_pool.set_timeout(:default, timeout)
        end

        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "config :nous, :hackney_pool is set but :hackney could not be started " <>
            "(#{inspect(reason)}). Add {:hackney, \"~> 4.0\"} to your deps. " <>
            "Skipping pool configuration."
        )

        :ok
    end
  end
end

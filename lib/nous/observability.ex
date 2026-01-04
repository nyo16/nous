defmodule Nous.Observability do
  @moduledoc """
  Observability module for exporting telemetry to nous_ui.

  This module provides an opt-in observability layer that captures telemetry events
  from agent runs and sends them to a nous_ui instance via HTTP for visualization.

  ## Configuration

      config :nous,
        observability: [
          enabled: true,
          endpoint: "http://localhost:4000/api/telemetry",
          batch_size: 100,
          batch_timeout: 5_000,
          concurrency: 2,
          max_demand: 50
        ]

  ## Usage

      # Enable at runtime
      Nous.Observability.enable(endpoint: "http://nous-ui.local:4000/api/telemetry")

      # Disable
      Nous.Observability.disable()

      # Check status
      Nous.Observability.enabled?()

  ## Requirements

  This module requires the `broadway` and `off_broadway_memory` dependencies.
  Add them to your mix.exs if you want to use observability:

      {:broadway, "~> 1.0"},
      {:off_broadway_memory, "~> 0.2"}

  ## How it works

  1. Telemetry events from agent execution are captured by `Nous.Observability.Handler`
  2. Events are pushed to an in-memory Broadway producer (`OffBroadwayMemory.Producer`)
  3. Broadway batches events and sends them to nous_ui via HTTP
  4. nous_ui stores the data and provides real-time visualizations

  This design ensures:
  - Zero impact on agent execution (async, non-blocking)
  - Built-in backpressure handling
  - Fault tolerance with automatic retries
  - Graceful shutdown (pending events are flushed)
  """

  alias Nous.Observability.{Handler, Pipeline}

  @doc """
  Enable observability export.

  ## Options

    * `:endpoint` - The nous_ui API endpoint (required)
    * `:batch_size` - Number of spans to batch before sending (default: 100)
    * `:batch_timeout` - Max time in ms to wait before sending a batch (default: 5000)
    * `:concurrency` - Number of concurrent batch processors (default: 2)
    * `:max_demand` - Back-pressure control (default: 50)
    * `:headers` - Additional HTTP headers to include
    * `:metadata` - Global metadata to include in all spans (user_id, session_id, etc.)

  ## Examples

      Nous.Observability.enable(endpoint: "http://localhost:4000/api/telemetry")

      Nous.Observability.enable(
        endpoint: "http://nous-ui.example.com/api/telemetry",
        batch_size: 50,
        batch_timeout: 3000,
        headers: [{"authorization", "Bearer token"}],
        metadata: %{
          user_id: "user_123",
          session_id: "sess_456",
          environment: "production",
          app_version: "1.0.0"
        }
      )
  """
  @spec enable(keyword()) :: :ok | {:error, term()}
  def enable(opts \\ []) do
    config = build_config(opts)

    with :ok <- validate_config(config),
         :ok <- ensure_broadway_available(),
         :ok <- start_pipeline(config),
         :ok <- attach_handler(config) do
      :ok
    end
  end

  @doc """
  Disable observability export.

  This will:
  1. Detach the telemetry handler
  2. Allow the Broadway pipeline to flush pending events
  3. Stop the pipeline
  """
  @spec disable() :: :ok
  def disable do
    Handler.detach()
    stop_pipeline()
    :ok
  end

  @doc """
  Check if observability is currently enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Handler.attached?()
  end

  @doc """
  Get the current observability configuration.
  """
  @spec config() :: keyword()
  def config do
    Application.get_env(:nous, :observability, [])
  end

  @doc """
  Push a span directly to the observability pipeline.

  This is primarily used internally by the telemetry handler, but can also
  be used to manually push custom spans.
  """
  @spec push_span(map()) :: :ok | {:error, :not_enabled}
  def push_span(span) when is_map(span) do
    if enabled?() do
      Pipeline.push(span)
    else
      {:error, :not_enabled}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @doc """
  Set per-run metadata for observability spans.

  This metadata will be merged with the global metadata set in enable/1.
  Per-run metadata takes precedence over global metadata.

  ## Examples

      Nous.Observability.set_run_metadata(%{
        user_id: current_user.id,
        request_id: request_id,
        tags: ["important", "customer-support"]
      })
  """
  @spec set_run_metadata(map()) :: :ok
  def set_run_metadata(metadata) when is_map(metadata) do
    Process.put(:nous_observability_metadata, metadata)
    :ok
  end

  @doc """
  Get the current observability metadata (global + per-run).
  """
  @spec get_metadata() :: map()
  def get_metadata do
    global_metadata = config()[:metadata] || %{}
    run_metadata = Process.get(:nous_observability_metadata, %{})

    global_metadata
    |> Map.merge(run_metadata)
  end

  defp build_config(opts) do
    defaults = Application.get_env(:nous, :observability, [])

    defaults
    |> Keyword.merge(opts)
    |> Keyword.put_new(:batch_size, 100)
    |> Keyword.put_new(:batch_timeout, 5_000)
    |> Keyword.put_new(:concurrency, 2)
    |> Keyword.put_new(:max_demand, 50)
    |> Keyword.put_new(:headers, [])
    |> Keyword.put_new(:metadata, %{})
  end

  defp validate_config(config) do
    case Keyword.get(config, :endpoint) do
      nil -> {:error, :endpoint_required}
      endpoint when is_binary(endpoint) -> :ok
      _ -> {:error, :invalid_endpoint}
    end
  end

  defp ensure_broadway_available do
    if Code.ensure_loaded?(Broadway) and Code.ensure_loaded?(OffBroadwayMemory.Producer) do
      :ok
    else
      {:error, :broadway_not_available}
    end
  end

  defp start_pipeline(config) do
    case Pipeline.start_link(config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_pipeline do
    case Process.whereis(Nous.Observability.Pipeline) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp attach_handler(config) do
    Handler.attach(config)
  end
end

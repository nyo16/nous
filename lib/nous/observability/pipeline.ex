defmodule Nous.Observability.Pipeline do
  @moduledoc """
  Broadway pipeline for batching and sending telemetry spans to nous_ui.

  Uses `OffBroadwayMemory.Producer` for in-memory queueing and
  Broadway for batching, concurrency, and fault tolerance.
  """

  use Broadway

  require Logger

  @buffer_name Nous.Observability.Buffer

  @doc """
  Start the Broadway pipeline.

  ## Options

    * `:endpoint` - The nous_ui API endpoint (required)
    * `:batch_size` - Number of spans to batch before sending (default: 100)
    * `:batch_timeout` - Max time in ms to wait before sending a batch (default: 5000)
    * `:concurrency` - Number of concurrent batch processors (default: 2)
    * `:max_demand` - Back-pressure control (default: 50)
    * `:headers` - Additional HTTP headers

  """
  def start_link(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    batch_size = Keyword.get(opts, :batch_size, 100)
    batch_timeout = Keyword.get(opts, :batch_timeout, 5_000)
    concurrency = Keyword.get(opts, :concurrency, 2)
    max_demand = Keyword.get(opts, :max_demand, 50)
    headers = Keyword.get(opts, :headers, [])

    # Create a named buffer for the memory producer
    {:ok, _buffer} = OffBroadwayMemory.Buffer.start_link(name: @buffer_name)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {OffBroadwayMemory.Producer, buffer: @buffer_name},
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: concurrency,
          max_demand: max_demand
        ]
      ],
      batchers: [
        default: [
          concurrency: concurrency,
          batch_size: batch_size,
          batch_timeout: batch_timeout
        ]
      ],
      context: %{
        endpoint: endpoint,
        headers: headers
      }
    )
  end

  @doc """
  Push a span to the pipeline for processing.

  This is a non-blocking operation - the span is queued and will be
  batched and sent asynchronously.
  """
  @spec push(map()) :: :ok
  def push(span) when is_map(span) do
    case Process.whereis(@buffer_name) do
      nil ->
        # Buffer not running, silently drop
        :ok

      _pid ->
        OffBroadwayMemory.Buffer.push(@buffer_name, span)
    end
  end

  # ============================================================================
  # Broadway Callbacks
  # ============================================================================

  @impl true
  def handle_message(_processor, message, _context) do
    # Pass through to batcher - batching is where we do the work
    message
  end

  @impl true
  def handle_batch(:default, messages, _batch_info, context) do
    spans = Enum.map(messages, & &1.data)

    case send_batch(spans, context) do
      :ok ->
        messages

      {:error, reason} ->
        Logger.warning("[Nous.Observability] Failed to send batch: #{inspect(reason)}")
        # Mark messages as failed for potential retry
        Enum.map(messages, &Broadway.Message.failed(&1, reason))
    end
  end

  # ============================================================================
  # HTTP Sending
  # ============================================================================

  defp send_batch(spans, %{endpoint: endpoint, headers: custom_headers}) do
    batch_endpoint = "#{endpoint}/batch"

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "nous-observability/#{Application.spec(:nous, :vsn)}"}
      | custom_headers
    ]

    body = Jason.encode!(%{spans: spans})

    case Req.post(batch_endpoint, body: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Nous.HTTP.StreamBackend.Hackney do
  @moduledoc """
  `Nous.HTTP.StreamBackend` implementation backed by `:hackney` in
  `[{:async, :once}]` mode for strict pull-based backpressure.

  The consumer calls `:hackney.stream_next/1` to ask for one more chunk;
  hackney reads it off the socket and delivers it as a single message
  `{:hackney_response, conn, chunk_or_done}`. Because the network read
  only happens when the consumer asks for it, the producer literally
  cannot outrun the consumer — the mailbox stays bounded at one message
  no matter how slow the consumer is.

  Pick this backend when downstream consumers can block per chunk
  (LiveView fan-out under load, persistence-on-every-chunk, slow IO).
  For typical LLM workloads where token-generation rate is the
  bottleneck, `Nous.HTTP.StreamBackend.Req` is simpler and equally fast.

  ## Hackney 4 option shape

  Hackney 4 documents the pull-based form as `[{async, once}]` — a
  **tuple**. The legacy `[:async, :once]` two-atom form silently puts
  hackney into push mode (`proplists` resolves bare `:async` as
  `{:async, true}`), which forfeits the backpressure guarantee. This
  module uses the tuple form. See `deps/hackney/NEWS.md:255-275`.

  ## TLS verification

  Passes `verify: :verify_peer` with system CAs from
  `:public_key.cacerts_get/0` explicitly. Hackney's default is
  `:verify_none`, which would silently accept MITM'd connections — do
  not regress this.

  ## Pool

  Uses hackney's `:default` pool (50 conns, 2s idle keepalive) unless
  the caller passes `:pool`. Apps that want isolation can pass
  `pool: :my_pool` per call after starting the pool with
  `:hackney_pool.start_pool/2`.
  """

  @behaviour Nous.HTTP.StreamBackend

  require Logger

  alias Nous.Providers.HTTP

  # 3 minutes — LLM streams (especially with reasoning) can sit silent
  # between chunks long enough to trip a tighter timeout. Per-call
  # `:timeout` opt overrides.
  @default_timeout 180_000
  @default_connect_timeout 30_000

  @impl Nous.HTTP.StreamBackend
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    pool = Keyword.get(opts, :pool, :default)
    stream_parser = Keyword.get(opts, :stream_parser)

    try do
      json_body = JSON.encode!(body)

      stream =
        Stream.resource(
          fn ->
            start_streaming(url, headers, json_body, timeout, connect_timeout, pool,
              stream_parser: stream_parser
            )
          end,
          &next_chunk/1,
          &cleanup/1
        )

      {:ok, stream}
    catch
      _, error ->
        Logger.error("Failed to encode request body: #{inspect(error)}")
        {:error, %{reason: :json_encode_error, details: error}}
    end
  end

  @doc false
  # Public for unit-testing the regression net on the option proplist
  # shape. Returns the proplist passed to `:hackney.request/5`. The
  # `{:async, :once}` tuple form is what enables pull mode — a bare
  # `:async` atom would put hackney into push mode (proplists resolves
  # bare atoms as `{atom, true}`), forfeiting backpressure. See
  # `deps/hackney/NEWS.md:269-272` and the regression test in
  # `test/nous/http/stream_backend/hackney_test.exs`.
  @spec request_opts(non_neg_integer(), non_neg_integer(), atom()) :: keyword()
  def request_opts(timeout, connect_timeout, pool) do
    [
      {:async, :once},
      {:pool, pool},
      {:recv_timeout, timeout},
      {:connect_timeout, connect_timeout},
      {:ssl_options, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}
    ]
  end

  # Start streaming via hackney's `[{:async, :once}]` pull-based mode.
  defp start_streaming(url, headers, body, timeout, connect_timeout, pool, extra) do
    stream_parser = Keyword.get(extra, :stream_parser)
    hackney_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    opts = request_opts(timeout, connect_timeout, pool)

    case :hackney.request(:post, url, hackney_headers, body, opts) do
      {:ok, ref} ->
        %{
          ref: ref,
          buffer: "",
          done: false,
          status: nil,
          timeout: timeout,
          error: nil,
          stream_parser: stream_parser
        }

      {:error, reason} ->
        Logger.error("hackney request failed: #{inspect(reason)}")

        # Stay `done: false` here so the next_chunk error-emission clause
        # fires once before halting. Setting done immediately would short-
        # circuit straight to {:halt, _} and the consumer would never see
        # the {:stream_error, _} event.
        %{
          ref: nil,
          buffer: "",
          done: false,
          status: nil,
          timeout: timeout,
          error: {:stream_error, %{reason: reason}},
          stream_parser: stream_parser
        }
    end
  end

  # Get next chunk from the hackney `[{:async, :once}]` stream.
  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(%{ref: nil, error: {:stream_error, _} = err} = state) do
    {[err], %{state | done: true}}
  end

  defp next_chunk(state) do
    timeout = state.timeout

    # :hackney.stream_next/1 returns :ok unconditionally; errors arrive
    # asynchronously as {:hackney_response, ref, {:error, _}}.
    :ok = :hackney.stream_next(state.ref)

    ref = state.ref

    receive do
      {:hackney_response, ^ref, {:status, status, _reason_phrase}}
      when status not in 200..299 ->
        Logger.error("Hackney stream got error status #{status}")
        {[{:stream_error, %{status: status}}], %{state | done: true}}

      {:hackney_response, ^ref, {:status, status, _reason_phrase}} ->
        next_chunk(%{state | status: status})

      {:hackney_response, ^ref, {:headers, _headers}} ->
        next_chunk(state)

      {:hackney_response, ^ref, :done} ->
        {events, _} = HTTP.flush_stream_buffer(state.buffer, state.stream_parser)

        final_events =
          Enum.reject(events, fn
            nil -> true
            {:parse_error, _} -> true
            _ -> false
          end)

        if Enum.empty?(final_events) do
          {:halt, %{state | done: true}}
        else
          {final_events, %{state | done: true, buffer: ""}}
        end

      {:hackney_response, ^ref, {:error, reason}} ->
        Logger.error("Hackney stream error: #{inspect(reason)}")
        {[{:stream_error, reason}], %{state | done: true}}

      {:hackney_response, ^ref, chunk} when is_binary(chunk) ->
        new_buffer = state.buffer <> chunk

        if byte_size(new_buffer) > HTTP.max_buffer_size() do
          Logger.error("SSE buffer overflow, terminating stream")
          {[{:stream_error, %{reason: :buffer_overflow}}], %{state | done: true}}
        else
          {events, remaining_buffer} =
            HTTP.parse_stream_buffer(new_buffer, state.stream_parser)

          {valid_events, errors} =
            Enum.split_with(events, fn
              {:parse_error, _} -> false
              _ -> true
            end)

          for {:parse_error, err} <- errors do
            Logger.debug("SSE parse error (ignored): #{inspect(err)}")
          end

          if Enum.empty?(valid_events) do
            next_chunk(%{state | buffer: remaining_buffer})
          else
            {valid_events, %{state | buffer: remaining_buffer}}
          end
        end
    after
      timeout ->
        Logger.error("Hackney stream timeout after #{timeout}ms")
        {[{:stream_error, %{reason: :timeout, timeout_ms: timeout}}], %{state | done: true}}
    end
  end

  # Cleanup when the consumer halts (Stream.take/2, exception, normal end).
  defp cleanup(%{ref: nil}), do: :ok

  defp cleanup(%{ref: ref}) do
    _ = :hackney.close(ref)
    :ok
  end
end

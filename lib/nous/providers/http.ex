defmodule Nous.Providers.HTTP do
  @moduledoc """
  Shared HTTP utilities for all LLM providers.

  Two HTTP families, deliberately split by use case:

  - **Non-streaming** requests (one-shot model calls, web fetching, search
    APIs) go through a pluggable `Nous.HTTP.Backend`. The default is
    `Nous.HTTP.Backend.Req` (Req on top of Finch). `Nous.HTTP.Backend.Hackney`
    is also shipped — pick it via per-call `:backend` opt, the
    `NOUS_HTTP_BACKEND` env var, or `config :nous, :http_backend, ...`.
    See `docs/benchmarks/http_backend.md` for the trade-offs.
  - **Streaming** requests (SSE / chunked LLM responses) go through
    `:hackney` in `:async, :once` pull-based mode. Hackney's `:async, :once`
    is true pull-based streaming - the consumer calls
    `:hackney.stream_next/1` to ask for one more chunk, the producer reads
    it off the socket and delivers it as a single message. The consumer
    paces the producer, so a slow consumer (LiveView assigns + diff +
    push, slow IO, etc.) can never grow its mailbox unboundedly.

  This split fixes M-12 (streaming consumer backpressure) and H-12 (stream
  lifecycle EXIT handling) from the comprehensive review by eliminating
  the spawn-and-mailbox plumbing entirely - the `Stream.resource`
  consumer is the only process involved.

  ## Usage

      # Non-streaming request (Req + Finch)
      {:ok, body} = HTTP.post(url, body, headers)

      # Streaming request (hackney pull-based, returns lazy stream)
      {:ok, stream} = HTTP.stream(url, body, headers)
      Enum.each(stream, &process_event/1)

  ## SSE Parsing

  SSE events follow the Server-Sent Events spec (https://html.spec.whatwg.org/multipage/server-sent-events.html):
  - Events are separated by double newlines (`\\n\\n`)
  - Each event contains field lines like `data: {...}`
  - Multiple `data:` fields are concatenated with newlines
  - `[DONE]` signals stream completion (OpenAI convention)

  ## Hackney pool

  Hackney's `:default` pool starts automatically when the `:hackney`
  application boots. Defaults: 50 max connections per pool, 2s idle
  keepalive timeout. For most LLM workloads (long-lived streams of
  seconds-to-minutes) the defaults are appropriate. Apps that need a
  Nous-isolated pool can pass `pool: :my_pool` per request and start
  the pool with `:hackney_pool.start_pool/2` (or include
  `:hackney_pool.child_spec/2` in their supervision tree).

  ## TLS verification

  Streaming requests pass `verify: :verify_peer` with system CAs from
  `:public_key.cacerts_get/0` explicitly. Do not silently regress this -
  hackney would otherwise default to `:verify_none` and accept MITM'd
  connections.
  """

  require Logger

  @default_timeout 60_000
  @default_connect_timeout 30_000
  # 10MB max buffer
  @max_buffer_size 10 * 1024 * 1024

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Make a non-streaming POST request.

  Dispatches to the configured `Nous.HTTP.Backend`. Resolution order
  (highest precedence first):

  1. Per-call `:backend` opt — `HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)`
  2. `NOUS_HTTP_BACKEND` env var — `req`, `hackney`, or a fully-qualified
     module name (e.g. `MyApp.MyHTTPBackend`)
  3. `Application.get_env(:nous, :http_backend, ...)`
  4. Default: `Nous.HTTP.Backend.Req`

  Returns `{:ok, body}` or `{:error, reason}`.

  ## Options
    * `:backend` - Backend module (overrides env / config / default)
    * `:timeout` - Request timeout in ms (default: 60_000)

  ## Error Reasons
    * `%{status: integer(), body: term()}` - HTTP error response
    * `%Mint.TransportError{}` - Network error (Req backend)
    * `%JSON.DecodeError{}` - JSON decode error
  """
  @spec post(String.t(), map(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, body, headers, opts \\ [])

  def post(url, body, headers, opts) when is_binary(url) and is_map(body) and is_list(headers) do
    backend = Keyword.get(opts, :backend) || configured_backend()
    backend.post(url, body, headers, opts)
  end

  def post(url, body, headers, _opts) do
    {:error,
     %ArgumentError{
       message:
         "Invalid arguments: url must be string, body must be map, headers must be list. " <>
           "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{inspect(headers)}"
     }}
  end

  # Resolve the configured HTTP backend. The env var takes precedence over
  # app config so ops can A/B-test backends without a redeploy.
  #
  # Custom backend modules are resolved via `String.to_existing_atom/1` to
  # uphold the project-wide rule (review C-2): never `String.to_atom/1` on
  # untrusted input. If the atom doesn't exist or doesn't implement the
  # behaviour, fall back to app config / default rather than crash.
  defp configured_backend do
    case System.get_env("NOUS_HTTP_BACKEND") do
      nil -> app_or_default()
      "req" -> Nous.HTTP.Backend.Req
      "hackney" -> Nous.HTTP.Backend.Hackney
      other -> resolve_custom_backend(other)
    end
  end

  defp resolve_custom_backend(name) do
    mod = String.to_existing_atom("Elixir." <> name)
    Code.ensure_loaded?(mod)

    if function_exported?(mod, :post, 4) do
      mod
    else
      app_or_default()
    end
  rescue
    ArgumentError -> app_or_default()
  end

  defp app_or_default do
    Application.get_env(:nous, :http_backend, Nous.HTTP.Backend.Req)
  end

  @doc """
  Make a streaming POST request with SSE parsing.

  Returns `{:ok, stream}` where stream is an Enumerable of parsed events.
  Events are maps with string keys (parsed JSON) or `{:stream_done, reason}` tuples.

  ## Options
    * `:timeout` - Receive timeout in ms (default: 60_000) — passed to
      hackney as `:recv_timeout`.
    * `:connect_timeout` - TCP connect timeout in ms (default: 30_000).
    * `:pool` - Hackney pool name (default: `:default`). Configure the
      default pool via `config :nous, :hackney_pool, max_connections:
      ..., timeout: ...` or start a dedicated pool with
      `:hackney_pool.start_pool/2`.
    * `:stream_parser` - Module for parsing the stream buffer (default: SSE parsing).
      Must implement `parse_buffer/1` returning `{events, remaining_buffer}`.
      See `Nous.Providers.HTTP.JSONArrayParser` for an example.
    * `:finch_name` - Ignored. Kept for source compatibility with
      callers from before the 0.15.0 hackney rewrite. Will be removed
      in a future release.

  ## Error Handling
  The stream will emit `{:stream_error, reason}` on errors and then halt.
  """
  @spec stream(String.t(), map(), list(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    pool = Keyword.get(opts, :pool, :default)
    stream_parser = Keyword.get(opts, :stream_parser)

    try do
      json_body = JSON.encode!(body)

      # Add streaming headers if not present
      headers = ensure_streaming_headers(headers)

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

  def stream(url, body, headers, _opts) do
    {:error,
     %ArgumentError{
       message:
         "Invalid arguments: url must be string, body must be map, headers must be list. " <>
           "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{inspect(headers)}"
     }}
  end

  # ============================================================================
  # SSE Parsing (Public for testing)
  # ============================================================================

  @doc """
  Parse an SSE buffer into events.

  Returns `{events, remaining_buffer}` where events is a list of parsed
  JSON maps, `{:stream_done, reason}` tuples, or `{:parse_error, reason}` tuples.

  Handles edge cases:
  - Empty events (ignored)
  - Whitespace-only events (ignored)
  - Malformed JSON (emits `{:parse_error, reason}`)
  - Multiple data fields per event (concatenated per spec)
  - Comment lines (ignored)
  - Buffer overflow protection

  ## Examples

      iex> parse_sse_buffer("data: {\\"text\\": \\"hi\\"}\\n\\n")
      {[%{"text" => "hi"}], ""}

      iex> parse_sse_buffer("data: partial")
      {[], "data: partial"}

      iex> parse_sse_buffer("data: [DONE]\\n\\n")
      {[{:stream_done, "stop"}], ""}
  """
  @spec parse_sse_buffer(String.t() | nil | any()) ::
          {list(), String.t()} | {:error, :buffer_overflow}
  def parse_sse_buffer(buffer) when is_binary(buffer) do
    # Buffer overflow is now a HARD error, not a silent truncation. The
    # previous behavior sliced from the front, which cut mid-event/mid-JSON
    # and produced one parse_error followed by valid events - silent data
    # loss. Halting here lets the consumer surface the failure cleanly.
    if byte_size(buffer) > @max_buffer_size do
      Logger.error("SSE buffer exceeded max size (#{@max_buffer_size} bytes), aborting stream")
      {:error, :buffer_overflow}
    else
      do_parse_sse_buffer(buffer)
    end
  end

  def parse_sse_buffer(nil), do: {[], ""}
  def parse_sse_buffer(_), do: {[], ""}

  defp do_parse_sse_buffer(buffer) when is_binary(buffer) do
    # Split on double newlines (SSE event separator)
    # Handle both \n\n and \r\n\r\n
    parts = String.split(buffer, ~r/\r?\n\r?\n/)

    case parts do
      [incomplete] ->
        # No complete events yet
        {[], incomplete}

      parts ->
        # All but the last part are complete events
        {complete, [incomplete]} = Enum.split(parts, -1)

        events =
          complete
          |> Enum.map(&parse_sse_event/1)
          |> Enum.reject(&is_nil/1)

        {events, incomplete}
    end
  end

  @doc """
  Parse a single SSE event.

  Returns parsed JSON map, `{:stream_done, reason}`, `{:parse_error, reason}`, or nil.

  Handles per SSE spec:
  - `data:` fields (with or without space after colon)
  - Multiple `data:` fields concatenated with newlines
  - `:` prefix for comments (ignored)
  - `event:`, `id:`, `retry:` fields (ignored for now)
  - Empty lines within events

  ## Examples

      iex> parse_sse_event("data: {\\"key\\": \\"value\\"}")
      %{"key" => "value"}

      iex> parse_sse_event("data: [DONE]")
      {:stream_done, "stop"}

      iex> parse_sse_event(": this is a comment")
      nil

      iex> parse_sse_event("")
      nil
  """
  @spec parse_sse_event(String.t()) ::
          map() | {:stream_done, String.t()} | {:parse_error, term()} | nil
  def parse_sse_event(event) when is_binary(event) do
    # Trim and check for empty
    event = String.trim(event)

    if event == "" do
      nil
    else
      parse_sse_event_lines(String.split(event, ~r/\r?\n/))
    end
  end

  def parse_sse_event(_), do: nil

  # ============================================================================
  # Header Helpers (Public for testing)
  # ============================================================================

  @doc """
  Build authorization header for Bearer token auth (OpenAI style).

  Returns empty list for nil, empty string, or "not-needed" values.
  """
  @spec bearer_auth_header(String.t() | nil) :: list()
  def bearer_auth_header(nil), do: []
  def bearer_auth_header(""), do: []
  def bearer_auth_header("not-needed"), do: []

  def bearer_auth_header(api_key) when is_binary(api_key),
    do: [{"authorization", "Bearer #{api_key}"}]

  def bearer_auth_header(_), do: []

  @doc """
  Build authorization header for API key auth (Anthropic style).

  Returns empty list for nil or empty string values.
  """
  @spec api_key_header(String.t() | nil, String.t()) :: list()
  def api_key_header(nil, _header_name), do: []
  def api_key_header("", _header_name), do: []

  def api_key_header(api_key, header_name) when is_binary(api_key) and is_binary(header_name) do
    [{header_name, api_key}]
  end

  def api_key_header(_, _), do: []

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Ensure headers include streaming-related ones
  defp ensure_streaming_headers(headers) do
    headers
    |> maybe_add_header("content-type", "application/json")
    |> maybe_add_header("accept", "text/event-stream")
  end

  defp maybe_add_header(headers, key, value) do
    key_lower = String.downcase(key)

    if Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == key_lower end) do
      headers
    else
      [{key, value} | headers]
    end
  end

  # Parse SSE event from lines
  defp parse_sse_event_lines(lines) do
    # Collect all data fields
    data_parts =
      lines
      |> Enum.reduce([], fn line, acc ->
        cond do
          # Comment line (starts with :)
          String.starts_with?(line, ":") ->
            acc

          # Data field with space
          String.starts_with?(line, "data: ") ->
            [String.replace_prefix(line, "data: ", "") | acc]

          # Data field without space (valid per spec)
          String.starts_with?(line, "data:") ->
            [String.replace_prefix(line, "data:", "") | acc]

          # Other fields (event:, id:, retry:) - ignore for now
          String.contains?(line, ":") ->
            acc

          # Empty line or continuation
          true ->
            acc
        end
      end)
      |> Enum.reverse()

    if Enum.empty?(data_parts) do
      nil
    else
      # Per SSE spec, multiple data fields are joined with newlines
      data = Enum.join(data_parts, "\n")
      parse_data_content(data)
    end
  end

  # Parse the data content (JSON or special markers)
  defp parse_data_content("[DONE]"), do: {:stream_done, "stop"}
  defp parse_data_content(""), do: nil

  defp parse_data_content(data) do
    case JSON.decode(data) do
      {:ok, parsed} ->
        parsed

      {:error, error} ->
        # Only log at debug level - malformed data is common during streaming
        Logger.debug(
          "Failed to parse SSE data as JSON: #{truncate_for_log(data)}, error: #{inspect(error)}"
        )

        {:parse_error, %{data: data, error: error}}
    end
  end

  # Start streaming via hackney's `:async, :once` pull-based mode.
  #
  # The previous implementation used `Finch.stream/5` with a callback that
  # fire-and-forgets `send(parent, ...)` per chunk - push-based, with no
  # backpressure. A fast LLM (e.g. Groq at 500 tok/s) feeding a slow
  # consumer (LiveView assigns + diff + push, slow stdout, etc.) grew the
  # consumer mailbox unboundedly until either the 10 MiB buffer cap tripped
  # or the BEAM scheduler starved.
  #
  # `:hackney.request/5` with `[:async, :once]` returns a request ref. The
  # consumer pulls chunks one at a time by calling `:hackney.stream_next/1`,
  # which causes hackney to read one more chunk off the socket and deliver
  # it as `{:hackney_response, ref, chunk_or_done}`. The network read only
  # happens when the consumer asks for it — the producer literally cannot
  # outrun the consumer.
  #
  # As a side-effect this also eliminates the spawn-and-monitor plumbing
  # that the previous design needed (H-12), the `Task.await(:infinity)`
  # blocker, and the awkward parent EXIT/DOWN handling. The Stream.resource
  # consumer IS the only process; cancellation is just the consumer
  # halting its enumerator and `:hackney.close/1` releasing the conn.
  #
  defp start_streaming(url, headers, body, timeout, connect_timeout, pool, extra) do
    stream_parser = Keyword.get(extra, :stream_parser)
    hackney_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    opts = [
      :async,
      :once,
      {:pool, pool},
      {:recv_timeout, timeout},
      {:connect_timeout, connect_timeout},
      {:ssl_options, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}
    ]

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

  # Get next chunk from the hackney `:async, :once` stream.
  #
  # Pull semantics: we call `:hackney.stream_next/1` to ask for ONE more
  # message from hackney, then block in `receive` for it. No mailbox
  # accumulation possible - each iteration moves exactly one chunk through.
  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(%{ref: nil, error: {:stream_error, _} = err} = state) do
    {[err], %{state | done: true}}
  end

  defp next_chunk(state) do
    timeout = state.timeout

    # :hackney.stream_next/1 is spec'd to return :ok unconditionally
    # (errors arrive asynchronously as {:hackney_response, ref, {:error, _}}).
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
        # Flush any remaining buffer with the parser's end-of-stream rules.
        {events, _} = flush_stream_buffer(state.buffer, state.stream_parser)

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

        if byte_size(new_buffer) > @max_buffer_size do
          Logger.error("SSE buffer overflow, terminating stream")
          {[{:stream_error, %{reason: :buffer_overflow}}], %{state | done: true}}
        else
          {events, remaining_buffer} = parse_stream_buffer(new_buffer, state.stream_parser)

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

  # Parse stream buffer using the configured parser (default: SSE).
  # Translates the new {:error, :buffer_overflow} tuple from parse_sse_buffer
  # into the legacy {events, buffer} shape so existing call sites keep working.
  defp parse_stream_buffer(buffer, nil) do
    case parse_sse_buffer(buffer) do
      {:error, :buffer_overflow} -> {[{:stream_error, %{reason: :buffer_overflow}}], ""}
      result -> result
    end
  end

  defp parse_stream_buffer(buffer, parser_mod), do: parser_mod.parse_buffer(buffer)

  # Flush remaining buffer at end of stream
  # SSE needs a trailing \n\n to force the last event through;
  # custom parsers just re-parse the remaining buffer as-is.
  defp flush_stream_buffer(buffer, nil) do
    case parse_sse_buffer(buffer <> "\n\n") do
      {:error, :buffer_overflow} -> {[{:stream_error, %{reason: :buffer_overflow}}], ""}
      result -> result
    end
  end

  defp flush_stream_buffer(buffer, parser_mod), do: parser_mod.parse_buffer(buffer)

  # Cleanup when the consumer halts (Stream.take/2, exception, normal end).
  # `:hackney.close/1` releases the connection back to the default pool
  # (or closes it if no pool was configured). Idempotent and safe to call
  # whether or not the stream finished.
  defp cleanup(%{ref: nil}), do: :ok

  defp cleanup(%{ref: ref}) do
    _ = :hackney.close(ref)
    :ok
  end

  # Truncate data for logging to avoid huge log messages
  defp truncate_for_log(data) when is_binary(data) do
    if byte_size(data) > 500 do
      String.slice(data, 0, 500) <> "... (truncated)"
    else
      data
    end
  end
end

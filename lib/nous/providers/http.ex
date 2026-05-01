defmodule Nous.Providers.HTTP do
  @moduledoc """
  Shared HTTP utilities for all LLM providers.

  Two HTTP families, both pluggable:

  - **Non-streaming** requests (one-shot model calls, web fetching, search
    APIs) go through a `Nous.HTTP.Backend`. Default is
    `Nous.HTTP.Backend.Req`; `Nous.HTTP.Backend.Hackney` is also shipped.
  - **Streaming** requests (SSE / chunked LLM responses) go through a
    `Nous.HTTP.StreamBackend`. Default is `Nous.HTTP.StreamBackend.Req`
    (Req's `:into` callback driven by Finch); `Nous.HTTP.StreamBackend.Hackney`
    provides strict pull-based backpressure via `:hackney`'s `{:async, :once}`
    mode for callers whose downstream consumers can block per chunk.

  Both backend layers resolve via the same precedence: per-call opt → env
  var → app config → default. See `Nous.HTTP.Backend` and
  `Nous.HTTP.StreamBackend` for selection details.

  ## Usage

      # Non-streaming request
      {:ok, body} = HTTP.post(url, body, headers)

      # Streaming request — returns a lazy stream of parsed events
      {:ok, stream} = HTTP.stream(url, body, headers)
      Enum.each(stream, &process_event/1)

      # Per-call backend override
      {:ok, stream} = HTTP.stream(url, body, headers,
        stream_backend: Nous.HTTP.StreamBackend.Hackney)

  ## SSE Parsing

  SSE events follow the Server-Sent Events spec (https://html.spec.whatwg.org/multipage/server-sent-events.html):
  - Events are separated by double newlines (`\\n\\n`)
  - Each event contains field lines like `data: {...}`
  - Multiple `data:` fields are concatenated with newlines
  - `[DONE]` signals stream completion (OpenAI convention)

  The default SSE parser (`parse_sse_buffer/1`) is transport-agnostic and
  shared by both stream backends. Custom parsers can be plugged in via
  the `:stream_parser` opt; see `Nous.Providers.HTTP.JSONArrayParser`
  for an example.

  ## Stream backpressure

  - `Nous.HTTP.StreamBackend.Req` (default): the `:into` callback runs in
    a `Task` and feeds the consumer process via `send/2`. BEAM mailboxes
    are unbounded, so a fast producer + slow consumer can grow the
    consumer's mailbox. Acceptable for typical LLM workloads where the
    consumer is parsing-bound (and parsing throttles naturally) or where
    token-generation rate is the bottleneck.
  - `Nous.HTTP.StreamBackend.Hackney`: strict pull-based — the consumer
    calls `:hackney.stream_next/1` per chunk, so the producer literally
    cannot outrun the consumer. Pick this when downstream consumers can
    block per chunk (LiveView fan-out, persistence-on-every-chunk, slow IO).
  """

  require Logger

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
      other -> resolve_custom_backend(other, :post, 4, &app_or_default/0)
    end
  end

  defp app_or_default do
    Application.get_env(:nous, :http_backend, Nous.HTTP.Backend.Req)
  end

  defp resolve_custom_backend(name, fun, arity, fallback) do
    mod = String.to_existing_atom("Elixir." <> name)
    Code.ensure_loaded?(mod)

    if function_exported?(mod, fun, arity) do
      mod
    else
      fallback.()
    end
  rescue
    ArgumentError -> fallback.()
  end

  @doc """
  Make a streaming POST request.

  Dispatches to the configured `Nous.HTTP.StreamBackend`. Resolution
  order (highest precedence first):

  1. Per-call `:stream_backend` opt
  2. `NOUS_HTTP_STREAM_BACKEND` env var — `req`, `hackney`, or a
     fully-qualified module name
  3. `Application.get_env(:nous, :http_stream_backend, ...)`
  4. Default: `Nous.HTTP.StreamBackend.Req`

  Returns `{:ok, stream}` where stream is an `Enumerable.t()` of parsed
  events. Events are maps with string keys (parsed JSON),
  `{:stream_done, reason}` tuples on completion, or
  `{:stream_error, reason}` tuples on failure.

  ## Options
    * `:stream_backend` - Backend module (overrides env / config / default)
    * `:timeout` - Receive timeout in ms (default: 60_000)
    * `:connect_timeout` - TCP connect timeout in ms (default: 30_000)
    * `:stream_parser` - Module for parsing the stream buffer (default: SSE).
      Must implement `parse_buffer/1` returning `{events, remaining_buffer}`.
      See `Nous.Providers.HTTP.JSONArrayParser` for an example.
    * `:pool` - (Hackney backend only) Hackney pool name (default: `:default`).

  ## Error Handling
  The stream emits `{:stream_error, reason}` on errors and then halts.
  """
  @spec stream(String.t(), map(), list(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    backend = Keyword.get(opts, :stream_backend) || configured_stream_backend()
    backend.stream(url, body, ensure_streaming_headers(headers), opts)
  end

  def stream(url, body, headers, _opts) do
    {:error,
     %ArgumentError{
       message:
         "Invalid arguments: url must be string, body must be map, headers must be list. " <>
           "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{inspect(headers)}"
     }}
  end

  defp configured_stream_backend do
    case System.get_env("NOUS_HTTP_STREAM_BACKEND") do
      nil -> stream_app_or_default()
      "req" -> Nous.HTTP.StreamBackend.Req
      "hackney" -> Nous.HTTP.StreamBackend.Hackney
      other -> resolve_custom_backend(other, :stream, 4, &stream_app_or_default/0)
    end
  end

  defp stream_app_or_default do
    Application.get_env(:nous, :http_stream_backend, Nous.HTTP.StreamBackend.Req)
  end

  # ============================================================================
  # SSE Parsing (Public for testing and reuse by stream backends)
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

  @doc false
  # Public for stream-backend reuse only — not part of the public API
  # surface. Translates the new `{:error, :buffer_overflow}` tuple from
  # `parse_sse_buffer/1` into the legacy `{events, buffer}` shape so
  # backends can stay agnostic about the failure mode.
  @spec parse_stream_buffer(String.t(), module() | nil) :: {list(), String.t()}
  def parse_stream_buffer(buffer, nil) do
    case parse_sse_buffer(buffer) do
      {:error, :buffer_overflow} -> {[{:stream_error, %{reason: :buffer_overflow}}], ""}
      result -> result
    end
  end

  def parse_stream_buffer(buffer, parser_mod), do: parser_mod.parse_buffer(buffer)

  @doc false
  # Public for stream-backend reuse only. Flush remaining buffer at end
  # of stream — SSE needs a trailing `\n\n` to force the last event
  # through; custom parsers just re-parse the remaining buffer as-is.
  @spec flush_stream_buffer(String.t(), module() | nil) :: {list(), String.t()}
  def flush_stream_buffer(buffer, nil) do
    case parse_sse_buffer(buffer <> "\n\n") do
      {:error, :buffer_overflow} -> {[{:stream_error, %{reason: :buffer_overflow}}], ""}
      result -> result
    end
  end

  def flush_stream_buffer(buffer, parser_mod), do: parser_mod.parse_buffer(buffer)

  @doc false
  # Max buffer size — public for stream-backend reuse.
  def max_buffer_size, do: @max_buffer_size

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

  @doc false
  # Public for stream-backend reuse. Ensures the request carries
  # `content-type: application/json` and `accept: text/event-stream`
  # if the caller didn't supply them.
  def ensure_streaming_headers(headers) do
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

  # ============================================================================
  # Private Functions
  # ============================================================================

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

  # Truncate data for logging to avoid huge log messages
  defp truncate_for_log(data) when is_binary(data) do
    if byte_size(data) > 500 do
      String.slice(data, 0, 500) <> "... (truncated)"
    else
      data
    end
  end
end

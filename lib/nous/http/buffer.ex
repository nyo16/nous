defmodule Nous.HTTP.Buffer do
  @moduledoc """
  Transport-level stream buffer primitives shared by the
  `Nous.HTTP.StreamBackend` implementations.

  Owns the SSE wire format (`parse_sse_buffer/1`, `parse_sse_event/1`),
  the 10 MB buffer cap, and the `:stream_parser` dispatch that lets a
  provider swap SSE for another framing (see
  `Nous.Providers.HTTP.JSONArrayParser`).

  This module exists so the transport layer (`Nous.HTTP.*`) does not have
  to reach up into the provider layer (`Nous.Providers.HTTP`) for buffer
  handling. `Nous.Providers.HTTP` keeps thin delegating wrappers for the
  public `parse_sse_buffer/1` / `parse_sse_event/1` API.

  ## Resumable parsers

  `parse_stream_buffer/3` and `flush_stream_buffer/3` thread an opaque
  `t:scan_state/0` through the parser. A `:stream_parser` module MAY
  export `parse_buffer/2` returning `{events, remaining, scan_state}` to
  resume scanning where the previous chunk left off instead of rescanning
  the accumulated buffer from byte 0 — the difference between O(n) and
  O(n²) when a single object spans hundreds of chunks. Support is probed
  with `function_exported?/3`; parsers that only export `parse_buffer/1`
  keep working unchanged and simply always get `nil` back.
  """

  require Logger

  @typedoc """
  Opaque parser-owned resume token. `nil` means "no partial scan in
  flight" — parse from the start of the buffer.
  """
  @type scan_state :: term() | nil

  # 10MB max buffer
  @max_buffer_size 10 * 1024 * 1024

  @doc """
  Maximum accumulated stream buffer size, in bytes.
  """
  @spec max_buffer_size() :: pos_integer()
  def max_buffer_size, do: @max_buffer_size

  @doc """
  Parse an SSE buffer into `{events, remaining_buffer}`.

  Returns `{:error, :buffer_overflow}` when the buffer exceeds
  `max_buffer_size/0`. See `Nous.Providers.HTTP.parse_sse_buffer/1` for
  the documented public entry point.
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
    # Split on the SSE event separator (blank line). Use `:binary.split` with a
    # precompiled pattern instead of a regex: on a large buffer that holds an
    # incomplete event (big tool-call args / thinking block spanning many
    # chunks) this is re-run per chunk, and the Boyer-Moore binary matcher is
    # dramatically cheaper than the regex engine. The two patterns cover the
    # only real SSE separators — `\r\n\r\n` contains no `\n\n` substring, so
    # there is no ambiguous overlap. (A stateful tail-only rescan would also
    # cut the cumulative O(n²), but that needs call-site scan-offset tracking.)
    parts = :binary.split(buffer, ["\r\n\r\n", "\n\n"], [:global])

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
  Parse a single SSE event into a JSON map, `{:stream_done, reason}`,
  `{:parse_error, reason}`, or `nil`.

  See `Nous.Providers.HTTP.parse_sse_event/1` for the documented public
  entry point.
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

  @doc """
  Parse an accumulated stream buffer with the configured parser.

  Non-resumable form; equivalent to `parse_stream_buffer(buffer, mod, nil)`
  with the scan state discarded. Kept for callers that do not thread state.
  """
  @spec parse_stream_buffer(String.t(), module() | nil) :: {list(), String.t()}
  def parse_stream_buffer(buffer, parser_mod) do
    {events, remaining, _scan_state} = parse_stream_buffer(buffer, parser_mod, nil)
    {events, remaining}
  end

  @doc """
  Resumable form of `parse_stream_buffer/2`.

  Returns `{events, remaining_buffer, scan_state}`. Pass the returned
  `scan_state` back on the next chunk. Parsers that do not export
  `parse_buffer/2` always yield `nil`.

  Translates the `{:error, :buffer_overflow}` tuple from
  `parse_sse_buffer/1` into the `{events, buffer}` shape so backends can
  stay agnostic about the failure mode.
  """
  @spec parse_stream_buffer(String.t(), module() | nil, scan_state()) ::
          {list(), String.t(), scan_state()}
  def parse_stream_buffer(buffer, nil, _scan_state) do
    case parse_sse_buffer(buffer) do
      {:error, :buffer_overflow} -> {[{:stream_error, %{reason: :buffer_overflow}}], "", nil}
      {events, remaining} -> {events, remaining, nil}
    end
  end

  def parse_stream_buffer(buffer, parser_mod, scan_state) do
    if resumable?(parser_mod) do
      parser_mod.parse_buffer(buffer, scan_state)
    else
      {events, remaining} = parser_mod.parse_buffer(buffer)
      {events, remaining, nil}
    end
  end

  @doc """
  Flush the remaining buffer at end of stream.

  SSE needs a trailing `\\n\\n` to force the last event through; custom
  parsers just re-parse the remaining buffer as-is.

  The chunk handler already enforces `max_buffer_size/0` on every received
  chunk, so the buffer reaching here is by construction within limits. The
  synthetic `"\\n\\n"` is bookkeeping, not received data — bypass the
  public size check so a buffer at exactly the cap doesn't trip a
  false-positive overflow on the 2-byte append. Only surface overflow if
  the input itself is over.
  """
  @spec flush_stream_buffer(String.t(), module() | nil) :: {list(), String.t()}
  def flush_stream_buffer(buffer, parser_mod) do
    {events, remaining, _scan_state} = flush_stream_buffer(buffer, parser_mod, nil)
    {events, remaining}
  end

  @doc """
  Resumable form of `flush_stream_buffer/2`.
  """
  @spec flush_stream_buffer(String.t(), module() | nil, scan_state()) ::
          {list(), String.t(), scan_state()}
  def flush_stream_buffer(buffer, nil, _scan_state) do
    if byte_size(buffer) > @max_buffer_size do
      {[{:stream_error, %{reason: :buffer_overflow}}], "", nil}
    else
      {events, remaining} = do_parse_sse_buffer(buffer <> "\n\n")
      {events, remaining, nil}
    end
  end

  def flush_stream_buffer(buffer, parser_mod, scan_state) do
    parse_stream_buffer(buffer, parser_mod, scan_state)
  end

  # Probe the optional resumable arity. `function_exported?/3` reports
  # false for a not-yet-loaded module; that is safe — we fall back to the
  # arity-1 call, which loads the module, and the next chunk picks up the
  # resumable path with a fresh (nil) scan state.
  defp resumable?(parser_mod), do: function_exported?(parser_mod, :parse_buffer, 2)

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

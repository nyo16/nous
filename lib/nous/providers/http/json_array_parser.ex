defmodule Nous.Providers.HTTP.JSONArrayParser do
  @moduledoc """
  Stream parser for JSON array responses.

  Parses streaming HTTP responses where the body is a JSON array of objects:

      [{"candidates":[...]},{"candidates":[...]},...]

  Used by providers (like Gemini) that stream responses as a JSON array
  rather than Server-Sent Events. Has the same interface as
  `Nous.Providers.HTTP.parse_sse_buffer/1` so it can be used as a
  drop-in `:stream_parser` for `HTTP.stream/4`.

  ## How it works

  Chunks arrive at arbitrary byte boundaries. The parser accumulates them
  in a buffer, skips array-level syntax (`[`, `]`, `,`, whitespace), and
  extracts complete top-level JSON objects by tracking `{}` nesting depth
  while respecting string literals and escape sequences.
  """

  require Logger

  @doc """
  Parse a buffer containing chunks of a JSON array into individual events.

  Returns `{events, remaining_buffer}` where events is a list of parsed
  JSON maps (same contract as `HTTP.parse_sse_buffer/1`).

  ## Examples

      iex> parse_buffer(~s|[{"text":"hi"},{"text":"there"}]|)
      {[%{"text" => "hi"}, %{"text" => "there"}], ""}

      iex> parse_buffer(~s|[{"text":"hi"},{"tex|)
      {[%{"text" => "hi"}], ~s|{"tex|}

      iex> parse_buffer("")
      {[], ""}
  """
  @spec parse_buffer(String.t()) :: {list(), String.t()}
  def parse_buffer(buffer) when is_binary(buffer) do
    {events, remaining, _scan_state} = parse_buffer(buffer, nil)
    {events, remaining}
  end

  def parse_buffer(_), do: {[], ""}

  @doc """
  Resumable form of `parse_buffer/1`.

  Returns `{events, remaining_buffer, scan_state}`. Pass the returned
  `scan_state` back on the next chunk and the object scan picks up where
  it stopped instead of re-walking the incomplete object from byte 0.

  `scan_state` is `nil` (nothing partially scanned) or the
  `{pos, depth, in_string}` triple the byte walker threads internally.
  It is only valid against a buffer that still carries the already-scanned
  prefix — i.e. the exact `remaining_buffer` returned alongside it, with
  more bytes appended. Anything else falls back to a full rescan.

  This is the optional arity of the `:stream_parser` contract;
  `Nous.HTTP.Buffer` probes for it with `function_exported?/3`. Without it
  a single JSON object spanning n chunks costs O(n²) byte steps — measured
  at 226 ms for one 480 KB object across 342 chunks, 55x the one-shot
  baseline at 240 KB (perf-audit, HIGH).

  ## Examples

      iex> parse_buffer(~s|[{"a":1|, nil)
      {[], ~s|{"a":1|, {6, 1, false}}

      iex> parse_buffer(~s|{"a":1}]|, {6, 1, false})
      {[%{"a" => 1}], "", nil}
  """
  @spec parse_buffer(String.t(), Nous.HTTP.Buffer.scan_state()) ::
          {list(), String.t(), Nous.HTTP.Buffer.scan_state()}
  def parse_buffer(buffer, scan_state) when is_binary(buffer) do
    extract_objects(buffer, [], scan_state)
  end

  def parse_buffer(_, _), do: {[], "", nil}

  # Recursively extract complete JSON objects from the buffer
  defp extract_objects(buffer, acc, scan_state) do
    {trimmed, scan_state} = resume_or_trim(buffer, scan_state)

    case extract_next_object(trimmed, scan_state) do
      {:ok, json_str, rest} ->
        case JSON.decode(json_str) do
          {:ok, parsed} ->
            extract_objects(rest, [parsed | acc], nil)

          {:error, error} ->
            Logger.debug("JSON array parser: failed to decode object: #{inspect(error)}")
            # Don't consume more — the buffer might just need more data
            {Enum.reverse(acc), trimmed, nil}
        end

      {:incomplete, new_scan_state} ->
        {Enum.reverse(acc), trimmed, new_scan_state}
    end
  end

  # ## Why this file never matches on `buffer` with bit syntax
  #
  # The stream backends grow the accumulator with `buffer <> chunk`. ERTS
  # extends such a binary in place — O(chunk) per append — but only while
  # the binary stays *writable*. Starting a bit-syntax match on it (a
  # function head like `<<"{", _::binary>> = buffer`, or walking a
  # `binary_part/3` sub-binary of it) emasculates it, and every later
  # append then copies the whole accumulator: quadratic. Direct A/B over
  # 5000 appends of 1 KB: 1.7 ms untouched, ~1300 ms once matched. The
  # perf audit measured the same shape here as 125 ms of concat vs 11 ms
  # of parse at 1920 KB, 2.68 s at 8 MB (F-3).
  #
  # So: inspect the accumulator only through BIFs (`:binary.at/2`,
  # `binary_part/3`, `byte_size/1`), and hand the byte walker a
  # `:binary.copy/1` of the unscanned tail — one chunk's worth, not the
  # accumulated buffer. Rewriting any of this back into idiomatic binary
  # pattern matching restores the quadratic.

  # A live scan_state means the buffer already starts at the `{` of the
  # object being scanned: there is no array syntax left to skip, and
  # re-trimming would invalidate the recorded offset. Anything else is a
  # stale token from a caller that didn't hand back the buffer we returned
  # — drop it and do a correct (merely slower) full parse.
  defp resume_or_trim(buffer, scan_state) do
    if scan_state != nil and object_start?(buffer) do
      {buffer, scan_state}
    else
      {skip_array_syntax(buffer), nil}
    end
  end

  defp object_start?(buffer), do: byte_size(buffer) > 0 and :binary.at(buffer, 0) == ?{

  # Skip array-level syntax: [ ] , and whitespace between objects
  defp skip_array_syntax(buffer), do: skip_array_syntax(buffer, 0, byte_size(buffer))

  defp skip_array_syntax(buffer, pos, size) when pos < size do
    case :binary.at(buffer, pos) do
      c when c in ~c|[,] \t\n\r| -> skip_array_syntax(buffer, pos + 1, size)
      _ -> drop_prefix(buffer, pos, size)
    end
  end

  defp skip_array_syntax(_buffer, _pos, _size), do: ""

  # Nothing to skip: hand back the accumulator itself rather than a
  # sub-binary of it, so the backend's next append still extends in place.
  defp drop_prefix(buffer, 0, _size), do: buffer
  defp drop_prefix(buffer, pos, size), do: binary_part(buffer, pos, size - pos)

  # Extract the next complete top-level JSON object from the buffer.
  # Only starts extraction when buffer begins with `{`.
  defp extract_next_object(buffer, scan_state) do
    if object_start?(buffer) do
      scan_object(buffer, resume_point(buffer, scan_state))
    else
      {:incomplete, nil}
    end
  end

  defp scan_object(buffer, {pos, depth, in_string}) do
    size = byte_size(buffer)
    tail = :binary.copy(binary_part(buffer, pos, size - pos))

    case find_object_end(tail, pos, depth, in_string) do
      {:ok, end_pos} ->
        {:ok, binary_part(buffer, 0, end_pos), binary_part(buffer, end_pos, size - end_pos)}

      {:incomplete, new_pos, new_depth, new_in_string} ->
        {:incomplete, {new_pos, new_depth, new_in_string}}
    end
  end

  # Backends only ever append to the buffer, so a returned offset stays
  # valid. A caller that hands back a stale token gets a correct (merely
  # slower) full rescan rather than a binary_part/3 ArgumentError.
  defp resume_point(buffer, {pos, depth, in_string})
       when is_integer(pos) and pos >= 0 and pos <= byte_size(buffer) and is_integer(depth) and
              is_boolean(in_string),
       do: {pos, depth, in_string}

  defp resume_point(_buffer, _scan_state), do: {0, 0, false}

  # Walk the buffer byte by byte tracking {} depth.
  # Respects JSON string boundaries and escape sequences.
  #
  # `pos` is an absolute offset into the whole accumulated buffer, so a
  # resumed scan can be handed just the unscanned tail and still report
  # positions the caller can slice the full buffer with.
  #
  # Returns {:ok, end_position} when a complete object is found, or
  # {:incomplete, pos, depth, in_string} — the resume token — when the
  # buffer ends mid-object.

  # Buffer exhausted before object closed
  defp find_object_end(<<>>, pos, depth, in_string), do: {:incomplete, pos, depth, in_string}

  # A lone trailing backslash inside a string: the byte it escapes lives in
  # the next chunk. Stop *before* it so the resumed scan sees the complete
  # two-byte escape. Consuming it here would let `\\` + `"` split across a
  # chunk boundary toggle in_string, which a full rescan never does — and
  # resumed output must be byte-identical to a rescan.
  defp find_object_end(<<"\\">>, pos, depth, true), do: {:incomplete, pos, depth, true}

  # Escaped character inside a string — skip both bytes
  defp find_object_end(<<"\\", _, rest::binary>>, pos, depth, true) do
    find_object_end(rest, pos + 2, depth, true)
  end

  # Quote toggles string state
  defp find_object_end(<<"\"", rest::binary>>, pos, depth, in_string) do
    find_object_end(rest, pos + 1, depth, not in_string)
  end

  # Open brace outside string — increase depth
  defp find_object_end(<<"{", rest::binary>>, pos, depth, false) do
    find_object_end(rest, pos + 1, depth + 1, false)
  end

  # Close brace outside string — decrease depth, check if object complete
  defp find_object_end(<<"}", rest::binary>>, pos, depth, false) do
    case depth - 1 do
      0 -> {:ok, pos + 1}
      new_depth -> find_object_end(rest, pos + 1, new_depth, false)
    end
  end

  # Any other character — advance position
  defp find_object_end(<<_, rest::binary>>, pos, depth, in_string) do
    find_object_end(rest, pos + 1, depth, in_string)
  end
end

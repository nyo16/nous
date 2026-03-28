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
    extract_objects(buffer, [])
  end

  def parse_buffer(_), do: {[], ""}

  # Recursively extract complete JSON objects from the buffer
  defp extract_objects(buffer, acc) do
    trimmed = skip_array_syntax(buffer)

    case extract_next_object(trimmed) do
      {:ok, json_str, rest} ->
        case JSON.decode(json_str) do
          {:ok, parsed} ->
            extract_objects(rest, [parsed | acc])

          {:error, error} ->
            Logger.debug("JSON array parser: failed to decode object: #{inspect(error)}")
            # Don't consume more — the buffer might just need more data
            {Enum.reverse(acc), trimmed}
        end

      :incomplete ->
        {Enum.reverse(acc), trimmed}
    end
  end

  # Skip array-level syntax: [ ] , and whitespace between objects
  defp skip_array_syntax(<<c, rest::binary>>) when c in ~c|[,] \t\n\r|,
    do: skip_array_syntax(rest)

  defp skip_array_syntax(buffer), do: buffer

  # Extract the next complete top-level JSON object from the buffer.
  # Only starts extraction when buffer begins with `{`.
  defp extract_next_object(<<"{", _::binary>> = buffer) do
    case find_object_end(buffer, 0, 0, false) do
      {:ok, end_pos} ->
        <<json::binary-size(^end_pos), rest::binary>> = buffer
        {:ok, json, rest}

      :incomplete ->
        :incomplete
    end
  end

  defp extract_next_object(_), do: :incomplete

  # Walk the buffer character by character tracking {} depth.
  # Respects JSON string boundaries and escape sequences.
  #
  # Returns {:ok, end_position} when a complete object is found,
  # or :incomplete if the buffer ends mid-object.

  # Buffer exhausted before object closed
  defp find_object_end(<<>>, _pos, _depth, _in_string), do: :incomplete

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

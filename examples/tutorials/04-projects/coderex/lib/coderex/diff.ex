defmodule Coderex.Diff do
  @moduledoc """
  Diff construction and application module.

  Supports SEARCH/REPLACE block format for targeted code modifications.

  Format:
      ------- SEARCH
      [exact content to find]
      =======
      [replacement content]
      +++++++ REPLACE

  Ported from Cline's diff.ts implementation.
  """

  # Markers
  @search_block_start "------- SEARCH"
  @search_block_end "======="
  @replace_block_end "+++++++ REPLACE"

  # Regex patterns for flexible matching
  @search_start_regex ~r/^[-]{3,} SEARCH>?$/
  @legacy_search_start_regex ~r/^[<]{3,} SEARCH>?$/
  @search_end_regex ~r/^[=]{3,}$/
  @replace_end_regex ~r/^[+]{3,} REPLACE>?$/
  @legacy_replace_end_regex ~r/^[>]{3,} REPLACE>?$/

  @doc """
  Constructs new file content by applying SEARCH/REPLACE blocks to original content.

  ## Parameters
    - diff_content: String containing SEARCH/REPLACE blocks
    - original_content: The original file content
    - is_final: Whether this is the final chunk (for streaming support)

  ## Returns
    - {:ok, new_content} on success
    - {:error, reason} on failure

  ## Example

      iex> diff = \"\"\"
      ...> ------- SEARCH
      ...> old code
      ...> =======
      ...> new code
      ...> +++++++ REPLACE
      ...> \"\"\"
      iex> Coderex.Diff.construct_new_content(diff, "old code", true)
      {:ok, "new code\\n"}
  """
  def construct_new_content(diff_content, original_content, is_final \\ true) do
    lines = String.split(diff_content, "\n")

    # Remove partial markers at the end (for streaming)
    lines = maybe_remove_partial_marker(lines)

    try do
      {result, replacements, state} =
        Enum.reduce(lines, {"", [], %{
          in_search: false,
          in_replace: false,
          current_search: "",
          current_replace: "",
          search_match_index: -1,
          search_end_index: -1,
          last_processed_index: 0,
          pending_out_of_order: false
        }}, fn line, {result, replacements, state} ->
          process_line(line, result, replacements, state, original_content)
        end)

      # Finalize if this is the last chunk
      if is_final do
        # Handle case where we're still in replace mode
        {replacements, _state} =
          if state.in_replace and state.search_match_index >= 0 do
            replacement = %{
              start: state.search_match_index,
              end: state.search_end_index,
              content: state.current_replace
            }
            {replacements ++ [replacement], %{state | in_replace: false}}
          else
            {replacements, state}
          end

        # Sort and apply all replacements
        final_result = apply_replacements(original_content, Enum.sort_by(replacements, & &1.start))
        {:ok, final_result}
      else
        {:ok, result}
      end
    rescue
      e in RuntimeError -> {:error, e.message}
    end
  end

  defp process_line(line, result, replacements, state, original_content) do
    cond do
      is_search_block_start?(line) ->
        # Start new search block
        new_state = %{state |
          in_search: true,
          current_search: "",
          current_replace: ""
        }
        {result, replacements, new_state}

      is_search_block_end?(line) ->
        # End search, start replace
        {match_index, end_index} = find_search_match(
          state.current_search,
          original_content,
          state.last_processed_index
        )

        pending = match_index < state.last_processed_index

        # Add content up to match (if in order)
        new_result = if not pending and match_index >= 0 do
          result <> String.slice(original_content, state.last_processed_index, match_index - state.last_processed_index)
        else
          result
        end

        new_state = %{state |
          in_search: false,
          in_replace: true,
          search_match_index: match_index,
          search_end_index: end_index,
          pending_out_of_order: pending
        }
        {new_result, replacements, new_state}

      is_replace_block_end?(line) ->
        # Complete the replacement
        if state.search_match_index < 0 do
          raise "The SEARCH block:\n#{String.trim_trailing(state.current_search)}\n...is malformatted."
        end

        replacement = %{
          start: state.search_match_index,
          end: state.search_end_index,
          content: state.current_replace
        }

        new_last_processed = if not state.pending_out_of_order do
          state.search_end_index
        else
          state.last_processed_index
        end

        new_state = %{state |
          in_search: false,
          in_replace: false,
          current_search: "",
          current_replace: "",
          search_match_index: -1,
          search_end_index: -1,
          pending_out_of_order: false,
          last_processed_index: new_last_processed
        }
        {result, replacements ++ [replacement], new_state}

      state.in_search ->
        # Accumulate search content
        new_state = %{state | current_search: state.current_search <> line <> "\n"}
        {result, replacements, new_state}

      state.in_replace ->
        # Accumulate replace content
        new_state = %{state | current_replace: state.current_replace <> line <> "\n"}

        # Output immediately for in-order replacements
        new_result = if state.search_match_index >= 0 and not state.pending_out_of_order do
          result <> line <> "\n"
        else
          result
        end
        {new_result, replacements, new_state}

      true ->
        # Outside any block
        {result, replacements, state}
    end
  end

  defp find_search_match(search_content, original_content, last_processed_index) do
    cond do
      # Empty search = new file or full replacement
      search_content == "" ->
        if original_content == "" do
          {0, 0}
        else
          raise "Empty SEARCH block detected with non-empty file. " <>
                "Please ensure your SEARCH marker follows the correct format."
        end

      # Try exact match first
      (idx = :binary.match(original_content, search_content, [{:scope, {last_processed_index, byte_size(original_content) - last_processed_index}}])) != :nomatch ->
        {elem(idx, 0), elem(idx, 0) + byte_size(search_content)}

      # Try line-trimmed fallback
      (match = line_trimmed_fallback_match(original_content, search_content, last_processed_index)) != nil ->
        match

      # Try block anchor fallback
      (match = block_anchor_fallback_match(original_content, search_content, last_processed_index)) != nil ->
        match

      # Try full file search from beginning
      (idx = :binary.match(original_content, search_content)) != :nomatch ->
        {elem(idx, 0), elem(idx, 0) + byte_size(search_content)}

      true ->
        raise "The SEARCH block:\n#{String.trim_trailing(search_content)}\n...does not match anything in the file."
    end
  end

  @doc """
  Line-trimmed fallback match - ignores leading/trailing whitespace per line.
  """
  def line_trimmed_fallback_match(original_content, search_content, start_index) do
    original_lines = String.split(original_content, "\n")
    search_lines = String.split(search_content, "\n")

    # Remove trailing empty line if exists
    search_lines = if List.last(search_lines) == "", do: Enum.drop(search_lines, -1), else: search_lines
    search_len = length(search_lines)

    # Find starting line number
    {start_line_num, _} = find_line_at_index(original_lines, start_index)

    # Search for matching block
    result = Enum.find_value(start_line_num..(length(original_lines) - search_len), fn i ->
      if lines_match_trimmed?(original_lines, search_lines, i) do
        {start_idx, end_idx} = calculate_char_positions(original_lines, i, search_len)
        {start_idx, end_idx}
      end
    end)

    result
  end

  @doc """
  Block anchor fallback - matches using first and last lines as anchors.
  Only for blocks of 3+ lines.
  """
  def block_anchor_fallback_match(original_content, search_content, start_index) do
    search_lines = String.split(search_content, "\n")
    search_lines = if List.last(search_lines) == "", do: Enum.drop(search_lines, -1), else: search_lines

    # Only use for 3+ line blocks
    if length(search_lines) < 3 do
      nil
    else
      original_lines = String.split(original_content, "\n")
      search_len = length(search_lines)

      first_line_trimmed = String.trim(List.first(search_lines))
      last_line_trimmed = String.trim(List.last(search_lines))

      {start_line_num, _} = find_line_at_index(original_lines, start_index)

      Enum.find_value(start_line_num..(length(original_lines) - search_len), fn i ->
        orig_first = Enum.at(original_lines, i, "") |> String.trim()
        orig_last = Enum.at(original_lines, i + search_len - 1, "") |> String.trim()

        if orig_first == first_line_trimmed and orig_last == last_line_trimmed do
          calculate_char_positions(original_lines, i, search_len)
        end
      end)
    end
  end

  defp find_line_at_index(lines, target_index) do
    Enum.reduce_while(lines, {0, 0}, fn line, {line_num, current_index} ->
      next_index = current_index + byte_size(line) + 1
      if next_index > target_index do
        {:halt, {line_num, current_index}}
      else
        {:cont, {line_num + 1, next_index}}
      end
    end)
  end

  defp lines_match_trimmed?(original_lines, search_lines, start_idx) do
    Enum.zip(0..(length(search_lines) - 1), search_lines)
    |> Enum.all?(fn {offset, search_line} ->
      orig_line = Enum.at(original_lines, start_idx + offset, "")
      String.trim(orig_line) == String.trim(search_line)
    end)
  end

  defp calculate_char_positions(lines, start_line, block_size) do
    # Calculate start character index
    start_idx = Enum.take(lines, start_line)
    |> Enum.reduce(0, fn line, acc -> acc + byte_size(line) + 1 end)

    # Calculate end character index
    end_idx = Enum.slice(lines, start_line, block_size)
    |> Enum.reduce(start_idx, fn line, acc -> acc + byte_size(line) + 1 end)

    {start_idx, end_idx}
  end

  defp apply_replacements(original_content, replacements) do
    original_size = byte_size(original_content)

    {result, _} = Enum.reduce(replacements, {"", 0}, fn replacement, {acc, current_pos} ->
      # Add original content up to this replacement
      start_pos = min(current_pos, original_size)
      end_pos = min(replacement.start, original_size)
      len = max(0, end_pos - start_pos)
      before = if len > 0, do: binary_part(original_content, start_pos, len), else: ""
      # Add replacement content
      new_acc = acc <> before <> replacement.content
      {new_acc, replacement.end}
    end)

    # Add remaining original content
    last_pos = case List.last(replacements) do
      nil -> 0
      r -> min(r.end, original_size)
    end

    remaining_len = max(0, original_size - last_pos)
    remaining = if remaining_len > 0 and last_pos < original_size do
      binary_part(original_content, last_pos, remaining_len)
    else
      ""
    end

    result <> remaining
  end

  defp maybe_remove_partial_marker(lines) do
    case List.last(lines) do
      nil -> lines
      last_line ->
        if looks_like_partial_marker?(last_line) and
           not is_search_block_start?(last_line) and
           not is_search_block_end?(last_line) and
           not is_replace_block_end?(last_line) do
          Enum.drop(lines, -1)
        else
          lines
        end
    end
  end

  defp looks_like_partial_marker?(line) do
    String.starts_with?(line, "-") or
    String.starts_with?(line, "<") or
    String.starts_with?(line, "=") or
    String.starts_with?(line, "+") or
    String.starts_with?(line, ">")
  end

  defp is_search_block_start?(line) do
    Regex.match?(@search_start_regex, line) or Regex.match?(@legacy_search_start_regex, line)
  end

  defp is_search_block_end?(line) do
    Regex.match?(@search_end_regex, line)
  end

  defp is_replace_block_end?(line) do
    Regex.match?(@replace_end_regex, line) or Regex.match?(@legacy_replace_end_regex, line)
  end

  # Utility for creating diff blocks programmatically
  @doc """
  Creates a SEARCH/REPLACE block string.

  ## Example

      iex> Coderex.Diff.make_block("old code", "new code")
      "------- SEARCH\\nold code\\n=======\\nnew code\\n+++++++ REPLACE"
  """
  def make_block(search_content, replace_content) do
    """
    #{@search_block_start}
    #{search_content}
    #{@search_block_end}
    #{replace_content}
    #{@replace_block_end}\
    """
  end
end

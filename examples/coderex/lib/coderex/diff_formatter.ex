defmodule Coderex.DiffFormatter do
  @moduledoc """
  Formats diffs for pretty console output with line numbers and colors.
  """

  # ANSI color codes
  @red "\e[31m"
  @green "\e[32m"
  @cyan "\e[36m"
  @yellow "\e[33m"
  @dim "\e[2m"
  @reset "\e[0m"
  @bold "\e[1m"

  @doc """
  Format a SEARCH/REPLACE diff block for display.

  Shows the old content (in red) and new content (in green) with line numbers.
  """
  def format_diff(path, original_content, new_content, opts \\ []) do
    use_color = Keyword.get(opts, :color, true)
    context_lines = Keyword.get(opts, :context, 3)

    # Compute the actual diff
    old_lines = String.split(original_content, "\n")
    new_lines = String.split(new_content, "\n")

    diff_chunks = compute_diff(old_lines, new_lines)

    # Build formatted output
    header = format_header(path, use_color)
    body = format_chunks(diff_chunks, old_lines, new_lines, context_lines, use_color)

    header <> body
  end

  @doc """
  Format a SEARCH/REPLACE block showing what will be changed.
  """
  def format_search_replace(path, search_content, replace_content, opts \\ []) do
    use_color = Keyword.get(opts, :color, true)

    search_lines = String.split(search_content, "\n")
    replace_lines = String.split(replace_content, "\n")

    header = format_header(path, use_color)

    search_section = format_section("SEARCH", search_lines, :delete, use_color)
    replace_section = format_section("REPLACE", replace_lines, :add, use_color)

    header <> search_section <> separator(use_color) <> replace_section
  end

  @doc """
  Format the result of a file edit operation.
  """
  def format_edit_result(path, original_content, new_content, opts \\ []) do
    use_color = Keyword.get(opts, :color, true)

    old_lines = String.split(original_content, "\n")
    new_lines = String.split(new_content, "\n")

    # Find changed regions
    changes = find_changes(old_lines, new_lines)

    if Enum.empty?(changes) do
      "#{dim("No changes", use_color)}"
    else
      header = format_header(path, use_color)
      body = Enum.map_join(changes, "\n", fn change ->
        format_change(change, old_lines, new_lines, use_color)
      end)

      stats = format_stats(old_lines, new_lines, use_color)

      header <> body <> "\n" <> stats
    end
  end

  # Private functions

  defp format_header(path, use_color) do
    if use_color do
      "\n#{@bold}#{@cyan}━━━ #{path} ━━━#{@reset}\n"
    else
      "\n━━━ #{path} ━━━\n"
    end
  end

  defp separator(use_color) do
    if use_color do
      "#{@dim}───────────────────────────────#{@reset}\n"
    else
      "───────────────────────────────\n"
    end
  end

  defp format_section(label, lines, type, use_color) do
    color = case type do
      :delete -> @red
      :add -> @green
      _ -> ""
    end

    prefix = case type do
      :delete -> "-"
      :add -> "+"
      _ -> " "
    end

    header = if use_color do
      "#{@dim}#{label}:#{@reset}\n"
    else
      "#{label}:\n"
    end

    body = lines
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, num} ->
      line_num = String.pad_leading("#{num}", 4)
      if use_color do
        "#{@dim}#{line_num}#{@reset} #{color}#{prefix} #{line}#{@reset}"
      else
        "#{line_num} #{prefix} #{line}"
      end
    end)

    header <> body <> "\n"
  end

  defp format_change(change, old_lines, new_lines, use_color) do
    case change do
      {:replace, old_start, old_end, new_start, new_end} ->
        old_section = Enum.slice(old_lines, old_start..old_end)
        new_section = Enum.slice(new_lines, new_start..new_end)

        location = if use_color do
          "#{@yellow}@@ -#{old_start + 1},#{old_end - old_start + 1} +#{new_start + 1},#{new_end - new_start + 1} @@#{@reset}"
        else
          "@@ -#{old_start + 1},#{old_end - old_start + 1} +#{new_start + 1},#{new_end - new_start + 1} @@"
        end

        deleted = format_lines(old_section, old_start + 1, :delete, use_color)
        added = format_lines(new_section, new_start + 1, :add, use_color)

        "#{location}\n#{deleted}#{added}"

      {:delete, start_line, end_line} ->
        section = Enum.slice(old_lines, start_line..end_line)
        location = if use_color do
          "#{@yellow}@@ -#{start_line + 1},#{end_line - start_line + 1} @@#{@reset}"
        else
          "@@ -#{start_line + 1},#{end_line - start_line + 1} @@"
        end

        deleted = format_lines(section, start_line + 1, :delete, use_color)
        "#{location}\n#{deleted}"

      {:insert, _line_num, new_start, new_end} ->
        section = Enum.slice(new_lines, new_start..new_end)
        location = if use_color do
          "#{@yellow}@@ +#{new_start + 1},#{new_end - new_start + 1} @@#{@reset}"
        else
          "@@ +#{new_start + 1},#{new_end - new_start + 1} @@"
        end

        added = format_lines(section, new_start + 1, :add, use_color)
        "#{location}\n#{added}"
    end
  end

  defp format_lines(lines, start_num, type, use_color) do
    {color, prefix} = case type do
      :delete -> {@red, "-"}
      :add -> {@green, "+"}
      :context -> {@dim, " "}
    end

    lines
    |> Enum.with_index(start_num)
    |> Enum.map_join("\n", fn {line, num} ->
      line_num = String.pad_leading("#{num}", 4)
      if use_color do
        "#{@dim}#{line_num}#{@reset} #{color}#{prefix} #{line}#{@reset}"
      else
        "#{line_num} #{prefix} #{line}"
      end
    end)
    |> Kernel.<>("\n")
  end

  defp format_stats(old_lines, new_lines, use_color) do
    old_count = length(old_lines)
    new_count = length(new_lines)
    diff = new_count - old_count

    diff_str = cond do
      diff > 0 -> "+#{diff}"
      diff < 0 -> "#{diff}"
      true -> "±0"
    end

    if use_color do
      "#{@dim}Lines: #{old_count} → #{new_count} (#{diff_str})#{@reset}\n"
    else
      "Lines: #{old_count} → #{new_count} (#{diff_str})\n"
    end
  end

  # Simple diff computation using longest common subsequence
  defp compute_diff(old_lines, new_lines) do
    # For simplicity, use a basic approach
    # A more sophisticated implementation would use Myers diff algorithm
    find_changes(old_lines, new_lines)
  end

  defp format_chunks(chunks, old_lines, new_lines, _context_lines, use_color) do
    Enum.map_join(chunks, "\n", fn chunk ->
      format_change(chunk, old_lines, new_lines, use_color)
    end)
  end

  defp find_changes(old_lines, new_lines) do
    old_len = length(old_lines)
    new_len = length(new_lines)

    # Quick check: if both are equal, no changes
    if old_lines == new_lines do
      []
    else
      # Find common prefix (lines that match at the start)
      prefix_len = Enum.zip(old_lines, new_lines)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

      # Find common suffix (lines that match at the end)
      old_remaining = old_len - prefix_len
      new_remaining = new_len - prefix_len

      suffix_len = Enum.zip(
        Enum.reverse(Enum.drop(old_lines, prefix_len)),
        Enum.reverse(Enum.drop(new_lines, prefix_len))
      )
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

      old_end = old_len - suffix_len - 1
      new_end = new_len - suffix_len - 1

      cond do
        # All lines removed from end
        old_remaining > 0 and new_remaining == 0 ->
          [{:delete, prefix_len, old_len - 1}]

        # Lines added at end
        old_remaining == 0 and new_remaining > 0 ->
          [{:insert, prefix_len, prefix_len, new_len - 1}]

        # No actual changes in content
        prefix_len >= old_len and prefix_len >= new_len ->
          []

        # General replacement
        true ->
          [{:replace, prefix_len, max(prefix_len, old_end), prefix_len, max(prefix_len, new_end)}]
      end
    end
  end

  defp dim(text, true), do: "#{@dim}#{text}#{@reset}"
  defp dim(text, false), do: text
end

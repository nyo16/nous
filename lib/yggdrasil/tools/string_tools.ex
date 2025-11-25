defmodule Yggdrasil.Tools.StringTools do
  @moduledoc """
  Built-in tools for string manipulation operations.

  These tools provide common string functionality that AI agents often need:
  - Text transformation (uppercase, lowercase, capitalize)
  - String analysis (length, count occurrences)
  - String operations (replace, split, join, trim)
  - Pattern matching and extraction
  - String validation

  ## Usage

      agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
        tools: [
          &StringTools.string_length/2,
          &StringTools.replace_text/2,
          &StringTools.split_text/2
        ]
      )

      {:ok, result} = Yggdrasil.run(agent, "How many characters in 'Hello World'?")
  """

  @doc """
  Get the length of a string.

  ## Arguments

  - text: The string to measure
  """
  def string_length(_ctx, args) do
    text = Map.get(args, "text", "")

    %{
      text: text,
      length: String.length(text),
      byte_size: byte_size(text),
      grapheme_count: String.length(text)
    }
  end

  @doc """
  Replace all occurrences of a pattern in a string.

  ## Arguments

  - text: The original text
  - pattern: The text to find
  - replacement: The text to replace with
  - case_sensitive: Whether to match case (default: true)
  """
  def replace_text(_ctx, args) do
    text = Map.get(args, "text", "")
    # Support multiple parameter names
    pattern = Map.get(args, "pattern") || Map.get(args, "old") || ""
    replacement = Map.get(args, "replacement") || Map.get(args, "new") || ""
    case_sensitive = Map.get(args, "case_sensitive", true)

    result = if case_sensitive do
      String.replace(text, pattern, replacement)
    else
      # Case-insensitive replacement
      regex = Regex.compile!(Regex.escape(pattern), "i")
      Regex.replace(regex, text, replacement)
    end

    count = if case_sensitive do
      (String.length(text) - String.length(String.replace(text, pattern, "")))
      |> div(max(String.length(pattern), 1))
    else
      regex = Regex.compile!(Regex.escape(pattern), "i")
      length(Regex.scan(regex, text))
    end

    %{
      original: text,
      pattern: pattern,
      replacement: replacement,
      result: result,
      replacements_made: count,
      case_sensitive: case_sensitive
    }
  end

  @doc """
  Split a string into parts based on a delimiter.

  ## Arguments

  - text: The text to split
  - delimiter: The delimiter to split on (default: " ")
  - trim: Whether to trim whitespace from parts (default: false)
  - remove_empty: Whether to remove empty strings (default: false)
  """
  def split_text(_ctx, args) do
    text = Map.get(args, "text", "")
    # Support multiple parameter names
    delimiter = Map.get(args, "delimiter") || Map.get(args, "separator") || " "
    trim = Map.get(args, "trim", false)
    remove_empty = Map.get(args, "remove_empty", false)

    parts = String.split(text, delimiter)

    parts = if trim do
      Enum.map(parts, &String.trim/1)
    else
      parts
    end

    parts = if remove_empty do
      Enum.reject(parts, &(&1 == ""))
    else
      parts
    end

    %{
      original: text,
      delimiter: delimiter,
      parts: parts,
      count: length(parts),
      trim: trim,
      remove_empty: remove_empty
    }
  end

  @doc """
  Join a list of strings with a delimiter.

  ## Arguments

  - parts: List of strings to join (comma-separated string)
  - delimiter: The delimiter to use (default: " ")
  """
  def join_text(_ctx, args) do
    # Support both array and comma-separated string
    parts = case Map.get(args, "parts") do
      list when is_list(list) -> list
      string when is_binary(string) -> String.split(string, ",")
      _ -> []
    end

    delimiter = Map.get(args, "delimiter", " ")

    result = Enum.join(parts, delimiter)

    %{
      parts: parts,
      delimiter: delimiter,
      result: result,
      length: String.length(result)
    }
  end

  @doc """
  Count occurrences of a substring in a string.

  ## Arguments

  - text: The text to search in
  - pattern: The pattern to count
  - case_sensitive: Whether to match case (default: true)
  """
  def count_occurrences(_ctx, args) do
    text = Map.get(args, "text", "")
    # Support multiple parameter names
    pattern = Map.get(args, "pattern") || Map.get(args, "substring") || ""
    case_sensitive = Map.get(args, "case_sensitive", true)

    count = if case_sensitive do
      if pattern == "" do
        0
      else
        (String.length(text) - String.length(String.replace(text, pattern, "")))
        |> div(String.length(pattern))
      end
    else
      if pattern == "" do
        0
      else
        regex = Regex.compile!(Regex.escape(pattern), "i")
        length(Regex.scan(regex, text))
      end
    end

    %{
      text: text,
      pattern: pattern,
      count: count,
      case_sensitive: case_sensitive
    }
  end

  @doc """
  Convert text to uppercase.

  ## Arguments

  - text: The text to convert
  """
  def to_uppercase(_ctx, args) do
    text = Map.get(args, "text", "")

    %{
      original: text,
      result: String.upcase(text)
    }
  end

  @doc """
  Convert text to lowercase.

  ## Arguments

  - text: The text to convert
  """
  def to_lowercase(_ctx, args) do
    text = Map.get(args, "text", "")

    %{
      original: text,
      result: String.downcase(text)
    }
  end

  @doc """
  Capitalize the first letter of each word.

  ## Arguments

  - text: The text to capitalize
  - mode: "first" (first letter only), "words" (each word), "sentences" (each sentence)
  """
  def capitalize_text(_ctx, args) do
    text = Map.get(args, "text", "")
    mode = Map.get(args, "mode", "words")

    result = case mode do
      "first" ->
        String.capitalize(text)

      "words" ->
        text
        |> String.split()
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(" ")

      "sentences" ->
        text
        |> String.split(". ")
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(". ")

      _ ->
        String.capitalize(text)
    end

    %{
      original: text,
      mode: mode,
      result: result
    }
  end

  @doc """
  Trim whitespace from a string.

  ## Arguments

  - text: The text to trim
  - side: "both" (default), "left", "right"
  """
  def trim_text(_ctx, args) do
    text = Map.get(args, "text", "")
    side = Map.get(args, "side", "both")

    result = case side do
      "left" -> String.trim_leading(text)
      "right" -> String.trim_trailing(text)
      _ -> String.trim(text)
    end

    %{
      original: text,
      side: side,
      result: result,
      chars_removed: String.length(text) - String.length(result)
    }
  end

  @doc """
  Extract a substring from a string.

  ## Arguments

  - text: The original text
  - start: Starting position (0-indexed)
  - length: Number of characters to extract (optional, extracts to end if not provided)
  """
  def substring(_ctx, args) do
    text = Map.get(args, "text", "")
    start = Map.get(args, "start", 0)
    # Support "length" or "end" parameter
    length = Map.get(args, "length") ||
             (Map.get(args, "end") && Map.get(args, "end") - start + 1)

    result = if length do
      String.slice(text, start, length)
    else
      String.slice(text, start..-1//1)
    end

    %{
      original: text,
      start: start,
      length: length,
      result: result
    }
  end

  @doc """
  Check if a string contains a substring.

  ## Arguments

  - text: The text to search in
  - pattern: The pattern to search for
  - case_sensitive: Whether to match case (default: true)
  """
  def contains(_ctx, args) do
    text = Map.get(args, "text", "")
    # Support multiple parameter names
    pattern = Map.get(args, "pattern") || Map.get(args, "substring") || ""
    case_sensitive = Map.get(args, "case_sensitive", true)

    contains = if case_sensitive do
      String.contains?(text, pattern)
    else
      String.downcase(text) |> String.contains?(String.downcase(pattern))
    end

    %{
      text: text,
      pattern: pattern,
      contains: contains,
      case_sensitive: case_sensitive
    }
  end

  @doc """
  Check if a string starts with a prefix.

  ## Arguments

  - text: The text to check
  - prefix: The prefix to check for
  - case_sensitive: Whether to match case (default: true)
  """
  def starts_with(_ctx, args) do
    text = Map.get(args, "text", "")
    prefix = Map.get(args, "prefix", "")
    case_sensitive = Map.get(args, "case_sensitive", true)

    starts = if case_sensitive do
      String.starts_with?(text, prefix)
    else
      String.downcase(text) |> String.starts_with?(String.downcase(prefix))
    end

    %{
      text: text,
      prefix: prefix,
      starts_with: starts,
      case_sensitive: case_sensitive
    }
  end

  @doc """
  Check if a string ends with a suffix.

  ## Arguments

  - text: The text to check
  - suffix: The suffix to check for
  - case_sensitive: Whether to match case (default: true)
  """
  def ends_with(_ctx, args) do
    text = Map.get(args, "text", "")
    suffix = Map.get(args, "suffix", "")
    case_sensitive = Map.get(args, "case_sensitive", true)

    ends = if case_sensitive do
      String.ends_with?(text, suffix)
    else
      String.downcase(text) |> String.ends_with?(String.downcase(suffix))
    end

    %{
      text: text,
      suffix: suffix,
      ends_with: ends,
      case_sensitive: case_sensitive
    }
  end

  @doc """
  Reverse a string.

  ## Arguments

  - text: The text to reverse
  """
  def reverse_text(_ctx, args) do
    text = Map.get(args, "text", "")

    result = text
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.join()

    %{
      original: text,
      result: result
    }
  end

  @doc """
  Repeat a string N times.

  ## Arguments

  - text: The text to repeat
  - times: Number of times to repeat (max 100)
  """
  def repeat_text(_ctx, args) do
    text = Map.get(args, "text", "")
    times = Map.get(args, "times", 1) |> min(100)  # Limit to prevent abuse

    result = String.duplicate(text, times)

    %{
      original: text,
      times: times,
      result: result,
      result_length: String.length(result)
    }
  end

  @doc """
  Extract words from a string.

  ## Arguments

  - text: The text to extract words from
  - min_length: Minimum word length (default: 1)
  """
  def extract_words(_ctx, args) do
    text = Map.get(args, "text", "")
    min_length = Map.get(args, "min_length", 1)

    words = text
    |> String.split(~r/\W+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= min_length))

    %{
      text: text,
      words: words,
      word_count: length(words),
      min_length: min_length,
      unique_words: Enum.uniq(words) |> length()
    }
  end

  @doc """
  Pad a string to a specific length.

  ## Arguments

  - text: The text to pad
  - length: Target length
  - padding: Character to pad with (default: " ")
  - side: "left", "right", or "both" (default: "right")
  """
  def pad_text(_ctx, args) do
    text = Map.get(args, "text", "")
    target_length = Map.get(args, "length", String.length(text))
    padding = Map.get(args, "padding", " ")
    side = Map.get(args, "side", "right")

    result = case side do
      "left" -> String.pad_leading(text, target_length, padding)
      "right" -> String.pad_trailing(text, target_length, padding)
      "both" ->
        diff = target_length - String.length(text)
        left_pad = div(diff, 2)
        text
        |> String.pad_leading(String.length(text) + left_pad, padding)
        |> String.pad_trailing(target_length, padding)
      _ -> String.pad_trailing(text, target_length, padding)
    end

    %{
      original: text,
      target_length: target_length,
      result: result,
      result_length: String.length(result)
    }
  end

  @doc """
  Check if a string is a palindrome.

  ## Arguments

  - text: The text to check
  - ignore_case: Whether to ignore case (default: true)
  - ignore_spaces: Whether to ignore spaces (default: true)
  """
  def is_palindrome(_ctx, args) do
    text = Map.get(args, "text", "")
    ignore_case = Map.get(args, "ignore_case", true)
    ignore_spaces = Map.get(args, "ignore_spaces", true)

    processed = text
    processed = if ignore_case, do: String.downcase(processed), else: processed
    processed = if ignore_spaces, do: String.replace(processed, " ", ""), else: processed

    reversed = processed
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.join()

    is_palindrome = processed == reversed

    %{
      text: text,
      is_palindrome: is_palindrome,
      processed_text: processed,
      ignore_case: ignore_case,
      ignore_spaces: ignore_spaces
    }
  end

  @doc """
  Extract numbers from a string.

  ## Arguments

  - text: The text to extract numbers from
  """
  def extract_numbers(_ctx, args) do
    text = Map.get(args, "text", "")

    # Find all numbers (including decimals)
    numbers = Regex.scan(~r/-?\d+\.?\d*/, text)
    |> Enum.map(fn [num] -> num end)

    parsed_numbers = Enum.map(numbers, fn num ->
      case Float.parse(num) do
        {value, _} -> value
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    %{
      text: text,
      numbers_found: numbers,
      parsed_numbers: parsed_numbers,
      count: length(numbers),
      sum: Enum.sum(parsed_numbers)
    }
  end
end

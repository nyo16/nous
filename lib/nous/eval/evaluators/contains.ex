defmodule Nous.Eval.Evaluators.Contains do
  @moduledoc """
  Evaluator that checks if output contains expected substrings or patterns.

  ## Expected Format

  The expected value can be:
  - A list of strings: `["word1", "word2"]`
  - A map with `:contains` key: `%{contains: ["word1", "word2"]}`
  - A map with `:contains_any` key: `%{contains_any: ["word1", "word2"]}`
  - A map with `:regex` key: `%{regex: ["pattern1", "pattern2"]}`

  ## Configuration

    * `:case_insensitive` - Ignore case (default: true)
    * `:match_all` - Require all items to match (default: true for :contains)

  ## Examples

      # Must contain all words
      TestCase.new(
        id: "contains_all",
        input: "What's the weather in Tokyo?",
        expected: %{contains: ["weather", "Tokyo"]},
        eval_type: :contains
      )

      # Must contain any word
      TestCase.new(
        id: "contains_any",
        input: "Say hello",
        expected: %{contains_any: ["hello", "hi", "hey"]},
        eval_type: :contains
      )

      # Regex patterns
      TestCase.new(
        id: "regex",
        input: "What is 25*4?",
        expected: %{regex: ["\\\\d+"]},
        eval_type: :contains
      )

  """

  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    # Handle map with :output key from runner, or raw string
    actual_str =
      case actual do
        %{output: output} when is_binary(output) -> output
        %{output: nil} -> ""
        str when is_binary(str) -> str
        _ -> ""
      end

    {mode, patterns} = parse_expected(expected)

    case mode do
      :contains_all -> check_all(actual_str, patterns, config)
      :contains_any -> check_any(actual_str, patterns, config)
      :regex -> check_regex(actual_str, patterns, config)
    end
  end

  @impl true
  def name, do: "Contains"

  defp parse_expected(expected) when is_list(expected), do: {:contains_all, expected}

  defp parse_expected(%{contains: patterns}), do: {:contains_all, patterns}
  defp parse_expected(%{"contains" => patterns}), do: {:contains_all, patterns}

  defp parse_expected(%{contains_any: patterns}), do: {:contains_any, patterns}
  defp parse_expected(%{"contains_any" => patterns}), do: {:contains_any, patterns}

  defp parse_expected(%{regex: patterns}), do: {:regex, patterns}
  defp parse_expected(%{"regex" => patterns}), do: {:regex, patterns}

  defp parse_expected(expected) when is_binary(expected), do: {:contains_all, [expected]}

  defp parse_expected(_), do: {:contains_all, []}

  defp check_all(actual, patterns, config) do
    case_insensitive = Map.get(config, :case_insensitive, true)
    actual_normalized = if case_insensitive, do: String.downcase(actual), else: actual

    results =
      Enum.map(patterns, fn pattern ->
        pattern_normalized = if case_insensitive, do: String.downcase(pattern), else: pattern
        {pattern, String.contains?(actual_normalized, pattern_normalized)}
      end)

    matched = Enum.filter(results, fn {_, found} -> found end)
    missing = Enum.reject(results, fn {_, found} -> found end) |> Enum.map(&elem(&1, 0))

    score = if patterns == [], do: 1.0, else: length(matched) / length(patterns)

    if missing == [] do
      %{
        score: score,
        passed: true,
        reason: nil,
        details: %{matched: Enum.map(matched, &elem(&1, 0)), mode: :contains_all}
      }
    else
      %{
        score: score,
        passed: false,
        reason: "Missing expected content: #{inspect(missing)}",
        details: %{
          matched: Enum.map(matched, &elem(&1, 0)),
          missing: missing,
          mode: :contains_all
        }
      }
    end
  end

  defp check_any(actual, patterns, config) do
    case_insensitive = Map.get(config, :case_insensitive, true)
    actual_normalized = if case_insensitive, do: String.downcase(actual), else: actual

    matched =
      Enum.filter(patterns, fn pattern ->
        pattern_normalized = if case_insensitive, do: String.downcase(pattern), else: pattern
        String.contains?(actual_normalized, pattern_normalized)
      end)

    if matched != [] do
      %{
        score: 1.0,
        passed: true,
        reason: nil,
        details: %{matched: matched, mode: :contains_any}
      }
    else
      %{
        score: 0.0,
        passed: false,
        reason: "None of the expected patterns found",
        details: %{expected: patterns, mode: :contains_any}
      }
    end
  end

  defp check_regex(actual, patterns, config) do
    case_insensitive = Map.get(config, :case_insensitive, true)
    opts = if case_insensitive, do: [:caseless], else: []

    results =
      Enum.map(patterns, fn pattern ->
        case Regex.compile(pattern, opts) do
          {:ok, regex} -> {pattern, Regex.match?(regex, actual)}
          {:error, _} -> {pattern, false}
        end
      end)

    matched = Enum.filter(results, fn {_, found} -> found end)
    missing = Enum.reject(results, fn {_, found} -> found end) |> Enum.map(&elem(&1, 0))

    score = if patterns == [], do: 1.0, else: length(matched) / length(patterns)

    if missing == [] do
      %{
        score: score,
        passed: true,
        reason: nil,
        details: %{matched: Enum.map(matched, &elem(&1, 0)), mode: :regex}
      }
    else
      %{
        score: score,
        passed: false,
        reason: "Missing regex patterns: #{inspect(missing)}",
        details: %{
          matched: Enum.map(matched, &elem(&1, 0)),
          missing: missing,
          mode: :regex
        }
      }
    end
  end
end

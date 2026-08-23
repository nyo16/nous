defmodule Nous.Eval.Evaluators.FuzzyMatch do
  @moduledoc """
  Evaluator that uses string similarity for matching.

  Uses Levenshtein distance to calculate similarity between strings.

  ## Configuration

    * `:threshold` - Minimum similarity (0.0 to 1.0, default: 0.8)
    * `:normalize` - Normalize strings before comparison (default: true)
    * `:case_insensitive` - Ignore case (default: true)

  ## Examples

      TestCase.new(
        id: "fuzzy",
        input: "What is the capital of France?",
        expected: "Paris is the capital of France",
        eval_type: :fuzzy_match,
        eval_config: %{threshold: 0.7}
      )

  """

  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    threshold = Map.get(config, :threshold, 0.8)

    # Handle map with :output key from runner, or raw string
    actual_str =
      case actual do
        %{output: output} when is_binary(output) -> normalize(output, config)
        %{output: nil} -> ""
        str when is_binary(str) -> normalize(str, config)
        _ -> ""
      end

    expected_str = normalize(to_string(expected), config)

    similarity = calculate_similarity(actual_str, expected_str)

    if similarity >= threshold do
      %{
        score: similarity,
        passed: true,
        reason: nil,
        details: %{
          similarity: Float.round(similarity, 4),
          threshold: threshold,
          actual: actual_str,
          expected: expected_str
        }
      }
    else
      %{
        score: similarity,
        passed: false,
        reason: "Similarity #{Float.round(similarity, 2)} below threshold #{threshold}",
        details: %{
          similarity: Float.round(similarity, 4),
          threshold: threshold,
          actual: actual_str,
          expected: expected_str
        }
      }
    end
  end

  @impl true
  def name, do: "Fuzzy Match"

  @doc """
  Calculate similarity between two strings using Levenshtein distance.

  Returns a value between 0.0 (completely different) and 1.0 (identical).
  """
  @spec calculate_similarity(String.t(), String.t()) :: float()
  def calculate_similarity("", ""), do: 1.0
  def calculate_similarity("", _), do: 0.0
  def calculate_similarity(_, ""), do: 0.0

  def calculate_similarity(s1, s2) do
    distance = levenshtein_distance(s1, s2)
    max_len = max(String.length(s1), String.length(s2))
    similarity = 1.0 - distance / max_len

    # The DP already bounds distance by max_len; clamping makes the documented
    # 0.0-1.0 contract structural rather than something callers must trust.
    similarity |> max(0.0) |> min(1.0)
  end

  @doc """
  Calculate the Levenshtein distance between two strings.

  Distance is counted in graphemes, not bytes, so a multi-byte character or a
  combining sequence costs a single edit.
  """
  @spec levenshtein_distance(String.t(), String.t()) :: non_neg_integer()
  def levenshtein_distance(s1, s2) when s1 == s2, do: 0

  def levenshtein_distance(s1, s2) do
    s2_chars = String.graphemes(s2)

    # Two-row DP. prev_row[0] is always the row index, so every row seeds itself
    # and no separate counter has to be threaded through the fold.
    initial_row = Enum.to_list(0..length(s2_chars))

    s1
    |> String.graphemes()
    |> Enum.reduce(initial_row, &next_row(&1, &2, s2_chars))
    |> List.last()
  end

  # d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + cost): deletion,
  # insertion, substitution. prev_row is consumed head-first, so the diagonal is
  # just the cell dropped on the previous step - never an Enum.at/2 list scan.
  defp next_row(c1, [row_index | prev_tail], s2_chars) do
    initial = {[row_index + 1], prev_tail, row_index}

    {row_reversed, _prev_tail, _diagonal} =
      Enum.reduce(s2_chars, initial, fn c2, {acc, [above | rest], diagonal} ->
        cost = if c1 == c2, do: 0, else: 1
        value = min(min(above + 1, hd(acc) + 1), diagonal + cost)
        {[value | acc], rest, above}
      end)

    Enum.reverse(row_reversed)
  end

  defp normalize(str, config) do
    str
    |> String.trim()
    |> maybe_downcase(config)
    |> maybe_normalize_whitespace(config)
  end

  defp maybe_downcase(str, config) do
    if Map.get(config, :case_insensitive, true), do: String.downcase(str), else: str
  end

  defp maybe_normalize_whitespace(str, config) do
    if Map.get(config, :normalize, true) do
      str
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      str
    end
  end
end

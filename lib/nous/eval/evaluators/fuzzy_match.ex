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
    1.0 - distance / max_len
  end

  @doc """
  Calculate the Levenshtein distance between two strings.
  """
  @spec levenshtein_distance(String.t(), String.t()) :: non_neg_integer()
  def levenshtein_distance(s1, s2) do
    s1_chars = String.graphemes(s1)
    s2_chars = String.graphemes(s2)
    s2_len = length(s2_chars)

    # Initialize first row
    row = Enum.to_list(0..s2_len)

    # Process each character in s1
    {final_row, _} =
      Enum.reduce(Enum.with_index(s1_chars), {row, 0}, fn {c1, i}, {prev_row, _} ->
        # Start with deletion cost
        first = i + 1

        # Process each character in s2
        {new_row, _} =
          Enum.reduce(Enum.with_index(s2_chars), {[first], first}, fn {c2, j}, {acc, prev_diag} ->
            prev = Enum.at(prev_row, j + 1)
            current = hd(acc)

            cost = if c1 == c2, do: 0, else: 1

            min_val =
              Enum.min([
                prev + 1,
                current + 1,
                prev_diag + cost
              ])

            {[min_val | acc], Enum.at(prev_row, j)}
          end)

        {Enum.reverse(new_row), i + 1}
      end)

    List.last(final_row)
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

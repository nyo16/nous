defmodule Nous.Eval.Evaluators.ExactMatch do
  @moduledoc """
  Evaluator that requires exact string match.

  ## Configuration

    * `:normalize` - Normalize strings before comparison (default: false)
    * `:trim` - Trim whitespace (default: true)
    * `:case_insensitive` - Ignore case (default: false)

  ## Examples

      # Basic exact match
      TestCase.new(
        id: "exact",
        input: "What is 2+2?",
        expected: "4",
        eval_type: :exact_match
      )

      # Case insensitive
      TestCase.new(
        id: "exact_ci",
        input: "What is the capital?",
        expected: "Paris",
        eval_type: :exact_match,
        eval_config: %{case_insensitive: true}
      )

  """

  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    # Handle map with :output key from runner, or raw string
    actual_str =
      case actual do
        %{output: output} when is_binary(output) -> normalize(output, config)
        %{output: nil} -> ""
        str when is_binary(str) -> normalize(str, config)
        _ -> ""
      end

    expected_str = normalize(to_string(expected), config)

    if actual_str == expected_str do
      %{
        score: 1.0,
        passed: true,
        reason: nil,
        details: %{actual: actual_str, expected: expected_str}
      }
    else
      %{
        score: 0.0,
        passed: false,
        reason: "Output does not exactly match expected",
        details: %{actual: actual_str, expected: expected_str}
      }
    end
  end

  @impl true
  def name, do: "Exact Match"

  defp normalize(str, config) do
    str
    |> maybe_trim(config)
    |> maybe_downcase(config)
    |> maybe_normalize_whitespace(config)
  end

  defp maybe_trim(str, config) do
    if Map.get(config, :trim, true), do: String.trim(str), else: str
  end

  defp maybe_downcase(str, config) do
    if Map.get(config, :case_insensitive, false), do: String.downcase(str), else: str
  end

  defp maybe_normalize_whitespace(str, config) do
    if Map.get(config, :normalize, false) do
      str
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      str
    end
  end
end

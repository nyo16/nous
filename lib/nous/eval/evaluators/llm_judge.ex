defmodule Nous.Eval.Evaluators.LLMJudge do
  @moduledoc """
  Evaluator that uses an LLM to judge output quality.

  This evaluator is useful when:
  - Expected output is subjective
  - Multiple valid answers exist
  - Complex reasoning is needed to evaluate

  ## Expected Format

      %{
        criteria: "Is the response helpful, accurate, and well-formatted?",
        rubric: "5: Excellent, 4: Good, 3: Average, 2: Poor, 1: Very Poor"
      }

  ## Configuration

    * `:judge_model` - Model to use for judging (default: from suite or config)
    * `:criteria` - Evaluation criteria
    * `:rubric` - Scoring rubric
    * `:pass_threshold` - Minimum score to pass (default: 0.6)
    * `:reference_answer` - Optional reference answer for comparison

  ## Examples

      TestCase.new(
        id: "quality_check",
        input: "Explain recursion",
        expected: %{
          criteria: "Is the explanation clear, accurate, and uses good examples?",
          rubric: "5: Excellent explanation with clear examples, 3: Adequate, 1: Poor"
        },
        eval_type: :llm_judge,
        eval_config: %{
          judge_model: "lmstudio:ministral-3-14b-reasoning",
          pass_threshold: 0.6
        }
      )

  """

  @behaviour Nous.Eval.Evaluator

  @default_rubric """
  Score from 1-5:
  5: Excellent - Complete, accurate, well-structured
  4: Good - Mostly complete and accurate, minor issues
  3: Average - Partially correct, some important aspects missing
  2: Poor - Significant issues or inaccuracies
  1: Very Poor - Completely wrong or irrelevant
  """

  @impl true
  def evaluate(actual, expected, config) do
    judge_model = Map.get(config, :judge_model) || get_default_model()
    pass_threshold = Map.get(config, :pass_threshold, 0.6)

    {criteria, rubric, reference} = parse_expected(expected, config)

    if is_nil(judge_model) do
      %{
        score: 0.0,
        passed: false,
        reason: "No judge model configured",
        details: %{}
      }
    else
      run_evaluation(actual, criteria, rubric, reference, judge_model, pass_threshold)
    end
  end

  @impl true
  def name, do: "LLM Judge"

  defp parse_expected(expected, config) when is_map(expected) do
    criteria =
      Map.get(expected, :criteria) ||
        Map.get(expected, "criteria") ||
        Map.get(config, :criteria, "Evaluate the quality and correctness of the response.")

    rubric =
      Map.get(expected, :rubric) ||
        Map.get(expected, "rubric") ||
        Map.get(config, :rubric, @default_rubric)

    reference =
      Map.get(expected, :reference_answer) ||
        Map.get(expected, "reference_answer") ||
        Map.get(config, :reference_answer)

    {criteria, rubric, reference}
  end

  defp parse_expected(expected, config) when is_binary(expected) do
    # String expected is treated as criteria
    rubric = Map.get(config, :rubric, @default_rubric)
    {expected, rubric, nil}
  end

  defp parse_expected(_, config) do
    criteria = Map.get(config, :criteria, "Evaluate the quality and correctness of the response.")
    rubric = Map.get(config, :rubric, @default_rubric)
    {criteria, rubric, nil}
  end

  defp run_evaluation(actual, criteria, rubric, reference, judge_model, pass_threshold) do
    actual_output = extract_output(actual)

    prompt = build_judge_prompt(actual_output, criteria, rubric, reference)

    case Nous.generate_text(judge_model, prompt, system: judge_system_prompt()) do
      {:ok, response} ->
        parse_judge_response(response, pass_threshold, actual_output)

      {:error, reason} ->
        %{
          score: 0.0,
          passed: false,
          reason: "LLM judge failed: #{inspect(reason)}",
          details: %{error: reason}
        }
    end
  end

  defp extract_output(actual) when is_map(actual) do
    cond do
      Map.has_key?(actual, :output) -> to_string(actual.output)
      Map.has_key?(actual, :agent_result) -> extract_output(actual.agent_result)
      true -> inspect(actual)
    end
  end

  defp extract_output(actual), do: to_string(actual)

  defp judge_system_prompt do
    """
    You are an expert evaluator. Your task is to evaluate AI-generated responses based on given criteria.
    Always provide:
    1. A score from 1-5 (or as specified in the rubric)
    2. A brief explanation of your scoring

    Format your response exactly as:
    SCORE: [number]
    EXPLANATION: [your explanation]
    """
  end

  defp build_judge_prompt(output, criteria, rubric, reference) do
    base = """
    Evaluate the following response:

    RESPONSE:
    #{output}

    CRITERIA:
    #{criteria}

    SCORING RUBRIC:
    #{rubric}
    """

    if reference do
      base <>
        """

        REFERENCE ANSWER (for comparison):
        #{reference}
        """
    else
      base
    end
  end

  defp parse_judge_response(response, pass_threshold, actual_output) do
    # Try to extract score from response
    score_regex = ~r/SCORE:\s*(\d+(?:\.\d+)?)/i

    case Regex.run(score_regex, response) do
      [_, score_str] ->
        score = parse_score(score_str)
        normalized_score = normalize_score(score)
        passed = normalized_score >= pass_threshold

        explanation = extract_explanation(response)

        %{
          score: normalized_score,
          passed: passed,
          reason:
            if(not passed, do: "Score #{normalized_score} below threshold #{pass_threshold}"),
          details: %{
            raw_score: score,
            explanation: explanation,
            judge_response: response,
            actual_output: actual_output
          }
        }

      nil ->
        # Try to find any number in the response
        fallback_score = extract_fallback_score(response)

        if fallback_score do
          normalized_score = normalize_score(fallback_score)
          passed = normalized_score >= pass_threshold

          %{
            score: normalized_score,
            passed: passed,
            reason: if(not passed, do: "Score below threshold"),
            details: %{
              raw_score: fallback_score,
              judge_response: response,
              parse_method: :fallback
            }
          }
        else
          %{
            score: 0.0,
            passed: false,
            reason: "Could not parse score from judge response",
            details: %{judge_response: response}
          }
        end
    end
  end

  defp parse_score(score_str) do
    case Float.parse(score_str) do
      {score, _} -> score
      :error -> 0.0
    end
  end

  defp normalize_score(score) when score >= 0 and score <= 1, do: score

  defp normalize_score(score) when score >= 1 and score <= 5 do
    # Convert 1-5 scale to 0-1
    (score - 1) / 4
  end

  defp normalize_score(score) when score >= 1 and score <= 10 do
    # Convert 1-10 scale to 0-1
    (score - 1) / 9
  end

  defp normalize_score(score) when score > 10 and score <= 100 do
    # Assume percentage
    score / 100
  end

  defp normalize_score(_), do: 0.0

  defp extract_explanation(response) do
    case Regex.run(~r/EXPLANATION:\s*(.+)/is, response) do
      [_, explanation] -> String.trim(explanation)
      nil -> nil
    end
  end

  defp extract_fallback_score(response) do
    case Regex.run(~r/\b(\d+(?:\.\d+)?)\s*(?:\/\s*(?:5|10|100))?\b/, response) do
      [_, score_str | _] -> parse_score(score_str)
      nil -> nil
    end
  end

  defp get_default_model do
    Nous.Eval.Config.get().default_model
  end
end

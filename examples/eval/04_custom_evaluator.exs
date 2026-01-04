# Custom Evaluator Example
#
# This example shows how to create and use custom evaluators
# for specialized evaluation needs.
#
# Run with: mix run examples/eval/04_custom_evaluator.exs

alias Nous.Eval
alias Nous.Eval.{TestCase, Suite, Reporter}

# Define a custom evaluator that checks response structure
defmodule ResponseStructureEvaluator do
  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, _config) do
    output = case actual do
      %{output: o} when is_binary(o) -> o
      s when is_binary(s) -> s
      _ -> ""
    end

    checks = []

    # Check word count if specified
    checks = if expected[:min_words] do
      word_count = output |> String.split(~r/\s+/, trim: true) |> length()
      passed = word_count >= expected.min_words
      [{:min_words, passed, "Word count: #{word_count} (min: #{expected.min_words})"} | checks]
    else
      checks
    end

    # Check max words if specified
    checks = if expected[:max_words] do
      word_count = output |> String.split(~r/\s+/, trim: true) |> length()
      passed = word_count <= expected.max_words
      [{:max_words, passed, "Word count: #{word_count} (max: #{expected.max_words})"} | checks]
    else
      checks
    end

    # Check sentence count if specified
    checks = if expected[:min_sentences] do
      sentence_count = output |> String.split(~r/[.!?]+/, trim: true) |> length()
      passed = sentence_count >= expected.min_sentences
      [{:min_sentences, passed, "Sentence count: #{sentence_count} (min: #{expected.min_sentences})"} | checks]
    else
      checks
    end

    # Check for bullet points if specified
    checks = if expected[:has_bullets] do
      has_bullets = String.contains?(output, ["- ", "* ", "• "])
      [{:has_bullets, has_bullets, "Has bullet points: #{has_bullets}"} | checks]
    else
      checks
    end

    # Calculate score
    if checks == [] do
      %{score: 1.0, passed: true, reason: nil, details: %{}}
    else
      passed_checks = Enum.count(checks, fn {_, passed, _} -> passed end)
      total_checks = length(checks)
      score = passed_checks / total_checks

      failed = Enum.filter(checks, fn {_, passed, _} -> !passed end)
      reasons = Enum.map(failed, fn {_, _, msg} -> msg end)

      %{
        score: score,
        passed: score >= 0.8,
        reason: if(reasons != [], do: Enum.join(reasons, "; "), else: nil),
        details: %{
          checks: Enum.map(checks, fn {name, passed, msg} ->
            %{check: name, passed: passed, message: msg}
          end)
        }
      }
    end
  end
end

# Define a sentiment evaluator
defmodule SimpleSentimentEvaluator do
  @behaviour Nous.Eval.Evaluator

  @positive_words ~w(good great excellent amazing wonderful fantastic awesome happy love best)
  @negative_words ~w(bad terrible awful horrible sad hate worst poor disappointing)

  @impl true
  def evaluate(actual, expected, _config) do
    output = case actual do
      %{output: o} when is_binary(o) -> String.downcase(o)
      s when is_binary(s) -> String.downcase(s)
      _ -> ""
    end

    expected_sentiment = expected[:sentiment] || :neutral

    positive_count = Enum.count(@positive_words, &String.contains?(output, &1))
    negative_count = Enum.count(@negative_words, &String.contains?(output, &1))

    detected_sentiment = cond do
      positive_count > negative_count -> :positive
      negative_count > positive_count -> :negative
      true -> :neutral
    end

    passed = detected_sentiment == expected_sentiment
    score = if passed, do: 1.0, else: 0.0

    %{
      score: score,
      passed: passed,
      reason: unless(passed, do: "Expected #{expected_sentiment}, got #{detected_sentiment}"),
      details: %{
        detected_sentiment: detected_sentiment,
        positive_words: positive_count,
        negative_words: negative_count
      }
    }
  end
end

# Configure model
model = System.get_env("NOUS_MODEL") || "lmstudio:ministral-3-14b-reasoning"

# Create test cases using custom evaluators
test_cases = [
  # Test 1: Response structure validation
  TestCase.new(
    id: "structured_response",
    name: "Structured Response",
    input: "Write a brief paragraph (3-5 sentences) about the benefits of exercise.",
    expected: %{
      min_sentences: 3,
      max_words: 100,
      min_words: 20
    },
    eval_type: :custom,
    eval_config: %{evaluator: ResponseStructureEvaluator}
  ),

  # Test 2: Bullet point format
  TestCase.new(
    id: "bullet_list",
    name: "Bullet Point List",
    input: "List 3 benefits of drinking water using bullet points",
    expected: %{
      has_bullets: true,
      min_words: 10
    },
    eval_type: :custom,
    eval_config: %{evaluator: ResponseStructureEvaluator}
  ),

  # Test 3: Sentiment analysis
  TestCase.new(
    id: "positive_review",
    name: "Positive Review",
    input: "Write a short positive review of a fictional restaurant called 'The Golden Fork'",
    expected: %{sentiment: :positive},
    eval_type: :custom,
    eval_config: %{evaluator: SimpleSentimentEvaluator}
  ),

  # Test 4: Negative sentiment
  TestCase.new(
    id: "complaint",
    name: "Complaint Letter",
    input: "Write a brief complaint about slow internet service",
    expected: %{sentiment: :negative},
    eval_type: :custom,
    eval_config: %{evaluator: SimpleSentimentEvaluator}
  )
]

suite = Suite.new(
  name: "custom_evaluator_example",
  default_model: model,
  default_instructions: "Follow the instructions carefully.",
  test_cases: test_cases
)

IO.puts("Running custom evaluator examples with model: #{model}\n")

case Eval.run(suite, timeout: 120_000) do
  {:ok, result} ->
    Reporter.print(result)

    # Show detailed results for custom evaluators
    IO.puts("\nDetailed Custom Evaluator Results:")
    IO.puts(String.duplicate("-", 60))

    Enum.each(result.test_results, fn test_result ->
      IO.puts("\n#{test_result.test_case.name}:")
      IO.puts("  Status: #{if test_result.passed, do: "PASS", else: "FAIL"}")
      IO.puts("  Score: #{Float.round(test_result.score * 100, 1)}%")

      if test_result.details && test_result.details != %{} do
        IO.puts("  Details:")
        case test_result.details do
          %{checks: checks} when is_list(checks) ->
            Enum.each(checks, fn check ->
              status = if check.passed, do: "✓", else: "✗"
              IO.puts("    #{status} #{check.message}")
            end)

          %{detected_sentiment: sentiment} ->
            IO.puts("    Detected sentiment: #{sentiment}")
            IO.puts("    Positive words: #{test_result.details.positive_words}")
            IO.puts("    Negative words: #{test_result.details.negative_words}")

          other ->
            IO.puts("    #{inspect(other)}")
        end
      end

      if test_result.reason do
        IO.puts("  Reason: #{test_result.reason}")
      end
    end)

  {:error, reason} ->
    IO.puts("Evaluation failed: #{inspect(reason)}")
end

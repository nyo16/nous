# A/B Testing Example
#
# This example shows how to compare two different configurations
# using the A/B testing feature.
#
# Run with: mix run examples/eval/05_ab_testing.exs

alias Nous.Eval
alias Nous.Eval.{TestCase, Suite}

# Configure model
model = System.get_env("NOUS_MODEL") || "lmstudio:ministral-3-14b-reasoning"

IO.puts("Running A/B test with model: #{model}\n")

# Create test cases for comparison
test_cases = [
  TestCase.new(
    id: "creative_story",
    name: "Creative Story",
    input: "Write a two-sentence story about a magical forest",
    expected: %{contains: ["forest"], min_words: 10},
    eval_type: :contains
  ),
  TestCase.new(
    id: "explain_concept",
    name: "Explain Concept",
    input: "Explain what photosynthesis is in simple terms",
    expected: %{contains: ["sun", "light", "plant", "energy"]},
    eval_type: :contains,
    eval_config: %{match_all: false}
  ),
  TestCase.new(
    id: "problem_solving",
    name: "Problem Solving",
    input: "A farmer has 15 apples and gives away 7. How many are left? Just the number.",
    expected: "8",
    eval_type: :fuzzy_match
  )
]

suite = Suite.new(
  name: "ab_test_example",
  default_model: model,
  test_cases: test_cases
)

IO.puts("=" <> String.duplicate("=", 59))
IO.puts("A/B Test: Temperature Comparison")
IO.puts("=" <> String.duplicate("=", 59))
IO.puts("")
IO.puts("Config A: temperature=0.2 (more deterministic)")
IO.puts("Config B: temperature=0.8 (more creative)")
IO.puts("")

# Run A/B comparison
case Eval.run_ab(suite,
  config_a: [
    model_settings: %{temperature: 0.2},
    instructions: "Be precise and concise."
  ],
  config_b: [
    model_settings: %{temperature: 0.8},
    instructions: "Be creative and expressive."
  ],
  timeout: 120_000
) do
  {:ok, comparison} ->
    IO.puts(String.duplicate("-", 60))
    IO.puts("Results")
    IO.puts(String.duplicate("-", 60))
    IO.puts("")

    # Config A results
    IO.puts("Config A (temp=0.2):")
    IO.puts("  Pass rate: #{Float.round(comparison.a.pass_rate * 100, 1)}%")
    IO.puts("  Avg score: #{Float.round(comparison.a.aggregate_score, 3)}")
    if comparison.a.metrics_summary[:latency] do
      IO.puts("  Latency p50: #{comparison.a.metrics_summary.latency.p50}ms")
    end
    IO.puts("")

    # Config B results
    IO.puts("Config B (temp=0.8):")
    IO.puts("  Pass rate: #{Float.round(comparison.b.pass_rate * 100, 1)}%")
    IO.puts("  Avg score: #{Float.round(comparison.b.aggregate_score, 3)}")
    if comparison.b.metrics_summary[:latency] do
      IO.puts("  Latency p50: #{comparison.b.metrics_summary.latency.p50}ms")
    end
    IO.puts("")

    # Comparison
    IO.puts(String.duplicate("-", 60))
    IO.puts("Comparison:")
    IO.puts("  Winner: #{comparison.comparison.winner}")
    IO.puts("  Score difference: #{Float.round(comparison.comparison.score_diff, 3)}")
    IO.puts("")

    # Detailed per-test comparison
    IO.puts("Per-test results:")
    IO.puts("")

    Enum.zip(comparison.a.test_results, comparison.b.test_results)
    |> Enum.each(fn {result_a, result_b} ->
      status_a = if result_a.passed, do: "✓", else: "✗"
      status_b = if result_b.passed, do: "✓", else: "✗"

      IO.puts("  #{result_a.test_case.name}:")
      IO.puts("    Config A: #{status_a} (score: #{Float.round(result_a.score, 2)})")
      IO.puts("    Config B: #{status_b} (score: #{Float.round(result_b.score, 2)})")
    end)

  {:error, reason} ->
    IO.puts("A/B test failed: #{inspect(reason)}")
end

IO.puts("")
IO.puts("=" <> String.duplicate("=", 59))
IO.puts("A/B Test: Instructions Comparison")
IO.puts("=" <> String.duplicate("=", 59))
IO.puts("")

# Test different instructions
case Eval.run_ab(suite,
  config_a: [
    instructions: "You are a helpful assistant. Answer questions directly."
  ],
  config_b: [
    instructions: "You are an expert teacher. Explain concepts clearly with examples."
  ],
  timeout: 120_000
) do
  {:ok, comparison} ->
    IO.puts("Direct instructions vs Teacher persona:")
    IO.puts("")
    IO.puts("  Config A (Direct): #{Float.round(comparison.a.aggregate_score * 100, 1)}%")
    IO.puts("  Config B (Teacher): #{Float.round(comparison.b.aggregate_score * 100, 1)}%")
    IO.puts("")
    IO.puts("  Winner: #{comparison.comparison.winner}")

  {:error, reason} ->
    IO.puts("A/B test failed: #{inspect(reason)}")
end

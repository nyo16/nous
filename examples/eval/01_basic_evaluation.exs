# Basic Evaluation Example
#
# This example shows how to create and run a simple evaluation suite.
#
# Run with: mix run examples/eval/01_basic_evaluation.exs

alias Nous.Eval
alias Nous.Eval.{TestCase, Suite, Reporter}

# Configure your model (uses LM Studio by default)
model = System.get_env("NOUS_MODEL") || "lmstudio:ministral-3-14b-reasoning"

IO.puts("Running evaluation with model: #{model}\n")

# Define test cases
test_cases = [
  # Test 1: Basic greeting with contains evaluator
  TestCase.new(
    id: "greeting",
    name: "Basic Greeting",
    input: "Say hello to the user",
    expected: %{contains: ["hello", "hi", "hey"]},
    eval_type: :contains,
    tags: [:basic]
  ),

  # Test 2: Math with fuzzy match
  TestCase.new(
    id: "math_simple",
    name: "Simple Math",
    input: "What is 15 + 27? Just give the number.",
    expected: "42",
    eval_type: :fuzzy_match,
    eval_config: %{threshold: 0.8},
    tags: [:math]
  ),

  # Test 3: Instructions following
  TestCase.new(
    id: "format_json",
    name: "JSON Format",
    input: "List 3 colors as a JSON array",
    expected: %{contains: ["[", "]"], patterns: ["\"\\w+\""]},
    eval_type: :contains,
    tags: [:format]
  ),

  # Test 4: Exact match (strict)
  TestCase.new(
    id: "capital",
    name: "Capital City",
    input: "What is the capital of France? Answer with just the city name.",
    expected: "Paris",
    eval_type: :exact_match,
    eval_config: %{case_sensitive: false},
    tags: [:knowledge]
  )
]

# Create suite
suite = Suite.new(
  name: "basic_eval_example",
  default_model: model,
  default_instructions: "Be concise. Give short, direct answers.",
  test_cases: test_cases
)

IO.puts("Suite: #{suite.name}")
IO.puts("Test cases: #{length(test_cases)}\n")

# Run evaluation
case Eval.run(suite, timeout: 60_000) do
  {:ok, result} ->
    # Print results
    Reporter.print(result)

    # Show individual results
    IO.puts("\nDetailed Results:")
    IO.puts(String.duplicate("-", 60))

    Enum.each(result.test_results, fn test_result ->
      status = if test_result.passed, do: "PASS", else: "FAIL"
      score = Float.round(test_result.score * 100, 1)

      IO.puts("#{status} | #{test_result.test_case.id} | Score: #{score}%")

      unless test_result.passed do
        IO.puts("     Reason: #{test_result.reason}")
      end
    end)

  {:error, reason} ->
    IO.puts("Evaluation failed: #{inspect(reason)}")
end

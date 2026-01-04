defmodule Nous.Eval do
  @moduledoc """
  Evaluation framework for Nous AI agents.

  Nous.Eval provides comprehensive testing, evaluation, and optimization capabilities
  for AI agents. It supports running test suites against real LLM APIs and collecting
  detailed metrics.

  ## Quick Start

      # Define a test suite
      suite = Nous.Eval.Suite.new(
        name: "my_agent_tests",
        default_model: "lmstudio:ministral-3-14b-reasoning",
        test_cases: [
          Nous.Eval.TestCase.new(
            id: "greeting",
            input: "Say hello",
            expected: %{contains: ["hello", "hi"]},
            eval_type: :contains
          )
        ]
      )

      # Run the evaluation
      {:ok, result} = Nous.Eval.run(suite)

      # Print results
      Nous.Eval.Reporter.print(result)

  ## Loading from YAML

      {:ok, suite} = Nous.Eval.Suite.from_yaml("test/eval/suites/basic.yaml")
      {:ok, result} = Nous.Eval.run(suite)

  ## A/B Testing

      {:ok, comparison} = Nous.Eval.run_ab(suite,
        config_a: [model_settings: %{temperature: 0.3}],
        config_b: [model_settings: %{temperature: 0.7}]
      )

  ## Mix Tasks

      # Run all suites
      mix nous.eval

      # Run specific suite
      mix nous.eval --suite basic

      # Filter by tags
      mix nous.eval --tags tool,streaming

  ## Metrics

  The evaluation framework tracks:

  - **Correctness**: Pass/fail rates and scores
  - **Token usage**: Input, output, and total tokens
  - **Latency**: Total duration, first token time, per-iteration timing
  - **Tool usage**: Call counts, errors, timing per tool
  - **Cost estimation**: Based on provider pricing

  ## Evaluators

  Built-in evaluators:

  - `:exact_match` - Output must exactly match expected
  - `:fuzzy_match` - String similarity above threshold
  - `:contains` - Output must contain expected substrings
  - `:tool_usage` - Verify correct tools were called
  - `:schema` - Validate structured output against Ecto schema
  - `:llm_judge` - Use an LLM to judge output quality

  ## Custom Evaluators

      defmodule MyEvaluator do
        @behaviour Nous.Eval.Evaluator

        @impl true
        def evaluate(actual, expected, config) do
          # Your evaluation logic
          %{score: 1.0, passed: true, reason: nil, details: %{}}
        end
      end

      test_case = TestCase.new(
        id: "custom",
        input: "...",
        expected: "...",
        eval_type: :custom,
        eval_config: %{evaluator: MyEvaluator}
      )

  """

  alias Nous.Eval.{Suite, Runner, Result}

  @doc """
  Run an evaluation suite.

  ## Options

    * `:model` - Override the default model for all test cases
    * `:agent_config` - Additional agent configuration
    * `:parallelism` - Number of concurrent test cases (default: 1)
    * `:timeout` - Timeout per test case in ms (default: from suite or 30_000)
    * `:retry_failed` - Number of retries for failed tests (default: 0)
    * `:tags` - Only run test cases with these tags
    * `:exclude_tags` - Skip test cases with these tags

  ## Returns

    * `{:ok, result}` - Run completed with results
    * `{:error, reason}` - Run failed to start

  ## Example

      {:ok, result} = Nous.Eval.run(suite)
      IO.puts("Pass rate: \#{result.pass_rate * 100}%")

  """
  @spec run(Suite.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Suite{} = suite, opts \\ []) do
    Runner.run(suite, opts)
  end

  @doc """
  Run an evaluation suite, raising on error.
  """
  @spec run!(Suite.t(), keyword()) :: map()
  def run!(%Suite{} = suite, opts \\ []) do
    case run(suite, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "Evaluation failed: #{inspect(reason)}"
    end
  end

  @doc """
  Run A/B comparison between two configurations.

  Runs the same suite with two different configurations and compares results.

  ## Options

    * `:config_a` - Configuration for variant A (keyword list)
    * `:config_b` - Configuration for variant B (keyword list)
    * All other options from `run/2`

  ## Returns

      %{
        a: %{...result for config A...},
        b: %{...result for config B...},
        comparison: %{
          winner: :a | :b | :tie,
          score_diff: float(),
          token_diff: float(),
          latency_diff: float()
        }
      }

  ## Example

      {:ok, comparison} = Nous.Eval.run_ab(suite,
        config_a: [model_settings: %{temperature: 0.3}],
        config_b: [model_settings: %{temperature: 0.7}]
      )

      IO.puts("Winner: \#{comparison.comparison.winner}")

  """
  @spec run_ab(Suite.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_ab(%Suite{} = suite, opts \\ []) do
    Runner.run_ab(suite, opts)
  end

  @doc """
  Run a single test case.

  Useful for debugging individual test cases.

  ## Example

      test_case = TestCase.new(id: "test", input: "Hello", expected: "hi")
      {:ok, result} = Nous.Eval.run_case(test_case, model: "lmstudio:model")

  """
  @spec run_case(Nous.Eval.TestCase.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run_case(%Nous.Eval.TestCase{} = test_case, opts \\ []) do
    Runner.run_case(test_case, opts)
  end
end

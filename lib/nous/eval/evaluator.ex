defmodule Nous.Eval.Evaluator do
  @moduledoc """
  Behaviour for evaluating agent outputs against expected results.

  Evaluators determine whether an agent's output matches expectations and
  provide a score indicating the quality of the match.

  ## Built-in Evaluators

  - `Nous.Eval.Evaluators.ExactMatch` - Exact string match
  - `Nous.Eval.Evaluators.FuzzyMatch` - Similarity-based match
  - `Nous.Eval.Evaluators.Contains` - Check for substrings
  - `Nous.Eval.Evaluators.ToolUsage` - Verify tool calls
  - `Nous.Eval.Evaluators.Schema` - Validate structured output
  - `Nous.Eval.Evaluators.LLMJudge` - LLM-based evaluation

  ## Custom Evaluators

      defmodule MyEvaluator do
        @behaviour Nous.Eval.Evaluator

        @impl true
        def evaluate(actual, expected, config) do
          # Your evaluation logic
          if my_check(actual, expected) do
            %{score: 1.0, passed: true, reason: nil, details: %{}}
          else
            %{score: 0.0, passed: false, reason: "Did not match", details: %{}}
          end
        end
      end

  ## Result Format

  Evaluators must return a map with:

    * `:score` - Float from 0.0 to 1.0
    * `:passed` - Boolean indicating pass/fail
    * `:reason` - String explaining failure (or nil)
    * `:details` - Map with additional details

  """

  @type score :: float()

  @type result :: %{
          score: score(),
          passed: boolean(),
          reason: String.t() | nil,
          details: map()
        }

  @doc """
  Evaluate an actual output against expected output.

  ## Parameters

    * `actual` - The actual output from the agent
    * `expected` - The expected output
    * `config` - Configuration map for the evaluator

  ## Returns

  A result map with score, passed status, and details.
  """
  @callback evaluate(actual :: term(), expected :: term(), config :: map()) :: result()

  @doc """
  Optional: Name of the evaluator for display purposes.
  """
  @callback name() :: String.t()

  @optional_callbacks [name: 0]

  @doc """
  Get the evaluator module for an eval_type.
  """
  @spec get_evaluator(atom()) :: module() | nil
  def get_evaluator(:exact_match), do: Nous.Eval.Evaluators.ExactMatch
  def get_evaluator(:fuzzy_match), do: Nous.Eval.Evaluators.FuzzyMatch
  def get_evaluator(:contains), do: Nous.Eval.Evaluators.Contains
  def get_evaluator(:tool_usage), do: Nous.Eval.Evaluators.ToolUsage
  def get_evaluator(:schema), do: Nous.Eval.Evaluators.Schema
  def get_evaluator(:llm_judge), do: Nous.Eval.Evaluators.LLMJudge
  def get_evaluator(:custom), do: nil
  def get_evaluator(_), do: nil

  @doc """
  Run evaluation using the appropriate evaluator.
  """
  @spec run(atom(), term(), term(), map()) :: result()
  def run(:custom, actual, expected, config) do
    case Map.get(config, :evaluator) do
      nil ->
        %{
          score: 0.0,
          passed: false,
          reason: "Custom evaluator not specified in config",
          details: %{}
        }

      evaluator when is_atom(evaluator) ->
        evaluator.evaluate(actual, expected, config)
    end
  end

  def run(eval_type, actual, expected, config) do
    case get_evaluator(eval_type) do
      nil ->
        %{
          score: 0.0,
          passed: false,
          reason: "Unknown eval_type: #{inspect(eval_type)}",
          details: %{}
        }

      evaluator when is_atom(evaluator) and not is_nil(evaluator) ->
        apply(evaluator, :evaluate, [actual, expected, config])
    end
  end

  @doc """
  Create a passing result helper.
  """
  @spec pass(map()) :: result()
  def pass(details \\ %{}) do
    %{score: 1.0, passed: true, reason: nil, details: details}
  end

  @doc """
  Create a failing result helper.
  """
  @spec fail(String.t(), map()) :: result()
  def fail(reason, details \\ %{}) do
    %{score: 0.0, passed: false, reason: reason, details: details}
  end

  @doc """
  Create a partial match result helper.
  """
  @spec partial(float(), String.t() | nil, map()) :: result()
  def partial(score, reason \\ nil, details \\ %{}) do
    %{score: score, passed: score >= 0.5, reason: reason, details: details}
  end
end

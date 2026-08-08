defmodule Nous.Eval.Result do
  @moduledoc """
  Result of a single test case evaluation.

  Contains the actual output, evaluation score, metrics, and any errors.

  ## Fields

    * `:test_case_id` - ID of the test case
    * `:test_case_name` - Display name of the test case
    * `:passed` - Whether the test passed
    * `:score` - Numeric score (0.0 to 1.0)
    * `:actual_output` - The output from the agent
    * `:expected_output` - The expected output
    * `:evaluation_details` - Details from the evaluator
    * `:metrics` - Collected metrics (tokens, latency, etc.)
    * `:error` - Error if the test failed to run
    * `:duration_ms` - Total test duration in milliseconds
    * `:run_at` - When the test was run

  """

  alias __MODULE__
  alias Nous.Eval.Metrics

  @type t :: %Result{
          test_case_id: String.t(),
          test_case_name: String.t(),
          passed: boolean(),
          score: float(),
          actual_output: term(),
          expected_output: term(),
          evaluation_details: map(),
          metrics: Metrics.t() | nil,
          error: term() | nil,
          duration_ms: non_neg_integer(),
          run_at: DateTime.t(),
          agent_result: map() | nil
        }

  defstruct [
    :test_case_id,
    :test_case_name,
    :actual_output,
    :expected_output,
    :error,
    :agent_result,
    passed: false,
    score: 0.0,
    evaluation_details: %{},
    metrics: nil,
    duration_ms: 0,
    run_at: nil
  ]

  @doc """
  Create a successful result.
  """
  @spec success(keyword()) :: t()
  def success(opts) do
    %Result{
      test_case_id: Keyword.fetch!(opts, :test_case_id),
      test_case_name: Keyword.get(opts, :test_case_name, opts[:test_case_id]),
      passed: true,
      score: Keyword.get(opts, :score, 1.0),
      actual_output: Keyword.get(opts, :actual_output),
      expected_output: Keyword.get(opts, :expected_output),
      evaluation_details: Keyword.get(opts, :evaluation_details, %{}),
      metrics: Keyword.get(opts, :metrics),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      run_at: Keyword.get(opts, :run_at, DateTime.utc_now()),
      agent_result: Keyword.get(opts, :agent_result)
    }
  end

  @doc """
  Create a failed result.
  """
  @spec failure(keyword()) :: t()
  def failure(opts) do
    %Result{
      test_case_id: Keyword.fetch!(opts, :test_case_id),
      test_case_name: Keyword.get(opts, :test_case_name, opts[:test_case_id]),
      passed: false,
      score: Keyword.get(opts, :score, 0.0),
      actual_output: Keyword.get(opts, :actual_output),
      expected_output: Keyword.get(opts, :expected_output),
      evaluation_details: Keyword.get(opts, :evaluation_details, %{}),
      metrics: Keyword.get(opts, :metrics),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      run_at: Keyword.get(opts, :run_at, DateTime.utc_now()),
      agent_result: Keyword.get(opts, :agent_result)
    }
  end

  @doc """
  Create an error result (test failed to run).
  """
  @spec error(keyword()) :: t()
  def error(opts) do
    %Result{
      test_case_id: Keyword.fetch!(opts, :test_case_id),
      test_case_name: Keyword.get(opts, :test_case_name, opts[:test_case_id]),
      passed: false,
      score: 0.0,
      error: Keyword.fetch!(opts, :error),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      run_at: Keyword.get(opts, :run_at, DateTime.utc_now())
    }
  end

  @doc """
  Check if the result has an error (test didn't complete).
  """
  @spec has_error?(t()) :: boolean()
  def has_error?(%Result{error: nil}), do: false
  def has_error?(%Result{}), do: true
end

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

  alias Nous.Eval.Metrics

  @type t :: %__MODULE__{
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
    %__MODULE__{
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
    %__MODULE__{
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
    %__MODULE__{
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
  def has_error?(%__MODULE__{error: nil}), do: false
  def has_error?(%__MODULE__{}), do: true
end

defmodule Nous.Eval.SuiteResult do
  @moduledoc """
  Result of running an entire test suite.
  """

  alias Nous.Eval.{Result, Metrics}

  @type t :: %__MODULE__{
          suite_name: String.t(),
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          results: [Result.t()],
          aggregate_score: float(),
          pass_rate: float(),
          pass_count: non_neg_integer(),
          fail_count: non_neg_integer(),
          error_count: non_neg_integer(),
          total_count: non_neg_integer(),
          metrics_summary: Metrics.Summary.t() | nil,
          duration_ms: non_neg_integer()
        }

  defstruct [
    :suite_name,
    :started_at,
    :completed_at,
    :metrics_summary,
    results: [],
    aggregate_score: 0.0,
    pass_rate: 0.0,
    pass_count: 0,
    fail_count: 0,
    error_count: 0,
    total_count: 0,
    duration_ms: 0
  ]

  @doc """
  Create a suite result from individual test results.
  """
  @spec from_results(String.t(), [Result.t()], DateTime.t(), DateTime.t()) :: t()
  def from_results(suite_name, results, started_at, completed_at) do
    pass_count = Enum.count(results, & &1.passed)
    error_count = Enum.count(results, &Result.has_error?/1)
    fail_count = length(results) - pass_count
    total_count = length(results)

    pass_rate = if total_count > 0, do: pass_count / total_count, else: 0.0

    aggregate_score =
      if total_count > 0 do
        results |> Enum.map(& &1.score) |> Enum.sum() |> Kernel./(total_count)
      else
        0.0
      end

    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    # Build metrics summary
    metrics_list = results |> Enum.map(& &1.metrics) |> Enum.reject(&is_nil/1)
    scores = Enum.map(results, & &1.score)

    metrics_summary =
      if metrics_list != [] do
        Metrics.Summary.from_metrics(metrics_list, scores)
      else
        nil
      end

    %__MODULE__{
      suite_name: suite_name,
      started_at: started_at,
      completed_at: completed_at,
      results: results,
      aggregate_score: Float.round(aggregate_score, 4),
      pass_rate: Float.round(pass_rate, 4),
      pass_count: pass_count,
      fail_count: fail_count,
      error_count: error_count,
      total_count: total_count,
      metrics_summary: metrics_summary,
      duration_ms: duration_ms
    }
  end

  @doc """
  Get failed test cases.
  """
  @spec failed(t()) :: [Result.t()]
  def failed(%__MODULE__{results: results}) do
    Enum.reject(results, & &1.passed)
  end

  @doc """
  Get passed test cases.
  """
  @spec passed(t()) :: [Result.t()]
  def passed(%__MODULE__{results: results}) do
    Enum.filter(results, & &1.passed)
  end

  @doc """
  Get error test cases (tests that failed to run).
  """
  @spec errors(t()) :: [Result.t()]
  def errors(%__MODULE__{results: results}) do
    Enum.filter(results, &Result.has_error?/1)
  end
end

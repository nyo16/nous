defmodule Nous.Eval.SuiteResult do
  @moduledoc """
  Result of running an entire test suite.
  """

  alias __MODULE__
  alias Nous.Eval.{Result, Metrics}

  @type t :: %SuiteResult{
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

    %SuiteResult{
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
  def failed(%SuiteResult{results: results}) do
    Enum.reject(results, & &1.passed)
  end

  @doc """
  Get passed test cases.
  """
  @spec passed(t()) :: [Result.t()]
  def passed(%SuiteResult{results: results}) do
    Enum.filter(results, & &1.passed)
  end

  @doc """
  Get error test cases (tests that failed to run).
  """
  @spec errors(t()) :: [Result.t()]
  def errors(%SuiteResult{results: results}) do
    Enum.filter(results, &Result.has_error?/1)
  end
end

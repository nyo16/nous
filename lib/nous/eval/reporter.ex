defmodule Nous.Eval.Reporter do
  @moduledoc """
  Report generation for evaluation results.

  ## Example

      {:ok, result} = Nous.Eval.run(suite)

      # Print to console
      Nous.Eval.Reporter.print(result)

      # Generate JSON
      json = Nous.Eval.Reporter.to_json(result)

      # Write to file
      Nous.Eval.Reporter.to_file(result, "report.json")

  """

  alias Nous.Eval.SuiteResult

  @doc """
  Print results to console.
  """
  @spec print(SuiteResult.t(), keyword()) :: :ok
  defdelegate print(result, opts \\ []), to: Nous.Eval.Reporter.Console

  @doc """
  Print detailed results (including failures) to console.
  """
  @spec print_detailed(SuiteResult.t(), keyword()) :: :ok
  defdelegate print_detailed(result, opts \\ []), to: Nous.Eval.Reporter.Console

  @doc """
  Generate JSON report.
  """
  @spec to_json(SuiteResult.t()) :: String.t()
  defdelegate to_json(result), to: Nous.Eval.Reporter.Json

  @doc """
  Write report to JSON file.
  """
  @spec to_file(SuiteResult.t(), String.t()) :: :ok | {:error, term()}
  defdelegate to_file(result, path), to: Nous.Eval.Reporter.Json

  @doc """
  Generate markdown report.
  """
  @spec to_markdown(SuiteResult.t()) :: String.t()
  def to_markdown(%SuiteResult{} = result) do
    """
    # Evaluation Report: #{result.suite_name}

    **Date:** #{DateTime.to_iso8601(result.completed_at)}
    **Duration:** #{result.duration_ms}ms

    ## Summary

    | Metric | Value |
    |--------|-------|
    | Total Tests | #{result.total_count} |
    | Passed | #{result.pass_count} |
    | Failed | #{result.fail_count} |
    | Errors | #{result.error_count} |
    | Pass Rate | #{Float.round(result.pass_rate * 100, 1)}% |
    | Average Score | #{Float.round(result.aggregate_score, 3)} |

    #{metrics_section(result)}

    ## Test Results

    #{test_results_table(result)}

    #{failures_section(result)}
    """
  end

  defp metrics_section(%{metrics_summary: nil}), do: ""

  defp metrics_section(%{metrics_summary: metrics}) do
    """
    ## Metrics

    | Metric | Value |
    |--------|-------|
    | Total Tokens | #{metrics.total_tokens} |
    | Mean Tokens | #{Float.round(metrics.mean_tokens, 1)} |
    | P50 Latency | #{metrics.p50_latency_ms}ms |
    | P95 Latency | #{metrics.p95_latency_ms}ms |
    | Tool Calls | #{metrics.total_tool_calls} |
    #{if metrics.total_estimated_cost, do: "| Estimated Cost | $#{Float.round(metrics.total_estimated_cost, 4)} |", else: ""}
    """
  end

  defp test_results_table(%{results: results}) do
    header = "| Test | Status | Score | Duration |\n|------|--------|-------|----------|\n"

    rows =
      Enum.map(results, fn r ->
        status = if r.passed, do: "PASS", else: "FAIL"
        duration = "#{r.duration_ms}ms"
        "| #{r.test_case_name} | #{status} | #{Float.round(r.score, 2)} | #{duration} |"
      end)
      |> Enum.join("\n")

    header <> rows
  end

  defp failures_section(%{results: results}) do
    failures = Enum.reject(results, & &1.passed)

    if failures == [] do
      ""
    else
      """
      ## Failures

      #{Enum.map_join(failures, "\n\n", &format_failure/1)}
      """
    end
  end

  defp format_failure(result) do
    reason =
      case result.evaluation_details[:reason] || result.error do
        nil -> "Unknown"
        r -> inspect(r)
      end

    """
    ### #{result.test_case_name}

    **Reason:** #{reason}

    **Expected:** #{inspect(result.expected_output)}

    **Actual:** #{inspect(result.actual_output)}
    """
  end
end

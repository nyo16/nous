defmodule Nous.Eval.Reporter.Json do
  @moduledoc """
  JSON output for evaluation reports.
  """

  alias Nous.Eval.SuiteResult

  @doc """
  Generate JSON report.
  """
  @spec to_json(SuiteResult.t()) :: String.t()
  def to_json(%SuiteResult{} = result) do
    result
    |> to_map()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Write report to JSON file.
  """
  @spec to_file(SuiteResult.t(), String.t()) :: :ok | {:error, term()}
  def to_file(%SuiteResult{} = result, path) do
    json = to_json(result)

    # Ensure directory exists
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case File.write(path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_error, path, reason}}
    end
  end

  @doc """
  Convert result to a map suitable for JSON encoding.
  """
  @spec to_map(SuiteResult.t()) :: map()
  def to_map(%SuiteResult{} = result) do
    %{
      suite_name: result.suite_name,
      started_at: DateTime.to_iso8601(result.started_at),
      completed_at: DateTime.to_iso8601(result.completed_at),
      duration_ms: result.duration_ms,
      summary: %{
        total: result.total_count,
        passed: result.pass_count,
        failed: result.fail_count,
        errors: result.error_count,
        pass_rate: result.pass_rate,
        aggregate_score: result.aggregate_score
      },
      metrics: format_metrics(result.metrics_summary),
      results: Enum.map(result.results, &format_result/1)
    }
  end

  defp format_metrics(nil), do: nil

  defp format_metrics(metrics) do
    %{
      count: metrics.count,
      scores: %{
        mean: metrics.mean_score,
        min: metrics.min_score,
        max: metrics.max_score
      },
      tokens: %{
        total: metrics.total_tokens,
        mean: metrics.mean_tokens,
        p50: metrics.p50_tokens,
        p95: metrics.p95_tokens,
        p99: metrics.p99_tokens
      },
      latency_ms: %{
        mean: metrics.mean_latency_ms,
        p50: metrics.p50_latency_ms,
        p95: metrics.p95_latency_ms,
        p99: metrics.p99_latency_ms
      },
      tools: %{
        total_calls: metrics.total_tool_calls,
        distribution: metrics.tool_call_distribution,
        error_rate: metrics.tool_error_rate
      },
      cost: %{
        total: metrics.total_estimated_cost,
        mean_per_run: metrics.mean_cost_per_run
      }
    }
  end

  defp format_result(result) do
    base = %{
      test_case_id: result.test_case_id,
      test_case_name: result.test_case_name,
      passed: result.passed,
      score: result.score,
      duration_ms: result.duration_ms,
      run_at: format_datetime(result.run_at)
    }

    if result.error do
      Map.merge(base, %{
        error: inspect(result.error)
      })
    else
      Map.merge(base, %{
        actual_output: format_output(result.actual_output),
        expected_output: format_output(result.expected_output),
        evaluation_details: result.evaluation_details,
        metrics: format_run_metrics(result.metrics)
      })
    end
  end

  defp format_output(output) when is_binary(output), do: output
  defp format_output(output), do: inspect(output)

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_run_metrics(nil), do: nil

  defp format_run_metrics(metrics) do
    %{
      input_tokens: metrics.input_tokens,
      output_tokens: metrics.output_tokens,
      total_tokens: metrics.total_tokens,
      total_duration_ms: metrics.total_duration_ms,
      iterations: metrics.iterations,
      tool_calls: metrics.tool_calls,
      requests: metrics.requests,
      tools_used: metrics.tools_used,
      estimated_cost: metrics.estimated_cost
    }
  end
end

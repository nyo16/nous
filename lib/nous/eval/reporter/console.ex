defmodule Nous.Eval.Reporter.Console do
  @moduledoc """
  Console output for evaluation reports.
  """

  alias Nous.Eval.{SuiteResult, Result}

  @doc """
  Print a summary of results to console.
  """
  @spec print(SuiteResult.t(), keyword()) :: :ok
  def print(%SuiteResult{} = result, opts \\ []) do
    show_details = Keyword.get(opts, :details, false)

    print_header(result)
    print_summary(result)

    if show_details do
      print_all_results(result)
    else
      print_failures(result)
    end

    print_metrics(result)
    print_footer(result)

    :ok
  end

  @doc """
  Print detailed results including all tests.
  """
  @spec print_detailed(SuiteResult.t(), keyword()) :: :ok
  def print_detailed(%SuiteResult{} = result, opts \\ []) do
    print(result, Keyword.put(opts, :details, true))
  end

  defp print_header(result) do
    IO.puts("")
    IO.puts(colorize("=" |> String.duplicate(60), :cyan))
    IO.puts(colorize("  Nous Evaluation Report: #{result.suite_name}", :cyan))
    IO.puts(colorize("=" |> String.duplicate(60), :cyan))
    IO.puts("")
  end

  defp print_summary(result) do
    pass_color = if result.pass_rate >= 0.8, do: :green, else: if(result.pass_rate >= 0.5, do: :yellow, else: :red)

    IO.puts("  Summary")
    IO.puts("  -------")
    IO.puts("  Total Tests:   #{result.total_count}")
    IO.puts("  " <> colorize("Passed:        #{result.pass_count}", :green))
    IO.puts("  " <> colorize("Failed:        #{result.fail_count}", :red))

    if result.error_count > 0 do
      IO.puts("  " <> colorize("Errors:        #{result.error_count}", :yellow))
    end

    IO.puts("  " <> colorize("Pass Rate:     #{format_percent(result.pass_rate)}", pass_color))
    IO.puts("  Avg Score:     #{Float.round(result.aggregate_score, 3)}")
    IO.puts("  Duration:      #{result.duration_ms}ms")
    IO.puts("")
  end

  defp print_all_results(%{results: results}) do
    IO.puts("  Test Results")
    IO.puts("  ------------")

    Enum.each(results, fn r ->
      status = if r.passed, do: colorize("PASS", :green), else: colorize("FAIL", :red)
      score = Float.round(r.score, 2)
      IO.puts("  [#{status}] #{r.test_case_name} (score: #{score}, #{r.duration_ms}ms)")

      if not r.passed and r.evaluation_details[:reason] do
        IO.puts("         " <> colorize("Reason: #{r.evaluation_details[:reason]}", :yellow))
      end
    end)

    IO.puts("")
  end

  defp print_failures(%{results: results}) do
    failures = Enum.reject(results, & &1.passed)

    if failures != [] do
      IO.puts("  " <> colorize("Failures", :red))
      IO.puts("  --------")

      Enum.each(failures, fn r ->
        IO.puts("")
        IO.puts("  " <> colorize("#{r.test_case_name}", :red))

        if Result.has_error?(r) do
          IO.puts("    Error: #{inspect(r.error)}")
        else
          IO.puts("    Score: #{Float.round(r.score, 2)}")

          if r.evaluation_details[:reason] do
            IO.puts("    Reason: #{r.evaluation_details[:reason]}")
          end

          IO.puts("    Expected: #{format_expected(r.expected_output)}")
          IO.puts("    Actual:   #{format_actual(r.actual_output)}")
        end
      end)

      IO.puts("")
    end
  end

  defp print_metrics(%{metrics_summary: nil}), do: :ok

  defp print_metrics(%{metrics_summary: metrics}) do
    IO.puts("  Metrics")
    IO.puts("  -------")
    IO.puts("  Tokens:       #{metrics.total_tokens} total (avg: #{Float.round(metrics.mean_tokens, 1)})")
    IO.puts("  Latency:      p50=#{metrics.p50_latency_ms}ms, p95=#{metrics.p95_latency_ms}ms, p99=#{metrics.p99_latency_ms}ms")
    IO.puts("  Tool Calls:   #{metrics.total_tool_calls}")

    if metrics.total_estimated_cost do
      IO.puts("  Est. Cost:    $#{Float.round(metrics.total_estimated_cost, 4)}")
    end

    IO.puts("")
  end

  defp print_footer(result) do
    status =
      cond do
        result.pass_rate == 1.0 -> colorize("ALL TESTS PASSED", :green)
        result.pass_rate >= 0.8 -> colorize("MOSTLY PASSED", :yellow)
        true -> colorize("TESTS FAILED", :red)
      end

    IO.puts(colorize("-" |> String.duplicate(60), :cyan))
    IO.puts("  #{status}")
    IO.puts(colorize("-" |> String.duplicate(60), :cyan))
    IO.puts("")
  end

  defp format_percent(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end

  defp format_expected(expected) when is_binary(expected) do
    truncate(expected, 50)
  end

  defp format_expected(expected) do
    expected |> inspect() |> truncate(50)
  end

  defp format_actual(actual) when is_binary(actual) do
    truncate(actual, 50)
  end

  defp format_actual(actual) do
    actual |> inspect() |> truncate(50)
  end

  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str

  defp truncate(str, max_len) do
    String.slice(str, 0, max_len - 3) <> "..."
  end

  defp colorize(text, color) do
    color_code =
      case color do
        :red -> "\e[31m"
        :green -> "\e[32m"
        :yellow -> "\e[33m"
        :cyan -> "\e[36m"
        _ -> ""
      end

    reset = "\e[0m"

    if IO.ANSI.enabled?() do
      "#{color_code}#{text}#{reset}"
    else
      text
    end
  end
end

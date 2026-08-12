defmodule Nous.Eval.OptimizerTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Metrics
  alias Nous.Eval.Optimizer
  alias Nous.Eval.SuiteResult

  # Regression: every metric other than :score and :pass_rate used
  # `get_in(result, [:metrics_summary, :latency, :p50])`. `%SuiteResult{}` and
  # `%Metrics.Summary{}` are plain structs with no Access implementation, so
  # that raised UndefinedFunctionError instead of returning nil — and the
  # nested `:latency`/`:tokens`/`:cost` keys do not exist on the summary in the
  # first place. `mix run examples/eval/03_optimization.exs` crashed on it.
  describe "extract_metric/2" do
    setup do
      summary = %Metrics.Summary{
        count: 2,
        mean_score: 0.75,
        total_tokens: 900,
        mean_tokens: 450.0,
        p50_tokens: 400,
        p95_tokens: 500,
        p99_tokens: 500,
        mean_latency_ms: 150.0,
        p50_latency_ms: 120,
        p95_latency_ms: 400,
        p99_latency_ms: 800,
        total_estimated_cost: 0.25,
        mean_cost_per_run: 0.125,
        pass_rate: 0.5
      }

      %{
        result: %SuiteResult{
          suite_name: "s",
          aggregate_score: 0.75,
          pass_rate: 0.5,
          metrics_summary: summary
        },
        empty: %SuiteResult{suite_name: "s", metrics_summary: nil}
      }
    end

    test "reads latency percentiles off the summary", %{result: result} do
      assert Optimizer.extract_metric(result, :latency_p50) == 120.0
      assert Optimizer.extract_metric(result, :latency_p95) == 400.0
      assert Optimizer.extract_metric(result, :latency_p99) == 800.0
    end

    test "reads token and cost totals off the summary", %{result: result} do
      assert Optimizer.extract_metric(result, :total_tokens) == 900.0
      assert Optimizer.extract_metric(result, :cost) == 0.25
    end

    test "reads score and pass rate", %{result: result} do
      assert Optimizer.extract_metric(result, :score) == 0.75
      assert Optimizer.extract_metric(result, :pass_rate) == 0.5
    end

    # A suite where every case errored has no summary. An objective must
    # degrade to a neutral score, not crash the whole search.
    test "returns 0.0 for every metric when the suite produced no summary", %{empty: empty} do
      for metric <- [
            :score,
            :pass_rate,
            :latency_p50,
            :latency_p95,
            :latency_p99,
            :total_tokens,
            :cost
          ] do
        assert Optimizer.extract_metric(empty, metric) == 0.0
      end
    end

    test "returns 0.0 for an unknown metric", %{result: result} do
      assert Optimizer.extract_metric(result, :not_a_metric) == 0.0
    end
  end
end

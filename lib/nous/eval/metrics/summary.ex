defmodule Nous.Eval.Metrics.Summary do
  @moduledoc """
  Aggregated metrics summary across multiple evaluation runs.
  """

  alias __MODULE__
  alias Nous.Eval.Metrics

  @type t :: %Summary{
          count: non_neg_integer(),

          # Aggregated scores
          mean_score: float(),
          min_score: float(),
          max_score: float(),

          # Token statistics
          total_tokens: non_neg_integer(),
          mean_tokens: float(),
          p50_tokens: non_neg_integer(),
          p95_tokens: non_neg_integer(),
          p99_tokens: non_neg_integer(),

          # Latency statistics (ms)
          mean_latency_ms: float(),
          p50_latency_ms: non_neg_integer(),
          p95_latency_ms: non_neg_integer(),
          p99_latency_ms: non_neg_integer(),

          # Tool usage
          total_tool_calls: non_neg_integer(),
          tool_call_distribution: %{String.t() => non_neg_integer()},
          tool_error_rate: float(),

          # Cost
          total_estimated_cost: float() | nil,
          mean_cost_per_run: float() | nil,

          # Pass/fail
          pass_count: non_neg_integer(),
          fail_count: non_neg_integer(),
          pass_rate: float()
        }

  defstruct count: 0,
            mean_score: 0.0,
            min_score: 0.0,
            max_score: 0.0,
            total_tokens: 0,
            mean_tokens: 0.0,
            p50_tokens: 0,
            p95_tokens: 0,
            p99_tokens: 0,
            mean_latency_ms: 0.0,
            p50_latency_ms: 0,
            p95_latency_ms: 0,
            p99_latency_ms: 0,
            total_tool_calls: 0,
            tool_call_distribution: %{},
            tool_error_rate: 0.0,
            total_estimated_cost: nil,
            mean_cost_per_run: nil,
            pass_count: 0,
            fail_count: 0,
            pass_rate: 0.0

  @doc """
  Create a summary from a list of metrics and scores.
  """
  @spec from_metrics([Metrics.t()], [float()]) :: t()
  def from_metrics(metrics_list, scores) when is_list(metrics_list) and is_list(scores) do
    count = length(metrics_list)

    if count == 0 do
      %Summary{}
    else
      tokens = Enum.map(metrics_list, & &1.total_tokens)
      latencies = Enum.map(metrics_list, & &1.total_duration_ms)
      tool_calls = Enum.map(metrics_list, & &1.tool_calls)
      tool_errors = Enum.map(metrics_list, & &1.tool_errors)

      # Merge all tool distributions
      tool_distribution =
        Enum.reduce(metrics_list, %{}, fn m, acc -> merge_tool_counts(acc, m.tools_used) end)

      # Cost calculations
      costs = Enum.map(metrics_list, & &1.estimated_cost) |> Enum.reject(&is_nil/1)
      total_cost = if costs == [], do: nil, else: Enum.sum(costs)
      mean_cost = if costs == [], do: nil, else: total_cost / length(costs)

      # Score calculations
      pass_count = Enum.count(scores, &(&1 >= 0.5))

      %Summary{
        count: count,
        mean_score: mean(scores),
        min_score: Enum.min(scores, fn -> 0.0 end),
        max_score: Enum.max(scores, fn -> 0.0 end),
        total_tokens: Enum.sum(tokens),
        mean_tokens: mean(tokens),
        p50_tokens: percentile(tokens, 50),
        p95_tokens: percentile(tokens, 95),
        p99_tokens: percentile(tokens, 99),
        mean_latency_ms: mean(latencies),
        p50_latency_ms: percentile(latencies, 50),
        p95_latency_ms: percentile(latencies, 95),
        p99_latency_ms: percentile(latencies, 99),
        total_tool_calls: Enum.sum(tool_calls),
        tool_call_distribution: tool_distribution,
        tool_error_rate: safe_divide(Enum.sum(tool_errors), Enum.sum(tool_calls)),
        total_estimated_cost: total_cost,
        mean_cost_per_run: mean_cost,
        pass_count: pass_count,
        fail_count: count - pass_count,
        pass_rate: pass_count / count
      }
    end
  end

  defp merge_tool_counts(acc, tools_used) do
    Map.merge(acc, tools_used, fn _tool, count, other -> count + other end)
  end

  @doc """
  Compare two summaries.
  """
  @spec compare(t(), t()) :: map()
  def compare(%Summary{} = a, %Summary{} = b) do
    %{
      score_diff: b.mean_score - a.mean_score,
      tokens_diff: b.mean_tokens - a.mean_tokens,
      latency_diff: b.mean_latency_ms - a.mean_latency_ms,
      pass_rate_diff: b.pass_rate - a.pass_rate,
      cost_diff:
        if(a.mean_cost_per_run && b.mean_cost_per_run,
          do: b.mean_cost_per_run - a.mean_cost_per_run,
          else: nil
        ),
      winner: determine_winner(a, b)
    }
  end

  defp determine_winner(a, b) do
    cond do
      b.mean_score > a.mean_score + 0.05 -> :b
      a.mean_score > b.mean_score + 0.05 -> :a
      true -> :tie
    end
  end

  defp mean([]), do: 0.0

  defp mean(list) do
    Enum.sum(list) / length(list)
  end

  defp percentile([], _), do: 0

  defp percentile(list, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(list)
    n = length(sorted)
    k = p / 100 * (n - 1)
    f = floor(k)
    c = ceil(k)

    if f == c do
      Enum.at(sorted, f)
    else
      lower = Enum.at(sorted, f)
      upper = Enum.at(sorted, c)
      round(lower + (upper - lower) * (k - f))
    end
  end

  defp safe_divide(_, 0), do: 0.0
  defp safe_divide(a, b), do: a / b
end

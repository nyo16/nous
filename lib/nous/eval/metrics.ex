defmodule Nous.Eval.Metrics do
  @moduledoc """
  Metrics collected during evaluation runs.

  Tracks token usage, latency, tool calls, and costs.

  ## Example

      metrics = Metrics.new()
      metrics = Metrics.from_usage(agent_result.usage)
      IO.puts("Total tokens: \#{metrics.total_tokens}")

  """

  @type t :: %__MODULE__{
          # Token metrics
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),

          # Timing metrics (milliseconds)
          total_duration_ms: non_neg_integer(),
          first_token_ms: non_neg_integer() | nil,
          model_latency_ms: non_neg_integer(),
          tool_latency_ms: non_neg_integer(),

          # Execution metrics
          iterations: non_neg_integer(),
          tool_calls: non_neg_integer(),
          tool_errors: non_neg_integer(),
          requests: non_neg_integer(),
          retries: non_neg_integer(),

          # Tool breakdown
          tools_used: %{String.t() => non_neg_integer()},

          # Cost estimation
          estimated_cost: float() | nil
        }

  defstruct input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            total_duration_ms: 0,
            first_token_ms: nil,
            model_latency_ms: 0,
            tool_latency_ms: 0,
            iterations: 0,
            tool_calls: 0,
            tool_errors: 0,
            requests: 0,
            retries: 0,
            tools_used: %{},
            estimated_cost: nil

  @doc """
  Create empty metrics.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Create metrics from a Nous.Usage struct.
  """
  @spec from_usage(Nous.Usage.t()) :: t()
  def from_usage(%Nous.Usage{} = usage) do
    %__MODULE__{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      tool_calls: usage.tool_calls,
      requests: usage.requests
    }
  end

  @doc """
  Create metrics from an agent result.
  """
  @spec from_agent_result(map(), non_neg_integer()) :: t()
  def from_agent_result(result, duration_ms) when is_map(result) do
    usage = Map.get(result, :usage) || %Nous.Usage{}

    # Extract tool breakdown from messages
    tools_used = extract_tools_used(result)

    # Get iterations from context if available
    iterations =
      case Map.get(result, :context) do
        %{iterations: i} when is_integer(i) -> i
        _ -> 1
      end

    %__MODULE__{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      total_duration_ms: duration_ms,
      tool_calls: usage.tool_calls,
      requests: usage.requests,
      iterations: iterations,
      tools_used: tools_used
    }
  end

  @doc """
  Merge two metrics structs.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = m1, %__MODULE__{} = m2) do
    %__MODULE__{
      input_tokens: m1.input_tokens + m2.input_tokens,
      output_tokens: m1.output_tokens + m2.output_tokens,
      total_tokens: m1.total_tokens + m2.total_tokens,
      total_duration_ms: m1.total_duration_ms + m2.total_duration_ms,
      first_token_ms: m1.first_token_ms || m2.first_token_ms,
      model_latency_ms: m1.model_latency_ms + m2.model_latency_ms,
      tool_latency_ms: m1.tool_latency_ms + m2.tool_latency_ms,
      iterations: m1.iterations + m2.iterations,
      tool_calls: m1.tool_calls + m2.tool_calls,
      tool_errors: m1.tool_errors + m2.tool_errors,
      requests: m1.requests + m2.requests,
      retries: m1.retries + m2.retries,
      tools_used: merge_tool_counts(m1.tools_used, m2.tools_used),
      estimated_cost: add_costs(m1.estimated_cost, m2.estimated_cost)
    }
  end

  @doc """
  Add cost estimation to metrics.
  """
  @spec with_cost(t(), String.t()) :: t()
  def with_cost(%__MODULE__{} = metrics, provider) do
    cost = Nous.Eval.Config.estimate_cost(provider, metrics.input_tokens, metrics.output_tokens)
    %{metrics | estimated_cost: cost}
  end

  defp extract_tools_used(result) do
    messages = Map.get(result, :all_messages) || get_in(result, [:context, :messages]) || []

    messages
    |> Enum.flat_map(fn msg ->
      case msg do
        %{role: :assistant, tool_calls: calls} when is_list(calls) ->
          Enum.map(calls, fn call ->
            call[:name] || call["name"] || "unknown"
          end)

        _ ->
          []
      end
    end)
    |> Enum.frequencies()
  end

  defp merge_tool_counts(m1, m2) do
    Map.merge(m1, m2, fn _k, v1, v2 -> v1 + v2 end)
  end

  defp add_costs(nil, nil), do: nil
  defp add_costs(c1, nil), do: c1
  defp add_costs(nil, c2), do: c2
  defp add_costs(c1, c2), do: c1 + c2
end

defmodule Nous.Eval.Metrics.Summary do
  @moduledoc """
  Aggregated metrics summary across multiple evaluation runs.
  """

  alias Nous.Eval.Metrics

  @type t :: %__MODULE__{
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
      %__MODULE__{}
    else
      tokens = Enum.map(metrics_list, & &1.total_tokens)
      latencies = Enum.map(metrics_list, & &1.total_duration_ms)
      tool_calls = Enum.map(metrics_list, & &1.tool_calls)
      tool_errors = Enum.map(metrics_list, & &1.tool_errors)

      # Merge all tool distributions
      tool_distribution =
        Enum.reduce(metrics_list, %{}, fn m, acc ->
          Map.merge(acc, m.tools_used, fn _k, v1, v2 -> v1 + v2 end)
        end)

      # Cost calculations
      costs = Enum.map(metrics_list, & &1.estimated_cost) |> Enum.reject(&is_nil/1)
      total_cost = if costs == [], do: nil, else: Enum.sum(costs)
      mean_cost = if costs == [], do: nil, else: total_cost / length(costs)

      # Score calculations
      pass_count = Enum.count(scores, &(&1 >= 0.5))

      %__MODULE__{
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

  @doc """
  Compare two summaries.
  """
  @spec compare(t(), t()) :: map()
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
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

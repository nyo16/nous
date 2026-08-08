defmodule Nous.Eval.Metrics do
  @moduledoc """
  Metrics collected during evaluation runs.

  Tracks token usage, latency, tool calls, and costs.

  ## Example

      metrics = Metrics.new()
      metrics = Metrics.from_usage(agent_result.usage)
      IO.puts("Total tokens: \#{metrics.total_tokens}")

  """

  alias __MODULE__

  @type t :: %Metrics{
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
  def new, do: %Metrics{}

  @doc """
  Create metrics from a Nous.Usage struct.
  """
  @spec from_usage(Nous.Usage.t()) :: t()
  def from_usage(%Nous.Usage{} = usage) do
    %Metrics{
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

    %Metrics{
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
  def merge(%Metrics{} = m1, %Metrics{} = m2) do
    %Metrics{
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
  def with_cost(%Metrics{} = metrics, provider) do
    cost = Nous.Eval.Config.estimate_cost(provider, metrics.input_tokens, metrics.output_tokens)
    %{metrics | estimated_cost: cost}
  end

  defp extract_tools_used(result) do
    messages = Map.get(result, :all_messages) || get_in(result, [:context, :messages]) || []

    messages
    |> Enum.flat_map(fn msg ->
      case msg do
        %{role: :assistant, tool_calls: calls} when is_list(calls) ->
          Enum.map(calls, &Nous.ToolCall.field(&1, :name, "unknown"))

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

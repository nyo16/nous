defmodule Nous.Observability.Attributes do
  @moduledoc """
  Maps nous telemetry metadata to OpenTelemetry semantic conventions.

  See: https://opentelemetry.io/docs/specs/semconv/gen-ai/
  """

  @doc """
  Convert agent start metadata to OpenTelemetry attributes.
  """
  @spec from_agent_start(map()) :: map()
  def from_agent_start(metadata) do
    %{
      "gen_ai.agent.name" => metadata[:agent_name],
      "gen_ai.provider.name" => to_string(metadata[:model_provider]),
      "gen_ai.request.model" => metadata[:model_name],
      "nous.agent.tool_count" => metadata[:tool_count],
      "nous.agent.has_tools" => metadata[:has_tools]
    }
    |> compact()
  end

  @doc """
  Convert agent stop measurements and metadata to OpenTelemetry attributes.
  """
  @spec from_agent_stop(map(), map()) :: map()
  def from_agent_stop(measurements, metadata) do
    %{
      "gen_ai.agent.name" => metadata[:agent_name],
      "gen_ai.provider.name" => to_string(metadata[:model_provider]),
      "gen_ai.request.model" => metadata[:model_name],
      "gen_ai.usage.input_tokens" => measurements[:input_tokens],
      "gen_ai.usage.output_tokens" => measurements[:output_tokens],
      "gen_ai.usage.total_tokens" => measurements[:total_tokens],
      "nous.agent.iterations" => measurements[:iterations],
      "nous.agent.tool_calls" => measurements[:tool_calls],
      "nous.agent.requests" => measurements[:requests]
    }
    |> compact()
  end

  @doc """
  Convert iteration start metadata to OpenTelemetry attributes.
  """
  @spec from_iteration_start(map()) :: map()
  def from_iteration_start(metadata) do
    %{
      "gen_ai.agent.name" => metadata[:agent_name],
      "nous.agent.iteration" => metadata[:iteration],
      "nous.agent.max_iterations" => metadata[:max_iterations]
    }
    |> compact()
  end

  @doc """
  Convert iteration stop metadata to OpenTelemetry attributes.
  """
  @spec from_iteration_stop(map(), map()) :: map()
  def from_iteration_stop(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    %{
      "gen_ai.agent.name" => metadata[:agent_name],
      "nous.agent.iteration" => metadata[:iteration],
      "nous.agent.tool_calls" => metadata[:tool_calls],
      "nous.agent.needs_response" => metadata[:needs_response],
      "nous.agent.duration_ms" => duration_ms
    }
    |> compact()
  end

  @doc """
  Convert provider request start metadata to OpenTelemetry attributes.
  """
  @spec from_provider_request_start(map()) :: map()
  def from_provider_request_start(metadata) do
    %{
      "gen_ai.operation.name" => "chat",
      "gen_ai.provider.name" => to_string(metadata[:provider]),
      "gen_ai.request.model" => metadata[:model_name],
      "gen_ai.request.message_count" => metadata[:message_count]
    }
    |> compact()
  end

  @doc """
  Convert provider response to OpenTelemetry attributes.
  """
  @spec from_provider_request_stop(map(), map()) :: map()
  def from_provider_request_stop(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    %{
      "gen_ai.provider.name" => to_string(metadata[:provider]),
      "gen_ai.response.model" => metadata[:model_name],
      "gen_ai.usage.input_tokens" => measurements[:input_tokens],
      "gen_ai.usage.output_tokens" => measurements[:output_tokens],
      "gen_ai.usage.total_tokens" => measurements[:total_tokens],
      "gen_ai.response.has_tool_calls" => metadata[:has_tool_calls],
      "nous.provider.duration_ms" => duration_ms
    }
    |> compact()
  end

  @doc """
  Convert tool execution start metadata to OpenTelemetry attributes.
  """
  @spec from_tool_start(map()) :: map()
  def from_tool_start(metadata) do
    %{
      "gen_ai.tool.name" => metadata[:tool_name],
      "gen_ai.tool.type" => "function",
      "nous.tool.module" => to_string(metadata[:tool_module]),
      "nous.tool.attempt" => metadata[:attempt],
      "nous.tool.max_retries" => metadata[:max_retries],
      "nous.tool.has_timeout" => metadata[:has_timeout]
    }
    |> compact()
  end

  @doc """
  Convert tool completion to OpenTelemetry attributes.
  """
  @spec from_tool_stop(map(), map()) :: map()
  def from_tool_stop(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    %{
      "gen_ai.tool.name" => metadata[:tool_name],
      "nous.tool.attempt" => metadata[:attempt],
      "nous.tool.success" => metadata[:success],
      "nous.tool.duration_ms" => duration_ms
    }
    |> compact()
  end

  @doc """
  Convert tool exception to OpenTelemetry attributes.
  """
  @spec from_tool_exception(map(), map()) :: map()
  def from_tool_exception(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)

    %{
      "gen_ai.tool.name" => metadata[:tool_name],
      "nous.tool.attempt" => metadata[:attempt],
      "nous.tool.will_retry" => metadata[:will_retry],
      "nous.tool.duration_ms" => duration_ms,
      "exception.type" => to_string(metadata[:kind]),
      "exception.message" => inspect(metadata[:reason])
    }
    |> compact()
  end

  # Remove nil values from the map
  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

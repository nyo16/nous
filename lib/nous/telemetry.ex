defmodule Nous.Telemetry do
  @moduledoc """
  Telemetry integration for Nous AI.

  Nous executes the following Telemetry events:

  ## Agent Events

    * `[:nous, :agent, :run, :start]` - Dispatched before agent execution starts
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string, tool_count: integer}`

    * `[:nous, :agent, :run, :stop]` - Dispatched after agent execution completes
      * Measurement: `%{duration: native_time, total_tokens: integer, input_tokens: integer, output_tokens: integer, tool_calls: integer, requests: integer, iterations: integer}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string}`

    * `[:nous, :agent, :run, :exception]` - Dispatched when agent execution fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{agent_name: string, model_provider: atom, kind: atom, reason: term, stacktrace: list}`

  ## Provider Events

    * `[:nous, :provider, :request, :start]` - Dispatched before calling provider API
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{provider: atom, model_name: string, message_count: integer}`

    * `[:nous, :provider, :request, :stop]` - Dispatched after provider responds
      * Measurement: `%{duration: native_time, input_tokens: integer, output_tokens: integer, total_tokens: integer}`
      * Metadata: `%{provider: atom, model_name: string, has_tool_calls: boolean}`

    * `[:nous, :provider, :request, :exception]` - Dispatched when provider request fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string, kind: atom, reason: term}`

  ## Provider Streaming Events

    * `[:nous, :provider, :stream, :start]` - Dispatched before starting a streaming request
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{provider: atom, model_name: string, message_count: integer}`

    * `[:nous, :provider, :stream, :connected]` - Dispatched when stream connection is established
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string}`

    * `[:nous, :provider, :stream, :exception]` - Dispatched when streaming request fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string, kind: atom, reason: term}`

  ## Tool Events

    * `[:nous, :tool, :execute, :start]` - Dispatched before tool execution
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{tool_name: string, attempt: integer, max_retries: integer}`

    * `[:nous, :tool, :execute, :stop]` - Dispatched after tool completes
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{tool_name: string, attempt: integer, success: boolean}`

    * `[:nous, :tool, :execute, :exception]` - Dispatched when tool fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{tool_name: string, attempt: integer, will_retry: boolean, kind: atom, reason: term}`

  All times are in `:native` time unit. Use `System.convert_time_unit/3` to
  convert to desired unit.

  ## Default Handler

  Nous provides a default handler that logs events at appropriate levels:

      Nous.Telemetry.attach_default_handler()

  This is useful for development and debugging.

  ## Custom Handlers

      :telemetry.attach(
        "my-nous-handler",
        [:nous, :agent, :run, :stop],
        fn _event, measurements, metadata, _config ->
          MyApp.Metrics.track_agent_run(
            metadata.agent_name,
            measurements.duration,
            measurements.total_tokens
          )
        end,
        nil
      )

  """

  require Logger

  @doc """
  Attaches the default logging handler for Nous events.

  This handler logs:
  - Agent runs (info level)
  - Provider requests (debug level)
  - Tool executions (debug level)
  - Exceptions (error level)

  ## Example

      Nous.Telemetry.attach_default_handler()

  """
  def attach_default_handler do
    events = [
      [:nous, :agent, :run, :start],
      [:nous, :agent, :run, :stop],
      [:nous, :agent, :run, :exception],
      [:nous, :provider, :request, :start],
      [:nous, :provider, :request, :stop],
      [:nous, :provider, :request, :exception],
      [:nous, :provider, :stream, :start],
      [:nous, :provider, :stream, :connected],
      [:nous, :provider, :stream, :exception],
      [:nous, :tool, :execute, :start],
      [:nous, :tool, :execute, :stop],
      [:nous, :tool, :execute, :exception]
    ]

    :telemetry.attach_many(
      "nous-default-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detaches the default handler.
  """
  def detach_default_handler do
    :telemetry.detach("nous-default-handler")
  end

  # Event handlers

  defp handle_event([:nous, :agent, :run, :start], _measurements, metadata, _config) do
    Logger.info("[Nous] Agent #{metadata.agent_name} starting (#{metadata.model_provider}:#{metadata.model_name})")
  end

  defp handle_event([:nous, :agent, :run, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "[Nous] Agent #{metadata.agent_name} completed in #{duration_ms}ms " <>
        "(#{measurements.total_tokens} tokens, #{measurements.tool_calls} tool calls, #{measurements.iterations} iterations)"
    )
  end

  defp handle_event([:nous, :agent, :run, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Nous] Agent #{metadata.agent_name} failed after #{duration_ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:nous, :provider, :request, :start], _measurements, metadata, _config) do
    Logger.debug("[Nous] Provider request to #{metadata.provider}:#{metadata.model_name}")
  end

  defp handle_event([:nous, :provider, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Provider #{metadata.provider}:#{metadata.model_name} responded in #{duration_ms}ms " <>
        "(#{measurements.total_tokens} tokens)"
    )
  end

  defp handle_event([:nous, :provider, :request, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Nous] Provider #{metadata.provider}:#{metadata.model_name} failed after #{duration_ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:nous, :provider, :stream, :start], _measurements, metadata, _config) do
    Logger.debug("[Nous] Stream request to #{metadata.provider}:#{metadata.model_name}")
  end

  defp handle_event([:nous, :provider, :stream, :connected], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Stream #{metadata.provider}:#{metadata.model_name} connected in #{duration_ms}ms"
    )
  end

  defp handle_event([:nous, :provider, :stream, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Nous] Stream #{metadata.provider}:#{metadata.model_name} failed after #{duration_ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:nous, :tool, :execute, :start], _measurements, metadata, _config) do
    Logger.debug("[Nous] Tool #{metadata.tool_name} executing (attempt #{metadata.attempt})")
  end

  defp handle_event([:nous, :tool, :execute, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Tool #{metadata.tool_name} #{if metadata.success, do: "succeeded", else: "failed"} " <>
        "in #{duration_ms}ms (attempt #{metadata.attempt})"
    )
  end

  defp handle_event([:nous, :tool, :execute, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    retry_msg = if metadata.will_retry, do: " (will retry)", else: " (final attempt)"

    Logger.warning(
      "[Nous] Tool #{metadata.tool_name} failed after #{duration_ms}ms#{retry_msg}: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  # Ignore unknown events for forward compatibility
  defp handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end

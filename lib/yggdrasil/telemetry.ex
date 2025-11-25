defmodule Yggdrasil.Telemetry do
  @moduledoc """
  Telemetry integration for Yggdrasil AI.

  Yggdrasil executes the following Telemetry events:

  ## Agent Events

    * `[:yggdrasil, :agent, :run, :start]` - Dispatched before agent execution starts
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string, tool_count: integer}`

    * `[:yggdrasil, :agent, :run, :stop]` - Dispatched after agent execution completes
      * Measurement: `%{duration: native_time, total_tokens: integer, input_tokens: integer, output_tokens: integer, tool_calls: integer, requests: integer, iterations: integer}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string}`

    * `[:yggdrasil, :agent, :run, :exception]` - Dispatched when agent execution fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{agent_name: string, model_provider: atom, kind: atom, reason: term, stacktrace: list}`

  ## Model Events

    * `[:yggdrasil, :model, :request, :start]` - Dispatched before calling model API
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{provider: atom, model_name: string, message_count: integer}`

    * `[:yggdrasil, :model, :request, :stop]` - Dispatched after model responds
      * Measurement: `%{duration: native_time, input_tokens: integer, output_tokens: integer, total_tokens: integer}`
      * Metadata: `%{provider: atom, model_name: string, has_tool_calls: boolean}`

    * `[:yggdrasil, :model, :request, :exception]` - Dispatched when model request fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string, kind: atom, reason: term}`

  ## Tool Events

    * `[:yggdrasil, :tool, :execute, :start]` - Dispatched before tool execution
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{tool_name: string, attempt: integer, max_retries: integer}`

    * `[:yggdrasil, :tool, :execute, :stop]` - Dispatched after tool completes
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{tool_name: string, attempt: integer, success: boolean}`

    * `[:yggdrasil, :tool, :execute, :exception]` - Dispatched when tool fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{tool_name: string, attempt: integer, will_retry: boolean, kind: atom, reason: term}`

  All times are in `:native` time unit. Use `System.convert_time_unit/3` to
  convert to desired unit.

  ## Default Handler

  Yggdrasil provides a default handler that logs events at appropriate levels:

      Yggdrasil.Telemetry.attach_default_handler()

  This is useful for development and debugging.

  ## Custom Handlers

      :telemetry.attach(
        "my-exadantic-handler",
        [:yggdrasil, :agent, :run, :stop],
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
  Attaches the default logging handler for Yggdrasil events.

  This handler logs:
  - Agent runs (info level)
  - Model requests (debug level)
  - Tool executions (debug level)
  - Exceptions (error level)

  ## Example

      Yggdrasil.Telemetry.attach_default_handler()

  """
  def attach_default_handler do
    events = [
      [:yggdrasil, :agent, :run, :start],
      [:yggdrasil, :agent, :run, :stop],
      [:yggdrasil, :agent, :run, :exception],
      [:yggdrasil, :model, :request, :start],
      [:yggdrasil, :model, :request, :stop],
      [:yggdrasil, :model, :request, :exception],
      [:yggdrasil, :tool, :execute, :start],
      [:yggdrasil, :tool, :execute, :stop],
      [:yggdrasil, :tool, :execute, :exception]
    ]

    :telemetry.attach_many(
      "exadantic-default-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detaches the default handler.
  """
  def detach_default_handler do
    :telemetry.detach("exadantic-default-handler")
  end

  # Event handlers

  defp handle_event([:yggdrasil, :agent, :run, :start], _measurements, metadata, _config) do
    Logger.info("[Yggdrasil] Agent #{metadata.agent_name} starting (#{metadata.model_provider}:#{metadata.model_name})")
  end

  defp handle_event([:yggdrasil, :agent, :run, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "[Yggdrasil] Agent #{metadata.agent_name} completed in #{duration_ms}ms " <>
        "(#{measurements.total_tokens} tokens, #{measurements.tool_calls} tool calls, #{measurements.iterations} iterations)"
    )
  end

  defp handle_event([:yggdrasil, :agent, :run, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Yggdrasil] Agent #{metadata.agent_name} failed after #{duration_ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:yggdrasil, :model, :request, :start], _measurements, metadata, _config) do
    Logger.debug("[Yggdrasil] Model request to #{metadata.provider}:#{metadata.model_name}")
  end

  defp handle_event([:yggdrasil, :model, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Yggdrasil] Model #{metadata.provider}:#{metadata.model_name} responded in #{duration_ms}ms " <>
        "(#{measurements.total_tokens} tokens)"
    )
  end

  defp handle_event([:yggdrasil, :model, :request, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Yggdrasil] Model #{metadata.provider}:#{metadata.model_name} failed after #{duration_ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:yggdrasil, :tool, :execute, :start], _measurements, metadata, _config) do
    Logger.debug("[Yggdrasil] Tool #{metadata.tool_name} executing (attempt #{metadata.attempt})")
  end

  defp handle_event([:yggdrasil, :tool, :execute, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Yggdrasil] Tool #{metadata.tool_name} #{if metadata.success, do: "succeeded", else: "failed"} " <>
        "in #{duration_ms}ms (attempt #{metadata.attempt})"
    )
  end

  defp handle_event([:yggdrasil, :tool, :execute, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    retry_msg = if metadata.will_retry, do: " (will retry)", else: " (final attempt)"

    Logger.warning(
      "[Yggdrasil] Tool #{metadata.tool_name} failed after #{duration_ms}ms#{retry_msg}: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  # Ignore unknown events for forward compatibility
  defp handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end

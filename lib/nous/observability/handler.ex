defmodule Nous.Observability.Handler do
  @moduledoc """
  Telemetry event handler that transforms nous events to OpenTelemetry spans
  and pushes them to the Broadway pipeline.
  """

  alias Nous.Observability.{Span, Attributes, Pipeline}

  @handler_id "nous-observability-handler"

  @events [
    [:nous, :agent, :run, :start],
    [:nous, :agent, :run, :stop],
    [:nous, :agent, :run, :exception],
    [:nous, :agent, :iteration, :start],
    [:nous, :agent, :iteration, :stop],
    [:nous, :provider, :request, :start],
    [:nous, :provider, :request, :stop],
    [:nous, :provider, :request, :exception],
    [:nous, :tool, :execute, :start],
    [:nous, :tool, :execute, :stop],
    [:nous, :tool, :execute, :exception]
  ]

  @doc """
  Attach the observability handler to telemetry events.
  """
  @spec attach(keyword()) :: :ok | {:error, term()}
  def attach(config) do
    :telemetry.attach_many(@handler_id, @events, &handle_event/4, config)
  end

  @doc """
  Detach the observability handler.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc """
  Check if the handler is currently attached.
  """
  @spec attached?() :: boolean()
  def attached? do
    handlers = :telemetry.list_handlers([:nous, :agent, :run, :start])
    Enum.any?(handlers, fn %{id: id} -> id == @handler_id end)
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  # Agent run start - create root trace span
  def handle_event([:nous, :agent, :run, :start], measurements, metadata, _config) do
    trace_id = Span.generate_trace_id()
    span_id = Span.generate_span_id()

    # Store in process dict for child spans
    Span.set_current(trace_id, span_id)

    agent_name = metadata[:agent_name] || metadata[:name] || "Agent Run"

    # Get metadata (global + per-run)
    obs_metadata = Nous.Observability.get_metadata()

    span = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: nil,
      name: agent_name,
      kind: "INTERNAL",
      start_time_unix_nano: measurements[:system_time] || System.system_time(:nanosecond),
      end_time_unix_nano: nil,
      status: %{code: "UNSET"},
      attributes: Attributes.from_agent_start(metadata),
      # User context for trace-level filtering
      user_id: obs_metadata[:user_id] || obs_metadata["user_id"],
      session_id: obs_metadata[:session_id] || obs_metadata["session_id"],
      environment: obs_metadata[:environment] || obs_metadata["environment"],
      app_version: obs_metadata[:app_version] || obs_metadata["app_version"],
      metadata: obs_metadata
    }

    Pipeline.push(span)
  end

  # Agent run stop - complete root trace span
  def handle_event([:nous, :agent, :run, :stop], measurements, metadata, _config) do
    {trace_id, span_id} = Span.get_current()

    end_time =
      if measurements[:duration] do
        (measurements[:system_time] || System.system_time(:nanosecond)) + measurements[:duration]
      else
        System.system_time(:nanosecond)
      end

    agent_name = metadata[:agent_name] || metadata[:name] || "Agent Run"

    span = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: nil,
      name: agent_name,
      kind: "INTERNAL",
      start_time_unix_nano: nil,  # Already sent
      end_time_unix_nano: end_time,
      status: %{code: "OK"},
      attributes: Attributes.from_agent_stop(measurements, metadata)
    }

    Pipeline.push(span)
    Span.clear_current()
  end

  # Agent run exception
  def handle_event([:nous, :agent, :run, :exception], measurements, metadata, _config) do
    {trace_id, span_id} = Span.get_current()

    span = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: nil,
      name: "gen_ai.agent.invoke",
      kind: "INTERNAL",
      start_time_unix_nano: nil,
      end_time_unix_nano: System.system_time(:nanosecond),
      status: %{code: "ERROR", description: inspect(metadata[:reason])},
      attributes:
        Attributes.from_agent_stop(measurements, metadata)
        |> Map.merge(%{
          "exception.type" => to_string(metadata[:kind]),
          "exception.message" => inspect(metadata[:reason])
        })
    }

    Pipeline.push(span)
    Span.clear_current()
  end

  # Iteration start
  def handle_event([:nous, :agent, :iteration, :start], measurements, metadata, _config) do
    {trace_id, parent_span_id} = Span.get_current()
    span_id = Span.generate_span_id()

    # Store iteration span as current for child spans
    Process.put(:nous_iteration_span, {span_id, parent_span_id})

    iteration_num = metadata[:iteration] || 1

    span = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      name: "Iteration #{iteration_num}",
      kind: "INTERNAL",
      start_time_unix_nano: measurements[:system_time] || System.system_time(:nanosecond),
      end_time_unix_nano: nil,
      status: %{code: "UNSET"},
      attributes: Attributes.from_iteration_start(metadata),
      metadata: Nous.Observability.get_metadata()
    }

    Pipeline.push(span)
  end

  # Iteration stop
  def handle_event([:nous, :agent, :iteration, :stop], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()

    case Process.get(:nous_iteration_span) do
      {span_id, _parent_span_id} ->
        end_time =
          if measurements[:duration] do
            (measurements[:system_time] || System.system_time(:nanosecond)) + measurements[:duration]
          else
            System.system_time(:nanosecond)
          end

        iteration_num = metadata[:iteration] || 1

        span = %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: nil,
          name: "Iteration #{iteration_num}",
          kind: "INTERNAL",
          start_time_unix_nano: nil,
          end_time_unix_nano: end_time,
          status: %{code: "OK"},
          attributes: Attributes.from_iteration_stop(measurements, metadata)
        }

        Pipeline.push(span)
        Process.delete(:nous_iteration_span)

      _ ->
        :ok
    end
  end

  # Provider request start
  def handle_event([:nous, :provider, :request, :start], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()
    span_id = Span.generate_span_id()

    # Get parent from iteration span or root span
    parent_span_id =
      case Process.get(:nous_iteration_span) do
        {iter_span_id, _} -> iter_span_id
        _ -> elem(Span.get_current(), 1)
      end

    Process.put(:nous_provider_span, span_id)

    provider = metadata[:provider] || "LLM"
    model = metadata[:model_name] || ""
    name = if model != "", do: "#{provider} (#{model})", else: "LLM Request"

    # Capture messages for debugging
    messages = metadata[:messages] || []
    serialized_messages = serialize_messages(messages)

    span = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      name: name,
      kind: "CLIENT",
      start_time_unix_nano: measurements[:system_time] || System.system_time(:nanosecond),
      end_time_unix_nano: nil,
      status: %{code: "UNSET"},
      attributes: Attributes.from_provider_request_start(metadata),
      input: %{messages: serialized_messages},
      metadata: Nous.Observability.get_metadata()
    }

    Pipeline.push(span)
  end

  # Provider request stop
  def handle_event([:nous, :provider, :request, :stop], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()

    case Process.get(:nous_provider_span) do
      span_id when is_binary(span_id) ->
        end_time =
          if measurements[:duration] do
            System.system_time(:nanosecond)
          else
            System.system_time(:nanosecond)
          end

        provider = metadata[:provider] || "LLM"
        model = metadata[:model_name] || ""
        name = if model != "", do: "#{provider} (#{model})", else: "LLM Request"

        # Capture response for debugging
        response = metadata[:response]
        output = serialize_response(response)

        span = %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: nil,
          name: name,
          kind: "CLIENT",
          start_time_unix_nano: nil,
          end_time_unix_nano: end_time,
          status: %{code: "OK"},
          attributes: Attributes.from_provider_request_stop(measurements, metadata),
          output: output
        }

        Pipeline.push(span)
        Process.delete(:nous_provider_span)

      _ ->
        :ok
    end
  end

  # Provider request exception
  def handle_event([:nous, :provider, :request, :exception], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()

    case Process.get(:nous_provider_span) do
      span_id when is_binary(span_id) ->
        provider = metadata[:provider] || "LLM"
        model = metadata[:model] || ""
        name = if model != "", do: "#{provider} (#{model})", else: "LLM Request"

        span = %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: nil,
          name: name,
          kind: "CLIENT",
          start_time_unix_nano: nil,
          end_time_unix_nano: System.system_time(:nanosecond),
          status: %{code: "ERROR", description: inspect(metadata[:reason])},
          attributes:
            Attributes.from_provider_request_stop(measurements, metadata)
            |> Map.merge(%{
              "exception.type" => to_string(metadata[:kind]),
              "exception.message" => inspect(metadata[:reason])
            })
        }

        Pipeline.push(span)
        Process.delete(:nous_provider_span)

      _ ->
        :ok
    end
  end

  # Tool execute start
  def handle_event([:nous, :tool, :execute, :start], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()
    span_id = Span.generate_span_id()

    # Get parent from iteration span or root span
    parent_span_id =
      case Process.get(:nous_iteration_span) do
        {iter_span_id, _} -> iter_span_id
        _ -> elem(Span.get_current(), 1)
      end

    tool_name = metadata[:tool_name] || "unknown"

    # Store start time for duration calculation
    Process.put({:nous_tool_span, tool_name}, {span_id, measurements[:system_time] || System.system_time(:nanosecond)})

    # Capture tool arguments
    arguments = metadata[:arguments]

    span = %{
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      name: "Tool: #{tool_name}",
      kind: "INTERNAL",
      start_time_unix_nano: measurements[:system_time] || System.system_time(:nanosecond),
      end_time_unix_nano: nil,
      status: %{code: "UNSET"},
      attributes: Attributes.from_tool_start(metadata),
      input: serialize_tool_args(arguments),
      metadata: Nous.Observability.get_metadata()
    }

    Pipeline.push(span)
  end

  # Tool execute stop
  def handle_event([:nous, :tool, :execute, :stop], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()
    tool_name = metadata[:tool_name] || "unknown"

    case Process.get({:nous_tool_span, tool_name}) do
      {span_id, start_time} when is_binary(span_id) ->
        end_time = System.system_time(:nanosecond)
        duration_ns = end_time - start_time
        duration_ms = div(duration_ns, 1_000_000)

        # Capture tool result
        result = metadata[:result]

        span = %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: nil,
          name: "Tool: #{tool_name}",
          kind: "INTERNAL",
          start_time_unix_nano: start_time,
          end_time_unix_nano: end_time,
          status: %{code: "OK"},
          attributes: Map.merge(Attributes.from_tool_stop(measurements, metadata), %{
            "nous.tool.duration_ms" => duration_ms
          }),
          output: serialize_tool_result(result)
        }

        Pipeline.push(span)
        Process.delete({:nous_tool_span, tool_name})

      _ ->
        :ok
    end
  end

  # Tool execute exception
  def handle_event([:nous, :tool, :execute, :exception], measurements, metadata, _config) do
    {trace_id, _} = Span.get_current()
    tool_name = metadata[:tool_name] || "unknown"

    case Process.get({:nous_tool_span, tool_name}) do
      {span_id, start_time} when is_binary(span_id) ->
        end_time = System.system_time(:nanosecond)
        duration_ns = end_time - start_time
        duration_ms = div(duration_ns, 1_000_000)

        # Capture error details
        error_type = metadata[:kind] || :error
        error_reason = metadata[:reason]
        stacktrace = metadata[:stacktrace]

        error_details = %{
          type: inspect(error_type),
          message: format_error(error_reason),
          stacktrace: format_stacktrace(stacktrace),
          will_retry: metadata[:will_retry] || false,
          attempt: metadata[:attempt] || 1
        }

        span = %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: nil,
          name: "Tool: #{tool_name}",
          kind: "INTERNAL",
          start_time_unix_nano: start_time,
          end_time_unix_nano: end_time,
          status: %{code: "ERROR", description: format_error(error_reason)},
          attributes: Map.merge(Attributes.from_tool_exception(measurements, metadata), %{
            "nous.tool.duration_ms" => duration_ms
          }),
          error: error_details
        }

        Pipeline.push(span)
        Process.delete({:nous_tool_span, tool_name})

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Serialization Helpers
  # ============================================================================

  defp serialize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      %{
        role: get_message_role(msg),
        content: get_message_content(msg),
        tool_calls: get_tool_calls(msg)
      }
    end)
  end
  defp serialize_messages(_), do: []

  defp get_message_role(%{role: role}), do: to_string(role)
  defp get_message_role(%Nous.Message{role: role}), do: to_string(role)
  defp get_message_role(_), do: "unknown"

  defp get_message_content(%{content: content}) when is_binary(content), do: content
  defp get_message_content(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{type: "text", text: text} -> text
      %{text: text} when is_binary(text) -> text
      part -> inspect(part)
    end)
  end
  defp get_message_content(%Nous.Message{content: content}), do: get_message_content(%{content: content})
  defp get_message_content(_), do: nil

  defp get_tool_calls(%{tool_calls: calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: Map.get(call, :id) || Map.get(call, "id"),
        name: Map.get(call, :name) || Map.get(call, "name"),
        arguments: Map.get(call, :arguments) || Map.get(call, "arguments")
      }
    end)
  end
  defp get_tool_calls(_), do: nil

  defp serialize_response(nil), do: nil
  defp serialize_response(%{content: content, tool_calls: tool_calls}) do
    %{
      content: content,
      tool_calls: serialize_tool_calls(tool_calls)
    }
  end
  defp serialize_response(response) when is_map(response) do
    %{
      content: Map.get(response, :content) || Map.get(response, "content"),
      tool_calls: serialize_tool_calls(Map.get(response, :tool_calls) || Map.get(response, "tool_calls"))
    }
  end
  defp serialize_response(response), do: inspect(response)

  defp serialize_tool_calls(nil), do: nil
  defp serialize_tool_calls([]), do: []
  defp serialize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: Map.get(call, :id) || Map.get(call, "id"),
        name: Map.get(call, :name) || Map.get(call, "name"),
        arguments: Map.get(call, :arguments) || Map.get(call, "arguments")
      }
    end)
  end
  defp serialize_tool_calls(_), do: nil

  defp serialize_tool_args(nil), do: nil
  defp serialize_tool_args(args) when is_map(args), do: args
  defp serialize_tool_args(args), do: inspect(args)

  defp serialize_tool_result(nil), do: nil
  defp serialize_tool_result({:ok, result}), do: %{status: "ok", result: format_result(result)}
  defp serialize_tool_result({:error, reason}), do: %{status: "error", error: format_error(reason)}
  defp serialize_tool_result(result), do: format_result(result)

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result) when is_map(result), do: result
  defp format_result(result), do: inspect(result)

  defp format_error(error) when is_binary(error), do: error
  defp format_error(%{message: msg}), do: msg
  defp format_error(error), do: inspect(error)

  defp format_stacktrace(nil), do: nil
  defp format_stacktrace([]), do: nil
  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(10)
    |> Exception.format_stacktrace()
  end
  defp format_stacktrace(_), do: nil
end

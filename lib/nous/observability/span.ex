defmodule Nous.Observability.Span do
  @moduledoc """
  Span and trace ID generation and context propagation.

  Follows OpenTelemetry W3C Trace Context format for IDs.
  """

  @trace_id_bytes 16
  @span_id_bytes 8
  @context_key :nous_observability_context

  @doc """
  Generate a new trace ID (32 hex characters).
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    :crypto.strong_rand_bytes(@trace_id_bytes)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Generate a new span ID (16 hex characters).
  """
  @spec generate_span_id() :: String.t()
  def generate_span_id do
    :crypto.strong_rand_bytes(@span_id_bytes)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Set the current trace and span context in the process dictionary.
  """
  @spec set_current(String.t(), String.t()) :: :ok
  def set_current(trace_id, span_id) do
    Process.put(@context_key, {trace_id, span_id})
    :ok
  end

  @doc """
  Get the current trace and span context from the process dictionary.

  Returns `{trace_id, span_id}` or `{nil, nil}` if not set.
  """
  @spec get_current() :: {String.t() | nil, String.t() | nil}
  def get_current do
    Process.get(@context_key, {nil, nil})
  end

  @doc """
  Clear the current trace context.
  """
  @spec clear_current() :: :ok
  def clear_current do
    Process.delete(@context_key)
    :ok
  end

  @doc """
  Execute a function with a new child span context.

  The child span inherits the current trace ID but gets a new span ID.
  The function receives `{trace_id, child_span_id, parent_span_id}`.
  After the function completes, the previous context is restored.
  """
  @spec with_child_span((tuple() -> result)) :: result when result: any()
  def with_child_span(fun) do
    {trace_id, parent_span_id} = get_current()
    child_span_id = generate_span_id()

    # Store old context
    old = Process.get(@context_key)

    # Set child as current
    set_current(trace_id, child_span_id)

    try do
      fun.({trace_id, child_span_id, parent_span_id})
    after
      # Restore old context
      if old do
        Process.put(@context_key, old)
      else
        clear_current()
      end
    end
  end

  @doc """
  Build a span struct from telemetry event data.
  """
  @spec build(atom(), map(), map(), keyword()) :: map()
  def build(event_type, measurements, metadata, opts \\ []) do
    {trace_id, span_id} = get_current()
    parent_span_id = opts[:parent_span_id]

    %{
      trace_id: trace_id,
      span_id: span_id || generate_span_id(),
      parent_span_id: parent_span_id,
      name: span_name(event_type, metadata),
      kind: span_kind(event_type),
      start_time_unix_nano: measurements[:system_time] || System.system_time(:nanosecond),
      end_time_unix_nano: nil,
      status: %{code: "UNSET"},
      attributes: %{},
      events: []
    }
  end

  @doc """
  Complete a span with end time and status.
  """
  @spec complete(map(), map(), map()) :: map()
  def complete(span, measurements, metadata) do
    end_time =
      if measurements[:duration] do
        span.start_time_unix_nano + System.convert_time_unit(measurements[:duration], :native, :nanosecond)
      else
        System.system_time(:nanosecond)
      end

    status =
      if Map.get(metadata, :error) || Map.get(metadata, :kind) == :error do
        %{code: "ERROR", description: inspect(Map.get(metadata, :reason, "Unknown error"))}
      else
        %{code: "OK"}
      end

    %{span | end_time_unix_nano: end_time, status: status}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp span_name(:agent_run_start, _metadata), do: "gen_ai.agent.invoke"
  defp span_name(:agent_run_stop, _metadata), do: "gen_ai.agent.invoke"
  defp span_name(:iteration_start, metadata), do: "gen_ai.agent.iteration.#{metadata[:iteration] || 0}"
  defp span_name(:iteration_stop, metadata), do: "gen_ai.agent.iteration.#{metadata[:iteration] || 0}"
  defp span_name(:provider_request_start, _metadata), do: "gen_ai.chat"
  defp span_name(:provider_request_stop, _metadata), do: "gen_ai.chat"
  defp span_name(:tool_execute_start, metadata), do: "gen_ai.tool.execute.#{metadata[:tool_name] || "unknown"}"
  defp span_name(:tool_execute_stop, metadata), do: "gen_ai.tool.execute.#{metadata[:tool_name] || "unknown"}"
  defp span_name(_, _), do: "unknown"

  defp span_kind(:agent_run_start), do: "INTERNAL"
  defp span_kind(:agent_run_stop), do: "INTERNAL"
  defp span_kind(:provider_request_start), do: "CLIENT"
  defp span_kind(:provider_request_stop), do: "CLIENT"
  defp span_kind(:tool_execute_start), do: "INTERNAL"
  defp span_kind(:tool_execute_stop), do: "INTERNAL"
  defp span_kind(_), do: "INTERNAL"
end

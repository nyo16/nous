defmodule Nous.AgentRunner.Streaming do
  @moduledoc false
  # Stream consumption and wrapping helpers for Nous.AgentRunner: callback
  # wrapping, result accumulation, and eager consumption of a normalized
  # stream into a %Nous.Message{}. Internal to the runner.

  alias Nous.{Errors, Message}
  alias Nous.Agent.Callbacks
  alias Nous.AgentRunner.Instrumentation
  alias Nous.Telemetry.RunScope

  require Logger

  @first_token_key :__nous_first_token_at__

  def wrap_stream_with_callbacks(stream, ctx) do
    Stream.map(stream, fn event ->
      case event do
        {:text_delta, text} ->
          Callbacks.execute(ctx, :on_llm_new_delta, text)

        {:thinking_delta, text} ->
          Callbacks.execute(ctx, :on_llm_new_delta, "[thinking] #{text}")

        {:tool_call_delta, calls} when is_list(calls) ->
          Enum.each(calls, fn call ->
            Callbacks.execute(ctx, :on_tool_call, call)
          end)

        # M-5: Anthropic streaming emits tool_use fragments tagged with
        # `_phase :start | :partial | :stop` and an `_index`. We don't
        # reassemble them here per-event because the on_tool_call callback
        # sees fragments by design (it's a streaming hook); the
        # post-stream complete-response path is what builds the final
        # tool_calls list, and Anthropic's convert_complete_response
        # handles that correctly.
        {:tool_call_delta, %{"_phase" => _} = _partial} ->
          :ok

        {:tool_call_delta, call} ->
          Callbacks.execute(ctx, :on_tool_call, call)

        _ ->
          :ok
      end

      event
    end)
  end

  # Wraps a stream to accumulate text/thinking content and emit a
  # {:complete, result} event after {:finish, reason}.
  # If the stream ends without {:finish}, emits {:complete} anyway.
  # This gives consumers a final aggregated result similar to run/3.
  #
  # Uses iodata accumulation (list of chunks) for O(n) performance,
  # converting to binary only once at the end.
  def wrap_stream_with_result(stream) do
    # Use a unique ref as sentinel — cannot collide with provider events
    sentinel = make_ref()

    stream
    |> Stream.concat([sentinel])
    |> Stream.transform(
      %{text: [], thinking: [], completed: false, sentinel: sentinel},
      fn
        {:text_delta, text} = event, acc ->
          # Prepend each chunk (O(1)) to a flat proper list; build_stream_result
          # reverses before IO.iodata_to_binary/1. The old `[acc.text | text]`
          # built a right-nested improper list whose depth grew with the stream.
          {[event], %{acc | text: [text | acc.text]}}

        {:thinking_delta, text} = event, acc ->
          {[event], %{acc | thinking: [text | acc.thinking]}}

        {:finish, _reason} = event, %{completed: true} = acc ->
          # OpenAI-compatible providers can emit a second {:finish, _} (the
          # finish_reason chunk followed by the end-of-stream marker). The
          # first one already emitted {:complete, _} with the accumulated
          # output — pass the event through without an empty duplicate.
          {[event], acc}

        {:finish, reason} = event, acc ->
          result = build_stream_result(acc, reason)
          {[event, {:complete, result}], %{acc | text: [], thinking: [], completed: true}}

        event, %{completed: true, sentinel: sentinel} = acc when event == sentinel ->
          # Already emitted :complete via {:finish}, nothing to do
          {[], acc}

        event, %{sentinel: sentinel} = acc when event == sentinel ->
          # Stream ended without {:finish} — emit :complete with accumulated data
          result = build_stream_result(acc, "stop")

          if acc.text == [] and acc.thinking == [] do
            # Completely empty stream — likely a provider issue (e.g. minimax)
            Logger.warning(
              "Stream ended with no events — possible provider issue (empty response)"
            )

            {[{:error, :empty_stream}, {:complete, result}], %{acc | completed: true}}
          else
            {[{:complete, result}], %{acc | completed: true}}
          end

        event, acc ->
          {[event], acc}
      end
    )
  end

  # The telemetry of a `Nous.AgentRunner.run_stream/3` run, which outlives the
  # call that started it: the stream is enumerated later, by whoever holds it,
  # possibly in another process. So the run's scope is reinstalled around
  # every pull from the stream (and every suspended continuation), the model
  # and run `:stop` events fire when `{:complete, _}` passes through, and a
  # raise during enumeration emits the `:exception` events (unless the run
  # already stopped) before it propagates.
  #
  # `info`: `agent`, `run_scope`, `start_time`, `model_span` (nil when no
  # model was called, e.g. a guard blocked the request) and `active_model`.
  def instrument_run(stream, info) do
    stream
    |> Stream.transform(%{first_token_at: nil, usage: nil}, fn
      {:complete, result} = event, acc ->
        complete_run(info, acc, result)
        {[event], acc}

      {:usage, usage} = event, acc ->
        {[event], %{acc | usage: usage}}

      {kind, _} = event, %{first_token_at: nil} = acc
      when kind in [:text_delta, :thinking_delta, :tool_call_delta] ->
        {[event], %{acc | first_token_at: System.monotonic_time()}}

      event, acc ->
        {[event], acc}
    end)
    |> scoped(info)
  end

  defp complete_run(info, acc, result) do
    usage = acc.usage || %Nous.Usage{}
    called_model? = info.model_span != nil

    if called_model? do
      response =
        Message.new!(
          %{
            role: :assistant,
            metadata: %{usage: usage, finish_reason: Map.get(result, :finish_reason)}
          }
          |> put_content(Map.get(result, :output, ""))
        )

      Instrumentation.model_stop(info.model_span, response, info.active_model, acc.first_token_at)
    end

    count = if called_model?, do: 1, else: 0

    measurements = %{
      total_tokens: usage_value(usage, :total_tokens),
      input_tokens: usage_value(usage, :input_tokens),
      output_tokens: usage_value(usage, :output_tokens),
      tool_calls: 0,
      requests: count,
      iterations: count
    }

    active = info.active_model || info.agent.model

    Instrumentation.run_stop(info.agent, info.run_scope, info.start_time, measurements, %{
      model: active,
      fallback_used: active != info.agent.model
    })
  end

  defp put_content(attrs, ""), do: attrs
  defp put_content(attrs, text) when is_binary(text), do: Map.put(attrs, :content, text)
  defp put_content(attrs, _other), do: attrs

  defp usage_value(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  # An enumerable (a 2-arity reducer function) that runs every step of
  # `stream` under the run's scope.
  defp scoped(stream, info) do
    scope = RunScope.install_scope(info.run_scope)

    fn acc, fun ->
      scoped_step(fn acc -> Enumerable.reduce(stream, acc, fun) end, acc, scope, info)
    end
  end

  defp scoped_step(step, acc, scope, info) do
    result =
      RunScope.with_scope(scope, fn ->
        try do
          step.(acc)
        catch
          kind, reason ->
            stream_failed(info, kind, reason, __STACKTRACE__)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end)

    case result do
      {:suspended, acc, continuation} ->
        {:suspended, acc, &scoped_step(continuation, &1, scope, info)}

      finished ->
        Instrumentation.clear_terminal(info.run_scope)
        finished
    end
  end

  defp stream_failed(info, kind, reason, stacktrace) do
    unless Instrumentation.terminal?(info.run_scope) do
      if info.model_span, do: Instrumentation.model_exception(info.model_span, kind, reason)

      Instrumentation.run_exception(
        info.agent,
        info.run_scope,
        info.start_time,
        kind,
        reason,
        stacktrace
      )
    end

    Instrumentation.clear_terminal(info.run_scope)
  end

  def build_stream_result(acc, reason) do
    # acc.text/acc.thinking are chunks in reverse arrival order (prepended);
    # reverse to restore order before flattening to a binary.
    result = %{
      output: acc.text |> Enum.reverse() |> IO.iodata_to_binary(),
      finish_reason: reason
    }

    thinking = acc.thinking |> Enum.reverse() |> IO.iodata_to_binary()

    if thinking != "",
      do: Map.put(result, :thinking, thinking),
      else: result
  end

  # Consume a normalized stream into a single %Nous.Message{}, firing
  # per-chunk delta callbacks along the way. Halts cleanly with
  # ExecutionCancelled if `ctx.cancellation_check` raises {:cancelled, reason}
  # between chunks.
  def consume_stream_into_message(stream, ctx, provider) do
    initial = %{
      text: [],
      reasoning: [],
      tool_acc: Nous.StreamNormalizer.ToolCallAccumulator.new(),
      usage: nil,
      finish_reason: "stop",
      error: nil,
      cancelled: nil,
      first_token_at: nil
    }

    final =
      Enum.reduce_while(stream, initial, fn event, acc ->
        case check_cancellation_inline(ctx) do
          {:cancelled, reason} ->
            {:halt, %{acc | cancelled: reason}}

          :ok ->
            {:cont, event |> handle_stream_event(acc, ctx) |> note_first_token(event)}
        end
      end)

    cond do
      final.cancelled ->
        {:error, Errors.ExecutionCancelled.exception(reason: final.cancelled)}

      final.error ->
        {:error, final.error}

      true ->
        {:ok, build_streamed_message(final, provider)}
    end
  end

  def handle_stream_event({:text_delta, text}, acc, ctx) do
    Callbacks.execute(ctx, :on_llm_new_delta, text)
    %{acc | text: [acc.text, text]}
  end

  def handle_stream_event({:thinking_delta, text}, acc, ctx) do
    Callbacks.execute(ctx, :on_llm_new_thinking_delta, text)
    %{acc | reasoning: [acc.reasoning, text]}
  end

  def handle_stream_event({:tool_call_delta, fragment}, acc, _ctx) do
    %{acc | tool_acc: Nous.StreamNormalizer.ToolCallAccumulator.feed(acc.tool_acc, fragment)}
  end

  def handle_stream_event({:usage, usage}, acc, _ctx) do
    %{acc | usage: usage}
  end

  def handle_stream_event({:finish, reason}, acc, _ctx) do
    %{acc | finish_reason: reason}
  end

  def handle_stream_event({:error, reason}, acc, _ctx) do
    %{acc | error: reason}
  end

  def handle_stream_event(_other, acc, _ctx), do: acc

  # The monotonic time of the first chunk that carries model output, for the
  # model span's `time_to_first_token`.
  defp note_first_token(%{first_token_at: nil} = acc, {kind, _})
       when kind in [:text_delta, :thinking_delta, :tool_call_delta],
       do: %{acc | first_token_at: System.monotonic_time()}

  defp note_first_token(acc, _event), do: acc

  @doc false
  # The metadata key the first-chunk time travels under from
  # build_streamed_message/2 to the model span, which pops it before the
  # message goes anywhere else (`Nous.AgentRunner.IterationLoop`).
  def first_token_key, do: @first_token_key

  def build_streamed_message(acc, _provider) do
    text = IO.iodata_to_binary(acc.text)
    reasoning = IO.iodata_to_binary(acc.reasoning)
    tool_calls = Nous.StreamNormalizer.ToolCallAccumulator.finalize(acc.tool_acc)

    metadata = %{
      usage: acc.usage || %Nous.Usage{},
      finish_reason: acc.finish_reason,
      timestamp: DateTime.utc_now()
    }

    metadata =
      case Map.get(acc, :first_token_at) do
        nil -> metadata
        at -> Map.put(metadata, @first_token_key, at)
      end

    attrs = %{role: :assistant, metadata: metadata}

    attrs = if text != "", do: Map.put(attrs, :content, text), else: attrs

    attrs =
      if reasoning != "",
        do: Map.put(attrs, :reasoning_content, reasoning),
        else: attrs

    attrs =
      if tool_calls != [],
        do: Map.put(attrs, :tool_calls, tool_calls),
        else: attrs

    Message.new!(attrs)
  end

  # Inline cancellation probe used between streamed chunks. Mirrors
  # check_cancellation/1 but returns a value instead of an {:error, _}
  # tuple so the reduce can decide between :halt and :cont.
  def check_cancellation_inline(%{cancellation_check: nil}), do: :ok

  def check_cancellation_inline(%{cancellation_check: check}) when is_function(check, 0) do
    try do
      check.()
      :ok
    catch
      {:cancelled, reason} -> {:cancelled, reason}
    end
  end

  def check_cancellation_inline(_), do: :ok
end

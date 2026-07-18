defmodule Nous.AgentRunner.Streaming do
  @moduledoc false
  # Stream consumption and wrapping helpers for Nous.AgentRunner: callback
  # wrapping, result accumulation, and eager consumption of a normalized
  # stream into a %Nous.Message{}. Internal to the runner.

  alias Nous.{Errors, Message}
  alias Nous.Agent.Callbacks

  require Logger

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
      cancelled: nil
    }

    final =
      Enum.reduce_while(stream, initial, fn event, acc ->
        case check_cancellation_inline(ctx) do
          {:cancelled, reason} ->
            {:halt, %{acc | cancelled: reason}}

          :ok ->
            {:cont, handle_stream_event(event, acc, ctx)}
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

  def build_streamed_message(acc, _provider) do
    text = IO.iodata_to_binary(acc.text)
    reasoning = IO.iodata_to_binary(acc.reasoning)
    tool_calls = Nous.StreamNormalizer.ToolCallAccumulator.finalize(acc.tool_acc)

    attrs = %{
      role: :assistant,
      metadata: %{
        usage: acc.usage || %Nous.Usage{},
        finish_reason: acc.finish_reason,
        timestamp: DateTime.utc_now()
      }
    }

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

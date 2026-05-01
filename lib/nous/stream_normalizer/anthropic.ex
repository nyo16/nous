defmodule Nous.StreamNormalizer.Anthropic do
  @moduledoc """
  Stream normalizer for Anthropic API.

  Handles Anthropic's SSE streaming format where events arrive as JSON maps
  with a `"type"` field indicating the event kind.

  ## Streaming Event Types

  | Anthropic Event | Normalized Output |
  |----------------|-------------------|
  | `content_block_delta` + `text_delta` | `{:text_delta, text}` |
  | `content_block_delta` + `thinking_delta` | `{:thinking_delta, text}` |
  | `content_block_delta` + `input_json_delta` | `{:tool_call_delta, json}` |
  | `content_block_start` + `tool_use` | `{:tool_call_delta, %{"id" => ..., "name" => ...}}` |
  | `message_delta` with `stop_reason` | `{:finish, reason}` |
  | `message_start`, `content_block_stop`, `message_stop` | `{:unknown, ...}` |
  | `{:stream_done, reason}` | `{:finish, reason}` |
  | Error with `"type" => "error"` | `{:error, message}` |
  """

  @behaviour Nous.StreamNormalizer

  @impl true
  def normalize_chunk({:stream_done, reason}) do
    [{:finish, reason}]
  end

  def normalize_chunk(%{"type" => "error", "error" => error}) do
    message = Map.get(error, "message", inspect(error))
    [{:error, message}]
  end

  def normalize_chunk(%{"type" => "content_block_delta", "delta" => delta} = chunk) do
    index = Map.get(chunk, "index")
    [parse_delta(delta, index)]
  end

  def normalize_chunk(%{"type" => "content_block_start", "content_block" => block} = chunk) do
    index = Map.get(chunk, "index")

    case block do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        # Emit a structured "start" so a stateful consumer can begin a
        # buffer keyed by `index` and append input_json_delta fragments
        # until content_block_stop, then assemble the full tool_call.
        [{:tool_call_delta, %{"id" => id, "name" => name, "_index" => index, "_phase" => :start}}]

      _ ->
        [{:unknown, block}]
    end
  end

  def normalize_chunk(%{"type" => "content_block_stop"} = chunk) do
    index = Map.get(chunk, "index")
    # Signal end of a content block; consumers tracking tool_use buffers
    # by index should flush at this point.
    [{:tool_call_delta, %{"_index" => index, "_phase" => :stop}}]
  end

  def normalize_chunk(%{"type" => "message_delta", "delta" => delta} = chunk) do
    usage_events =
      case Map.get(chunk, "usage") do
        usage when is_map(usage) -> [{:usage, Nous.Messages.Anthropic.parse_usage(usage)}]
        _ -> []
      end

    case Map.get(delta, "stop_reason") do
      nil ->
        if usage_events == [], do: [{:unknown, delta}], else: usage_events

      reason ->
        usage_events ++ [{:finish, reason}]
    end
  end

  def normalize_chunk(%{"type" => "message_start", "message" => message}) do
    case Map.get(message, "usage") do
      usage when is_map(usage) -> [{:usage, Nous.Messages.Anthropic.parse_usage(usage)}]
      _ -> [{:unknown, message}]
    end
  end

  def normalize_chunk(chunk) when is_map(chunk) do
    if complete_response?(chunk) do
      convert_complete_response(chunk)
    else
      [{:unknown, chunk}]
    end
  end

  def normalize_chunk(chunk) do
    [{:unknown, chunk}]
  end

  @impl true
  def complete_response?(chunk) when is_map(chunk) do
    Map.has_key?(chunk, "content") and Map.has_key?(chunk, "role")
  end

  def complete_response?(_), do: false

  @impl true
  def convert_complete_response(%{"content" => content} = chunk) when is_list(content) do
    events =
      Enum.flat_map(content, fn
        %{"type" => "text", "text" => text} when text != "" ->
          [{:text_delta, text}]

        %{"type" => "thinking", "thinking" => text} when text != "" ->
          [{:thinking_delta, text}]

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          [{:tool_call_delta, %{"id" => id, "name" => name, "input" => input}}]

        _ ->
          []
      end)

    stop_reason = Map.get(chunk, "stop_reason", "end_turn")
    events ++ [{:finish, stop_reason}]
  end

  def convert_complete_response(chunk) do
    [{:unknown, chunk}]
  end

  defp parse_delta(%{"type" => "text_delta", "text" => text}, _index) do
    {:text_delta, text}
  end

  defp parse_delta(%{"type" => "thinking_delta", "thinking" => text}, _index) do
    {:thinking_delta, text}
  end

  defp parse_delta(%{"type" => "input_json_delta", "partial_json" => json}, index) do
    # Tag the partial fragment with its content block index so the consumer
    # can buffer it correctly when multiple tool calls stream interleaved.
    {:tool_call_delta, %{"_index" => index, "_phase" => :partial, "partial_json" => json}}
  end

  defp parse_delta(delta, _index) do
    {:unknown, delta}
  end
end

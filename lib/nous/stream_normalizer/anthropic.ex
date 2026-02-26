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

  def normalize_chunk(%{"type" => "content_block_delta", "delta" => delta}) do
    [parse_delta(delta)]
  end

  def normalize_chunk(%{"type" => "content_block_start", "content_block" => block}) do
    case block do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        [{:tool_call_delta, %{"id" => id, "name" => name}}]

      _ ->
        [{:unknown, block}]
    end
  end

  def normalize_chunk(%{"type" => "message_delta", "delta" => delta}) do
    case Map.get(delta, "stop_reason") do
      nil -> [{:unknown, delta}]
      reason -> [{:finish, reason}]
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

  defp parse_delta(%{"type" => "text_delta", "text" => text}) do
    {:text_delta, text}
  end

  defp parse_delta(%{"type" => "thinking_delta", "thinking" => text}) do
    {:thinking_delta, text}
  end

  defp parse_delta(%{"type" => "input_json_delta", "partial_json" => json}) do
    {:tool_call_delta, json}
  end

  defp parse_delta(delta) do
    {:unknown, delta}
  end
end

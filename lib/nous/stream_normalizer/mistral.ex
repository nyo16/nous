defmodule Nous.StreamNormalizer.Mistral do
  @moduledoc """
  Stream normalizer for Mistral API.

  Handles Mistral's SSE format with string-keyed JSON maps.
  Also handles the pre-parsed `{:finish, "stop"}` tuple from SSE `[DONE]` events.

  ## Format

  Mistral streaming chunks arrive as:
  - Parsed JSON maps with string keys
  - `{:finish, "stop"}` tuple for stream completion
  """

  @behaviour Nous.StreamNormalizer

  @impl true
  def normalize_chunk(chunk) do
    case chunk do
      # Pre-parsed finish tuple from SSE [DONE] event
      {:finish, reason} when is_binary(reason) ->
        [{:finish, reason}]

      # Already a tuple event, pass through
      {event_type, _} = event when event_type in [:text_delta, :tool_call_delta, :thinking_delta, :error] ->
        [event]

      # Parsed JSON chunk
      chunk when is_map(chunk) ->
        [parse_json_chunk(chunk)]

      # Binary data (shouldn't happen if SSE parsing is done first)
      chunk when is_binary(chunk) ->
        parse_sse_chunk(chunk)

      _ ->
        [{:unknown, chunk}]
    end
  end

  @impl true
  def complete_response?(_chunk), do: false

  @impl true
  def convert_complete_response(_chunk), do: []

  defp parse_sse_chunk(data) do
    case data do
      "data: [DONE]" ->
        [{:finish, "stop"}]

      "data: " <> json_data ->
        case Jason.decode(json_data) do
          {:ok, json} -> [parse_json_chunk(json)]
          {:error, _} -> [{:unknown, data}]
        end

      _ ->
        [{:unknown, data}]
    end
  end

  defp parse_json_chunk(chunk) do
    choices = Map.get(chunk, "choices", [])
    choice = List.first(choices)

    if choice do
      delta = Map.get(choice, "delta", %{})
      content = Map.get(delta, "content")
      tool_calls = Map.get(delta, "tool_calls")
      finish_reason = Map.get(choice, "finish_reason")

      cond do
        content && content != "" ->
          {:text_delta, content}

        tool_calls ->
          {:tool_call_delta, tool_calls}

        finish_reason ->
          {:finish, finish_reason}

        true ->
          {:unknown, chunk}
      end
    else
      {:unknown, chunk}
    end
  end
end

defmodule Nous.StreamNormalizer.Gemini do
  @moduledoc """
  Stream normalizer for Google Gemini API.

  Handles Gemini's SSE streaming format where events arrive as JSON maps
  with a `candidates` array.

  ## Streaming Event Types

  | Gemini Event | Normalized Output |
  |-------------|-------------------|
  | `candidates[0].content.parts[0].text` | `{:text_delta, text}` |
  | `candidates[0].content.parts` with `functionCall` | `{:tool_call_delta, call}` |
  | `candidates[0].finishReason` present | `{:finish, reason}` |
  | `{:stream_done, reason}` | `{:finish, reason}` |
  | Error with `"error"` key | `{:error, message}` |
  """

  @behaviour Nous.StreamNormalizer

  @impl true
  def normalize_chunk({:stream_done, reason}) do
    [{:finish, reason}]
  end

  def normalize_chunk(%{"error" => error}) when is_map(error) do
    message = Map.get(error, "message", inspect(error))
    [{:error, message}]
  end

  def normalize_chunk(%{"candidates" => candidates} = chunk) when is_list(candidates) do
    case candidates do
      [candidate | _] -> parse_candidate(candidate, chunk)
      [] -> [{:unknown, chunk}]
    end
  end

  def normalize_chunk(chunk) do
    [{:unknown, chunk}]
  end

  @impl true
  def complete_response?(%{"candidates" => [candidate | _]}) when is_map(candidate) do
    Map.has_key?(candidate, "finishReason")
  end

  def complete_response?(_), do: false

  @impl true
  def convert_complete_response(%{"candidates" => [candidate | _]}) do
    parts = get_in(candidate, ["content", "parts"]) || []
    finish_reason = normalize_finish_reason(Map.get(candidate, "finishReason"))

    events = Enum.flat_map(parts, &parse_part/1)
    events ++ [{:finish, finish_reason}]
  end

  def convert_complete_response(chunk) do
    [{:unknown, chunk}]
  end

  defp parse_candidate(candidate, _chunk) do
    parts = get_in(candidate, ["content", "parts"]) || []
    finish_reason = Map.get(candidate, "finishReason")

    part_events = Enum.flat_map(parts, &parse_part/1)

    if finish_reason do
      part_events ++ [{:finish, normalize_finish_reason(finish_reason)}]
    else
      case part_events do
        [] -> [{:unknown, candidate}]
        events -> events
      end
    end
  end

  defp parse_part(%{"text" => text}) when text != "" do
    [{:text_delta, text}]
  end

  defp parse_part(%{"functionCall" => %{"name" => name, "args" => args}}) do
    [{:tool_call_delta, %{"name" => name, "arguments" => args}}]
  end

  defp parse_part(%{"functionCall" => %{"name" => name}}) do
    [{:tool_call_delta, %{"name" => name, "arguments" => %{}}}]
  end

  defp parse_part(_), do: []

  defp normalize_finish_reason("STOP"), do: "stop"
  defp normalize_finish_reason("MAX_TOKENS"), do: "length"
  defp normalize_finish_reason("SAFETY"), do: "safety"
  defp normalize_finish_reason(reason) when is_binary(reason), do: String.downcase(reason)
  defp normalize_finish_reason(_), do: "stop"
end

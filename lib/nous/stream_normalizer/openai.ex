defmodule Nous.StreamNormalizer.OpenAI do
  @moduledoc """
  Default stream normalizer for OpenAI-compatible providers.

  Handles:
  - OpenAI, Groq, OpenRouter (via OpenaiEx structs with atom keys)
  - LM Studio, vLLM, SGLang, Ollama (string-keyed maps)
  - Non-streaming fallback (message instead of delta)
  - Thinking/reasoning tokens (vLLM: reasoning, DeepSeek/SGLang: reasoning_content)

  ## Supported Providers

  | Provider | Format | Notes |
  |----------|--------|-------|
  | OpenAI | Atom keys | Via OpenaiEx structs |
  | Groq | Atom keys | Via OpenaiEx structs |
  | OpenRouter | Atom keys | Via OpenaiEx structs |
  | LM Studio | String keys | May return message instead of delta |
  | vLLM | String keys | SSE format, reasoning field |
  | SGLang | String keys | SSE format, reasoning_content field |
  | Ollama | String keys | OpenAI-compatible endpoint |
  | DeepSeek | String keys | reasoning_content field |
  """

  @behaviour Nous.StreamNormalizer

  @impl true
  def normalize_chunk(chunk) do
    if complete_response?(chunk) do
      convert_complete_response(chunk)
    else
      [parse_delta_chunk(chunk)]
    end
  end

  @impl true
  def complete_response?(chunk) do
    choices = get_choices(chunk)

    case choices do
      [choice | _] ->
        message = get_flexible(choice, :message)
        message != nil

      _ ->
        false
    end
  end

  @impl true
  def convert_complete_response(chunk) do
    choices = get_choices(chunk)

    case choices do
      [choice | _] ->
        message = get_flexible(choice, :message)
        content = get_flexible(message, :content)
        finish_reason = get_flexible(choice, :finish_reason) || "stop"

        events = []
        events = if content && content != "", do: [{:text_delta, content} | events], else: events
        events = [{:finish, finish_reason} | events]

        Enum.reverse(events)

      _ ->
        [{:unknown, chunk}]
    end
  end

  # Parse standard streaming delta chunk
  defp parse_delta_chunk(chunk) do
    choices = get_choices(chunk)
    choice = List.first(choices)

    if choice do
      delta = get_flexible(choice, :delta) || %{}
      content = get_flexible(delta, :content)
      tool_calls = get_flexible(delta, :tool_calls)
      finish_reason = get_flexible(choice, :finish_reason)

      # Thinking/reasoning content
      # vLLM uses "reasoning", DeepSeek/SGLang use "reasoning_content"
      reasoning = get_flexible(delta, :reasoning) || get_flexible(delta, :reasoning_content)

      cond do
        reasoning && reasoning != "" ->
          {:thinking_delta, reasoning}

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

  # Get choices from chunk, handling struct, atom-map, and string-map formats
  defp get_choices(chunk) do
    cond do
      is_struct(chunk) && Map.has_key?(chunk, :choices) ->
        chunk.choices || []

      is_map(chunk) && Map.has_key?(chunk, :choices) ->
        chunk.choices || []

      is_map(chunk) && Map.has_key?(chunk, "choices") ->
        chunk["choices"] || []

      true ->
        []
    end
  end

  # Flexible field access - tries atom key first, then string key
  defp get_flexible(nil, _key), do: nil

  defp get_flexible(data, key) when is_struct(data) do
    Map.get(data, key)
  end

  defp get_flexible(data, key) when is_map(data) and is_atom(key) do
    cond do
      Map.has_key?(data, key) -> Map.get(data, key)
      Map.has_key?(data, Atom.to_string(key)) -> Map.get(data, Atom.to_string(key))
      true -> nil
    end
  end

  defp get_flexible(_, _), do: nil
end

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
    cond do
      # Handle stream done signal from SSE [DONE] event
      match?({:stream_done, _}, chunk) ->
        {:stream_done, reason} = chunk
        [{:finish, reason}]

      complete_response?(chunk) ->
        convert_complete_response(chunk)

      true ->
        parse_delta_chunk(chunk)
    end
  end

  # Extract a {:usage, %Usage{}} event from the chunk's "usage" field if
  # present. OpenAI sends a final chunk with empty choices and a populated
  # usage map when stream_options.include_usage is enabled.
  defp maybe_usage_event(chunk) do
    case get_flexible(chunk, :usage) do
      nil -> []
      usage -> [{:usage, Nous.Messages.OpenAI.parse_usage(usage)}]
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
        reasoning = get_flexible(message, :reasoning) || get_flexible(message, :reasoning_content)
        tool_calls = get_flexible(message, :tool_calls)
        finish_reason = get_flexible(choice, :finish_reason) || "stop"

        # Build events in order: thinking -> text -> tool_calls -> finish
        # NOTE: previously this path read only :content/:reasoning and silently
        # dropped :tool_calls, so non-streaming "complete response" returns
        # (common from LM Studio / vLLM / Ollama / llamacpp when stream:true
        # degenerates) lost tool calls and the agent saw finish_reason "stop"
        # instead of "tool_calls".
        []
        |> maybe_prepend(reasoning, &{:thinking_delta, &1})
        |> maybe_prepend(content, &{:text_delta, &1})
        |> maybe_prepend_tool_calls(tool_calls)
        |> Kernel.++([{:finish, finish_reason}])

      _ ->
        [{:unknown, chunk}]
    end
  end

  defp maybe_prepend(events, value, builder) when is_binary(value) and value != "" do
    events ++ [builder.(value)]
  end

  defp maybe_prepend(events, _value, _builder), do: events

  defp maybe_prepend_tool_calls(events, calls) when is_list(calls) and calls != [] do
    events ++ [{:tool_call_delta, calls}]
  end

  defp maybe_prepend_tool_calls(events, _), do: events

  # Parse standard streaming delta chunk.
  #
  # Returns a LIST of events because a single chunk can carry multiple
  # signals at once - notably OpenAI sends `tool_calls + finish_reason:
  # "tool_calls"` in the same final delta, and providers that interleave
  # thinking/content can put both `reasoning` and `content` in one chunk.
  # Previously this returned a single event via cond/0 and silently dropped
  # all but one signal per chunk.
  defp parse_delta_chunk(chunk) do
    choices = get_choices(chunk)
    choice = List.first(choices)
    usage_events = maybe_usage_event(chunk)

    if choice do
      delta = get_flexible(choice, :delta) || %{}
      content = get_flexible(delta, :content)
      tool_calls = get_flexible(delta, :tool_calls)
      finish_reason = get_flexible(choice, :finish_reason)

      # vLLM uses "reasoning", DeepSeek/SGLang use "reasoning_content"
      reasoning = get_flexible(delta, :reasoning) || get_flexible(delta, :reasoning_content)

      events =
        []
        |> append_if(reasoning && reasoning != "", {:thinking_delta, reasoning})
        |> append_if(content && content != "", {:text_delta, content})
        |> append_if(is_list(tool_calls) and tool_calls != [], {:tool_call_delta, tool_calls})
        |> append_if(not is_nil(finish_reason), {:finish, finish_reason})

      cond do
        events != [] -> events ++ usage_events
        usage_events != [] -> usage_events
        true -> [{:unknown, chunk}]
      end
    else
      # OpenAI's final usage-only chunk has empty choices and a populated
      # `usage` field. Emit just the usage event in that case.
      if usage_events == [], do: [{:unknown, chunk}], else: usage_events
    end
  end

  defp append_if(list, true, event), do: list ++ [event]
  defp append_if(list, _, _event), do: list

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

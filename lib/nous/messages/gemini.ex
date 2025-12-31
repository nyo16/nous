defmodule Nous.Messages.Gemini do
  @moduledoc """
  Gemini format message conversion.

  Handles conversion between internal Message structs and Google Gemini API format.
  """

  alias Nous.{Message, Usage}
  alias Nous.Message.ContentPart

  @doc """
  Convert messages to Gemini format.

  Returns `{system_prompt, contents}` where system prompt is extracted
  and messages are converted to Gemini contents format.

  ## Examples

      iex> messages = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.Gemini.to_format(messages)
      {"Be helpful", [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]}

  """
  @spec to_format([Message.t()]) :: {String.t() | nil, [map()]}
  def to_format(messages) when is_list(messages) do
    {system_messages, other_messages} = Enum.split_with(messages, &Message.is_system?/1)

    system_prompt = case system_messages do
      [] -> nil
      msgs ->
        msgs
        |> Enum.map(&Message.extract_text/1)
        |> Enum.join("\n\n")
    end

    gemini_contents = Enum.map(other_messages, &message_to_gemini/1)

    {system_prompt, gemini_contents}
  end

  @doc """
  Parse Gemini response into a Message.

  ## Examples

      iex> response = %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]}
      iex> Messages.Gemini.from_response(response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_response(map()) :: Message.t()
  def from_response(response) when is_map(response) do
    candidates = Map.get(response, "candidates", [])
    usage_data = Map.get(response, "usageMetadata", %{})

    candidate = List.first(candidates) || %{}
    content_data = Map.get(candidate, "content", %{})
    parts_data = Map.get(content_data, "parts", [])

    {content_parts, tool_calls} = parse_content(parts_data)

    attrs = %{
      role: :assistant,
      content: consolidate_content_parts(content_parts),
      metadata: %{
        model_name: "gemini-model",
        usage: parse_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

    Message.new!(attrs)
  end

  @doc """
  Convert Gemini format messages to internal Message structs.
  """
  @spec from_messages([map()]) :: [Message.t()]
  def from_messages(gemini_messages) when is_list(gemini_messages) do
    Enum.map(gemini_messages, fn msg ->
      role = case Map.get(msg, "role") do
        "user" -> :user
        "model" -> :assistant
        _ -> :user
      end

      parts = Map.get(msg, "parts", [])
      {text_content, tool_calls} = parse_parts(parts)

      attrs = %{role: role, content: text_content}
      attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

      Message.new!(attrs)
    end)
  end

  # Private helpers

  defp message_to_gemini(%Message{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "parts" => [%{"text" => content}]}
  end

  defp message_to_gemini(%Message{role: :user, content: content}) when is_list(content) do
    gemini_parts = Enum.map(content, &content_part_to_gemini/1)
    %{"role" => "user", "parts" => gemini_parts}
  end

  defp message_to_gemini(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    parts = []

    parts = if content && content != "", do: [%{"text" => content} | parts], else: parts

    parts = if length(tool_calls) > 0 do
      tool_parts = Enum.map(tool_calls, fn call ->
        %{
          "functionCall" => %{
            "name" => Map.get(call, "name") || Map.get(call, :name),
            "args" => Map.get(call, "arguments") || Map.get(call, :arguments, %{})
          }
        }
      end)
      tool_parts ++ parts
    else
      parts
    end

    %{"role" => "model", "parts" => Enum.reverse(parts)}
  end

  defp message_to_gemini(%Message{role: :tool, content: content, tool_call_id: tool_call_id}) do
    # Gemini handles tool results as user messages with functionResponse
    response = case Jason.decode(content) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"result" => content}  # Treat as plain text
    end

    %{
      "role" => "user",
      "parts" => [%{
        "functionResponse" => %{
          "name" => tool_call_id,
          "response" => response
        }
      }]
    }
  end

  defp content_part_to_gemini(%ContentPart{type: :text, content: text}) do
    %{"text" => text}
  end

  defp content_part_to_gemini(%ContentPart{} = part) do
    # Convert to text representation for Gemini
    %{"text" => ContentPart.to_text([part])}
  end

  defp parse_content(parts_data) when is_list(parts_data) do
    {content_parts, tool_calls} = Enum.reduce(parts_data, {[], []}, fn item, {parts, tools} ->
      case item do
        %{"text" => text} ->
          {[ContentPart.text(text) | parts], tools}

        %{"functionCall" => %{"name" => name, "args" => args}} ->
          tool_call = %{
            "id" => "gemini_#{:rand.uniform(10000)}",
            "name" => name,
            "arguments" => args
          }
          {parts, [tool_call | tools]}

        _ ->
          {parts, tools}
      end
    end)

    {Enum.reverse(content_parts), Enum.reverse(tool_calls)}
  end

  defp parse_parts(parts) when is_list(parts) do
    {text_parts, tool_calls} = Enum.reduce(parts, {[], []}, fn part, {texts, tools} ->
      cond do
        Map.has_key?(part, "text") ->
          text = Map.get(part, "text", "")
          {[text | texts], tools}
        Map.has_key?(part, "functionCall") ->
          function_call = Map.get(part, "functionCall")
          tool_call = %{
            "id" => "call_#{:rand.uniform(1000000)}",  # Generate random ID since Gemini doesn't provide one
            "name" => Map.get(function_call, "name"),
            "arguments" => Map.get(function_call, "args", %{})
          }
          {texts, [tool_call | tools]}
        true ->
          {texts, tools}
      end
    end)

    text_content = text_parts |> Enum.reverse() |> Enum.join(" ") |> String.trim()
    # Add space after text if there are tool calls
    text_content = if text_content != "" and length(tool_calls) > 0 do
      text_content <> " "
    else
      text_content
    end

    {text_content, Enum.reverse(tool_calls)}
  end

  defp parse_usage(usage_data) when is_map(usage_data) do
    %Usage{
      input_tokens: Map.get(usage_data, "promptTokenCount", 0),
      output_tokens: Map.get(usage_data, "candidatesTokenCount", 0),
      total_tokens: Map.get(usage_data, "totalTokenCount", 0)
    }
  end

  defp parse_usage(_), do: %Usage{}

  defp consolidate_content_parts([]), do: ""
  defp consolidate_content_parts([%ContentPart{type: :text, content: content}]), do: content
  defp consolidate_content_parts(parts) when is_list(parts), do: parts
end

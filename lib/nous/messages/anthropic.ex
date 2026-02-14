defmodule Nous.Messages.Anthropic do
  @moduledoc """
  Anthropic format message conversion.

  Handles conversion between internal Message structs and Anthropic API format.
  """

  alias Nous.{Message, Usage}
  alias Nous.Message.ContentPart

  @doc """
  Convert messages to Anthropic format.

  Returns `{system_prompt, messages}` where system prompt is extracted
  and combined, and messages are converted to Anthropic format.

  ## Examples

      iex> messages = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.Anthropic.to_format(messages)
      {"Be helpful", [%{"role" => "user", "content" => "Hello"}]}

  """
  @spec to_format([Message.t()]) :: {String.t() | nil, [map()]}
  def to_format(messages) when is_list(messages) do
    {system_messages, other_messages} = Enum.split_with(messages, &Message.is_system?/1)

    system_prompt =
      case system_messages do
        [] ->
          nil

        msgs ->
          msgs
          |> Enum.map(&Message.extract_text/1)
          |> Enum.join("\n\n")
      end

    anthropic_messages = Enum.map(other_messages, &message_to_anthropic/1)

    {system_prompt, anthropic_messages}
  end

  @doc """
  Parse Anthropic response into a Message.

  ## Examples

      iex> response = %{"content" => [%{"type" => "text", "text" => "Hello"}], "model" => "claude-3"}
      iex> Messages.Anthropic.from_response(response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_response(map()) :: Message.t()
  def from_response(response) when is_map(response) do
    content_data = Map.get(response, "content", [])
    model = Map.get(response, "model", "claude")
    usage_data = Map.get(response, "usage", %{})

    {content_parts, tool_calls} = parse_content(content_data)

    attrs = %{
      role: :assistant,
      content: consolidate_content_parts(content_parts),
      metadata: %{
        model_name: model,
        usage: parse_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

    Message.new!(attrs)
  end

  @doc """
  Convert Anthropic format messages to internal Message structs.
  """
  @spec from_messages([map()]) :: [Message.t()]
  def from_messages(anthropic_messages) when is_list(anthropic_messages) do
    Enum.map(anthropic_messages, fn msg ->
      role =
        case Map.get(msg, "role") do
          "user" -> :user
          "assistant" -> :assistant
          _ -> :user
        end

      content = Map.get(msg, "content")

      {text_content, tool_calls} =
        case content do
          content when is_binary(content) ->
            {content, []}

          content when is_list(content) ->
            parse_content_parts(content)

          _ ->
            {inspect(content), []}
        end

      attrs = %{role: role, content: text_content}
      attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

      Message.new!(attrs)
    end)
  end

  # Private helpers

  defp message_to_anthropic(%Message{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp message_to_anthropic(%Message{role: :user, content: content}) when is_list(content) do
    anthropic_content = Enum.map(content, &content_part_to_anthropic/1)
    %{"role" => "user", "content" => anthropic_content}
  end

  defp message_to_anthropic(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    parts = []

    parts =
      if content && content != "",
        do: [%{"type" => "text", "text" => content} | parts],
        else: parts

    parts =
      if length(tool_calls) > 0 do
        tool_parts =
          Enum.map(tool_calls, fn call ->
            %{
              "type" => "tool_use",
              "id" => Map.get(call, "id") || Map.get(call, :id),
              "name" => Map.get(call, "name") || Map.get(call, :name),
              "input" => Map.get(call, "arguments") || Map.get(call, :arguments, %{})
            }
          end)

        tool_parts ++ parts
      else
        parts
      end

    %{"role" => "assistant", "content" => Enum.reverse(parts)}
  end

  defp message_to_anthropic(%Message{role: :tool, content: content, tool_call_id: tool_call_id}) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_call_id,
          "content" => content
        }
      ]
    }
  end

  defp content_part_to_anthropic(%ContentPart{type: :text, content: text}) do
    %{"type" => "text", "text" => text}
  end

  defp content_part_to_anthropic(%ContentPart{type: :image_url, content: url}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => "image/jpeg",
        "data" => url
      }
    }
  end

  defp content_part_to_anthropic(%ContentPart{} = part) do
    # Fallback: convert to text
    %{"type" => "text", "text" => ContentPart.to_text([part])}
  end

  defp parse_content(content_data) when is_list(content_data) do
    {content_parts, tool_calls} =
      Enum.reduce(content_data, {[], []}, fn item, {parts, tools} ->
        case item do
          %{"type" => "text", "text" => text} ->
            {[ContentPart.text(text) | parts], tools}

          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
            tool_call = %{"id" => id, "name" => name, "arguments" => input}
            {parts, [tool_call | tools]}

          _ ->
            {parts, tools}
        end
      end)

    {Enum.reverse(content_parts), Enum.reverse(tool_calls)}
  end

  defp parse_content_parts(content_parts) when is_list(content_parts) do
    {text_parts, tool_calls} =
      Enum.reduce(content_parts, {[], []}, fn part, {texts, tools} ->
        case Map.get(part, "type") do
          "text" ->
            text = Map.get(part, "text", "")
            {[text | texts], tools}

          "tool_use" ->
            tool_call = %{
              "id" => Map.get(part, "id"),
              "name" => Map.get(part, "name"),
              "arguments" => Map.get(part, "input", %{})
            }

            {texts, [tool_call | tools]}

          _ ->
            {texts, tools}
        end
      end)

    text_content = text_parts |> Enum.reverse() |> Enum.join(" ") |> String.trim()
    {text_content, Enum.reverse(tool_calls)}
  end

  defp parse_usage(usage_data) when is_map(usage_data) do
    %Usage{
      input_tokens: Map.get(usage_data, "input_tokens", 0),
      output_tokens: Map.get(usage_data, "output_tokens", 0),
      total_tokens:
        Map.get(usage_data, "input_tokens", 0) + Map.get(usage_data, "output_tokens", 0)
    }
  end

  defp parse_usage(_), do: %Usage{}

  defp consolidate_content_parts([]), do: ""
  defp consolidate_content_parts([%ContentPart{type: :text, content: content}]), do: content
  defp consolidate_content_parts(parts) when is_list(parts), do: parts
end

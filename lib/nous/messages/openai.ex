defmodule Nous.Messages.OpenAI do
  @moduledoc """
  OpenAI format message conversion.

  Handles conversion between internal Message structs and OpenAI API format.
  """

  alias Nous.{Message, Usage}
  alias Nous.Message.ContentPart

  require Logger

  @doc """
  Convert messages to OpenAI format.

  ## Examples

      iex> messages = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.OpenAI.to_format(messages)
      [
        %{"role" => "system", "content" => "Be helpful"},
        %{"role" => "user", "content" => "Hello"}
      ]

  """
  @spec to_format([Message.t()]) :: [map()]
  def to_format(messages) when is_list(messages) do
    Enum.map(messages, &message_to_openai/1)
  end

  @doc """
  Parse OpenAI response into a Message.

  ## Examples

      iex> response = %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}]}
      iex> Messages.OpenAI.from_response(response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_response(map()) :: Message.t()
  def from_response(response) when is_map(response) do
    choices = Map.get(response, "choices") || Map.get(response, :choices) || []
    choice = List.first(choices)

    message_data =
      if choice do
        Map.get(choice, "message") || Map.get(choice, :message)
      end

    content =
      if message_data do
        Map.get(message_data, "content") || Map.get(message_data, :content)
      end

    tool_calls =
      if message_data do
        Map.get(message_data, "tool_calls") || Map.get(message_data, :tool_calls) || []
      else
        []
      end

    usage_data = Map.get(response, "usage") || Map.get(response, :usage)
    model_name = Map.get(response, "model") || Map.get(response, :model)

    # Convert tool calls
    converted_tool_calls = Enum.map(tool_calls, &parse_tool_call/1)

    # Build message attributes
    attrs = %{
      role: :assistant,
      metadata: %{
        model_name: model_name,
        usage: parse_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if content && content != "", do: Map.put(attrs, :content, content), else: attrs

    attrs =
      if length(converted_tool_calls) > 0,
        do: Map.put(attrs, :tool_calls, converted_tool_calls),
        else: attrs

    Message.new!(attrs)
  end

  @doc """
  Convert OpenAI format messages to internal Message structs.
  """
  @spec from_messages([map()]) :: [Message.t()]
  def from_messages(openai_messages) when is_list(openai_messages) do
    Enum.map(openai_messages, fn msg ->
      role =
        case Map.get(msg, :role) || Map.get(msg, "role") do
          "system" -> :system
          "user" -> :user
          "assistant" -> :assistant
          "tool" -> :tool
          other -> other
        end

      content = Map.get(msg, :content) || Map.get(msg, "content")

      Message.new!(%{role: role, content: content || ""})
    end)
  end

  # Private helpers

  defp message_to_openai(%Message{role: :system, content: content}) when is_binary(content) do
    %{"role" => "system", "content" => content}
  end

  defp message_to_openai(%Message{role: :user, metadata: %{content_parts: content_parts}})
       when is_list(content_parts) do
    openai_content = Enum.map(content_parts, &content_part_to_openai/1)
    %{"role" => "user", "content" => openai_content}
  end

  defp message_to_openai(%Message{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp message_to_openai(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    if length(tool_calls) > 0 do
      # Assistant message with tool calls
      openai_tool_calls = Enum.map(tool_calls, &tool_call_to_openai/1)

      %{
        "role" => "assistant",
        "content" => content || "",
        "tool_calls" => openai_tool_calls
      }
    else
      # Simple assistant message
      %{"role" => "assistant", "content" => content || ""}
    end
  end

  defp message_to_openai(%Message{
         role: :tool,
         content: content,
         tool_call_id: tool_call_id,
         name: _name
       }) do
    %{"role" => "tool", "content" => content, "tool_call_id" => tool_call_id}
  end

  defp content_part_to_openai(%ContentPart{type: :text, content: text}) do
    %{"type" => "text", "text" => text}
  end

  defp content_part_to_openai(%ContentPart{type: :image_url, content: url}) do
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp content_part_to_openai(%ContentPart{} = part) do
    # Fallback: convert to text representation
    %{"type" => "text", "text" => ContentPart.to_text([part])}
  end

  defp tool_call_to_openai(tool_call) when is_map(tool_call) do
    %{
      "id" => Map.get(tool_call, "id") || Map.get(tool_call, :id),
      "type" => "function",
      "function" => %{
        "name" => Map.get(tool_call, "name") || Map.get(tool_call, :name),
        "arguments" =>
          Jason.encode!(Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments, %{}))
      }
    }
  end

  defp parse_tool_call(tool_call) when is_map(tool_call) do
    id = Map.get(tool_call, "id") || Map.get(tool_call, :id)
    func = Map.get(tool_call, "function") || Map.get(tool_call, :function)
    name = Map.get(func, "name") || Map.get(func, :name)
    arguments = Map.get(func, "arguments") || Map.get(func, :arguments)

    parsed_args =
      case Jason.decode(arguments) do
        {:ok, decoded_args} ->
          decoded_args

        {:error, _} ->
          Logger.warning("Failed to decode tool arguments: #{inspect(arguments)}")
          %{"error" => "Invalid JSON arguments", "raw" => arguments}
      end

    %{
      "id" => id,
      "name" => name,
      "arguments" => parsed_args
    }
  end

  defp parse_usage(usage_data) when is_map(usage_data) do
    %Usage{
      requests: 1,
      input_tokens:
        Map.get(usage_data, "prompt_tokens") || Map.get(usage_data, :prompt_tokens) || 0,
      output_tokens:
        Map.get(usage_data, "completion_tokens") || Map.get(usage_data, :completion_tokens) || 0,
      total_tokens: Map.get(usage_data, "total_tokens") || Map.get(usage_data, :total_tokens) || 0
    }
  end

  defp parse_usage(nil), do: %Usage{}
end

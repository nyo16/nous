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

    reasoning_content =
      if message_data do
        Map.get(message_data, "reasoning_content") || Map.get(message_data, :reasoning_content)
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
      if reasoning_content && reasoning_content != "",
        do: Map.put(attrs, :reasoning_content, reasoning_content),
        else: attrs

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

  defp message_to_openai(%Message{
         role: :assistant,
         content: content,
         reasoning_content: reasoning,
         tool_calls: tool_calls
       }) do
    base = %{
      "role" => "assistant",
      "content" => content || ""
    }

    base = if reasoning, do: Map.put(base, "reasoning_content", reasoning), else: base

    if length(tool_calls) > 0 do
      # Assistant message with tool calls
      openai_tool_calls = Enum.map(tool_calls, &tool_call_to_openai/1)

      Map.put(base, "tool_calls", openai_tool_calls)
    else
      # Simple assistant message
      base
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

  defp content_part_to_openai(%ContentPart{type: :image_url, content: url, options: opts}) do
    image_url_map = %{"url" => url}

    image_url_map =
      case Map.get(opts, :detail) do
        nil -> image_url_map
        detail -> Map.put(image_url_map, "detail", detail)
      end

    %{"type" => "image_url", "image_url" => image_url_map}
  end

  defp content_part_to_openai(%ContentPart{type: :image, content: data, options: opts}) do
    media_type = Map.get(opts, :media_type, "image/png")
    data_url = "data:#{media_type};base64,#{data}"
    %{"type" => "image_url", "image_url" => %{"url" => data_url}}
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
          JSON.encode!(Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments, %{}))
      }
    }
  end

  defp parse_tool_call(tool_call) when is_map(tool_call) do
    id = Map.get(tool_call, "id") || Map.get(tool_call, :id)
    func = Map.get(tool_call, "function") || Map.get(tool_call, :function)
    name = Map.get(func, "name") || Map.get(func, :name)
    arguments = Map.get(func, "arguments") || Map.get(func, :arguments)

    %{
      "id" => id,
      "name" => name,
      "arguments" => decode_arguments(arguments)
    }
  end

  @doc """
  Decode an OpenAI tool-call `arguments` JSON string into a map.

  Falls back to `%{"error" => "Invalid JSON arguments", "raw" => raw}` and logs a
  warning when the JSON is malformed. Used by both the non-streaming response
  parser and the streaming `ToolCallAccumulator`.
  """
  @spec decode_arguments(String.t() | nil) :: map()
  def decode_arguments(nil), do: %{}
  def decode_arguments(""), do: %{}

  def decode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded_args} when is_map(decoded_args) ->
        decoded_args

      {:ok, other} ->
        Logger.warning("Tool arguments decoded to non-map: #{inspect(other)}")
        %{"error" => "Invalid JSON arguments", "raw" => arguments}

      {:error, _} ->
        Logger.warning("Failed to decode tool arguments: #{inspect(arguments)}")
        %{"error" => "Invalid JSON arguments", "raw" => arguments}
    end
  end

  @doc """
  Parse an OpenAI-format usage map into a `%Nous.Usage{}` struct.

  Returns an empty `%Usage{}` for `nil`. Accepts both atom and string keys.
  """
  @spec parse_usage(map() | nil) :: Usage.t()
  def parse_usage(usage_data) when is_map(usage_data) do
    %Usage{
      requests: 1,
      input_tokens:
        Map.get(usage_data, "prompt_tokens") || Map.get(usage_data, :prompt_tokens) || 0,
      output_tokens:
        Map.get(usage_data, "completion_tokens") || Map.get(usage_data, :completion_tokens) || 0,
      total_tokens: Map.get(usage_data, "total_tokens") || Map.get(usage_data, :total_tokens) || 0
    }
  end

  def parse_usage(nil), do: %Usage{}
end

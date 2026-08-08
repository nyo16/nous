defmodule Nous.Messages.OpenAI do
  @moduledoc """
  OpenAI format message conversion.

  Handles conversion between internal Message structs and OpenAI API format.
  """

  alias Nous.{Message, Usage}
  alias Nous.Message.ContentPart
  alias Nous.Messages.Cache

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
    Cache.map(__MODULE__, messages, &message_to_openai/1)
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
    message_data = response_message(response)

    attrs =
      %{
        role: :assistant,
        metadata: %{
          model_name: fetch_either(response, "model", :model),
          usage: parse_usage(fetch_either(response, "usage", :usage)),
          timestamp: DateTime.utc_now()
        }
      }
      |> put_present(:content, fetch_either(message_data, "content", :content))
      |> put_present(
        :reasoning_content,
        fetch_either(message_data, "reasoning_content", :reasoning_content)
      )
      |> put_tool_calls(fetch_either(message_data, "tool_calls", :tool_calls) || [])

    Message.new!(attrs)
  end

  # OpenAI-compatible backends are inconsistent about string vs atom keys, and
  # `choices`/`message` are absent entirely on error-shaped responses — hence the
  # nil-tolerant lookup rather than a bare Map.get/2.
  defp fetch_either(nil, _string_key, _atom_key), do: nil

  defp fetch_either(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp response_message(response) do
    choices = fetch_either(response, "choices", :choices) || []
    choice = List.first(choices)

    if choice, do: fetch_either(choice, "message", :message)
  end

  defp put_present(attrs, _key, value) when value in [nil, ""], do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_tool_calls(attrs, []), do: attrs

  defp put_tool_calls(attrs, tool_calls) do
    Map.put(attrs, :tool_calls, Enum.map(tool_calls, &parse_tool_call/1))
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
    # Default to %{} — an OpenAI-compatible backend may emit a tool_call without
    # the "function" wrapper; Map.get(nil, _) would raise BadMapError and crash
    # the whole response parse. Mirrors the streaming accumulator's guard.
    func = Map.get(tool_call, "function") || Map.get(tool_call, :function) || %{}
    name = Map.get(func, "name") || Map.get(func, :name)
    arguments = Map.get(func, "arguments") || Map.get(func, :arguments)

    case decode_arguments(arguments) do
      {:ok, decoded} ->
        %{"id" => id, "name" => name, "arguments" => decoded}

      {:error, {:invalid_json, raw}} ->
        %{"id" => id, "name" => name, "arguments" => %{}, "_invalid_arguments" => raw}
    end
  end

  @doc """
  Decode an OpenAI tool-call `arguments` JSON string into a map.

  Returns `{:ok, map()}` on success, `{:error, {:invalid_json, raw}}` on
  malformed JSON or non-object payload. Used by both the non-streaming
  response parser and the streaming `ToolCallAccumulator`; callers tag the
  tool_call with `"_invalid_arguments"` so the agent runner can surface a
  proper error tool result instead of invoking the tool with bogus args.
  """
  @spec decode_arguments(String.t() | nil) ::
          {:ok, map()} | {:error, {:invalid_json, String.t()}}
  def decode_arguments(nil), do: {:ok, %{}}
  def decode_arguments(""), do: {:ok, %{}}

  def decode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded_args} when is_map(decoded_args) ->
        {:ok, decoded_args}

      {:ok, other} ->
        Logger.warning("Tool arguments decoded to non-map: #{inspect(other)}")
        {:error, {:invalid_json, arguments}}

      {:error, _} ->
        Logger.warning("Failed to decode tool arguments: #{inspect(arguments)}")
        {:error, {:invalid_json, arguments}}
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

defmodule Nous.Messages do
  @moduledoc """
  Utilities for working with conversations and message lists.

  This module provides functions to:
  - Work with lists of messages (conversations)
  - Convert between internal format and provider-specific formats
  - Extract data from conversations
  - Parse provider responses into internal format

  ## Message Format

  We use `Nous.Message` structs with standard roles:
  - `%Message{role: :system}` - System instructions
  - `%Message{role: :user}` - User input (text or multi-modal)
  - `%Message{role: :assistant}` - AI responses (with optional tool calls)
  - `%Message{role: :tool}` - Tool execution results

  ## Example

      # Build conversation
      conversation = [
        Message.system("You are a helpful assistant"),
        Message.user("What is 2+2?"),
        Message.assistant("2+2 equals 4")
      ]

      # Convert to provider format
      openai_messages = Messages.to_openai_format(conversation)
      anthropic_messages = Messages.to_anthropic_format(conversation)

      # Parse provider response
      response = Messages.from_openai_response(openai_response)
      # => %Message{role: :assistant, content: "4"}

  """

  require Logger

  alias Nous.{Message, Usage}
  alias Nous.Message.ContentPart

  # Conversation utilities

  @doc """
  Extract text content from messages in a conversation.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.extract_text(conversation)
      ["Be helpful", "Hello"]

      iex> message = Message.user("Hi there")
      iex> Messages.extract_text(message)
      "Hi there"

  """
  @spec extract_text([Message.t()] | Message.t()) :: [String.t()] | String.t()
  def extract_text(messages) when is_list(messages) do
    Enum.map(messages, &Message.extract_text/1)
  end

  def extract_text(%Message{} = message) do
    Message.extract_text(message)
  end

  @doc """
  Extract tool calls from a conversation.

  Returns all tool calls found in assistant messages.

  ## Examples

      iex> conversation = [
      ...>   Message.assistant("Let me search", tool_calls: [%{id: "call_1", name: "search", arguments: %{}}])
      ...> ]
      iex> Messages.extract_tool_calls(conversation)
      [%{id: "call_1", name: "search", arguments: %{}}]

  """
  @spec extract_tool_calls([Message.t()]) :: [map()]
  def extract_tool_calls(messages) when is_list(messages) do
    messages
    |> Enum.filter(&Message.from_assistant?/1)
    |> Enum.flat_map(& &1.tool_calls)
  end

  @doc """
  Find messages by role in a conversation.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.find_by_role(conversation, :system)
      [%Message{role: :system, content: "Be helpful"}]

  """
  @spec find_by_role([Message.t()], atom()) :: [Message.t()]
  def find_by_role(messages, role) when is_list(messages) do
    Enum.filter(messages, &(&1.role == role))
  end

  @doc """
  Get the last message from a conversation.

  ## Examples

      iex> conversation = [Message.user("Hi"), Message.assistant("Hello")]
      iex> Messages.last_message(conversation)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec last_message([Message.t()]) :: Message.t() | nil
  def last_message([]), do: nil
  def last_message(messages) when is_list(messages), do: List.last(messages)

  @doc """
  Count messages by role.

  ## Examples

      iex> conversation = [Message.system("Hi"), Message.user("Hello"), Message.user("World")]
      iex> Messages.count_by_role(conversation)
      %{system: 1, user: 2, assistant: 0, tool: 0}

  """
  @spec count_by_role([Message.t()]) :: map()
  def count_by_role(messages) when is_list(messages) do
    base_counts = %{system: 0, user: 0, assistant: 0, tool: 0}

    messages
    |> Enum.group_by(& &1.role)
    |> Enum.map(fn {role, msgs} -> {role, length(msgs)} end)
    |> Map.new()
    |> then(&Map.merge(base_counts, &1))
  end

  # Provider format conversion

  @doc """
  Convert messages to OpenAI format.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_openai_format(conversation)
      [
        %{role: "system", content: "Be helpful"},
        %{role: "user", content: "Hello"}
      ]

  """
  @spec to_openai_format([Message.t()]) :: [map()]
  def to_openai_format(messages) when is_list(messages) do
    Enum.map(messages, &message_to_openai/1)
  end

  @doc """
  Convert messages to Anthropic format.

  Returns `{system_prompt, messages}` where system prompt is extracted
  and combined, and messages are converted to Anthropic format.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_anthropic_format(conversation)
      {"Be helpful", [%{role: "user", content: "Hello"}]}

  """
  @spec to_anthropic_format([Message.t()]) :: {String.t() | nil, [map()]}
  def to_anthropic_format(messages) when is_list(messages) do
    {system_messages, other_messages} = Enum.split_with(messages, &Message.is_system?/1)

    system_prompt = case system_messages do
      [] -> nil
      msgs ->
        msgs
        |> Enum.map(&Message.extract_text/1)
        |> Enum.join("\n\n")
    end

    anthropic_messages = Enum.map(other_messages, &message_to_anthropic/1)

    {system_prompt, anthropic_messages}
  end

  @doc """
  Convert messages to Gemini format.

  Returns `{system_prompt, contents}` where system prompt is extracted
  and messages are converted to Gemini contents format.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_gemini_format(conversation)
      {"Be helpful", [%{role: "user", parts: [%{text: "Hello"}]}]}

  """
  @spec to_gemini_format([Message.t()]) :: {String.t() | nil, [map()]}
  def to_gemini_format(messages) when is_list(messages) do
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

  # Generic provider conversion (from earlier implementation)

  @doc """
  Convert messages to provider-specific format.

  Dispatches to the appropriate provider-specific conversion function.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_provider_format(conversation, :openai)
      [%{"role" => "system", "content" => "Be helpful"}, %{"role" => "user", "content" => "Hello"}]

      iex> Messages.to_provider_format(conversation, :anthropic)
      {"Be helpful", [%{role: "user", content: "Hello"}]}

  """
  @spec to_provider_format([Message.t()], atom()) :: any()
  def to_provider_format(messages, provider) when is_list(messages) do
    case provider do
      :openai -> to_openai_format(messages)
      :groq -> to_openai_format(messages)
      :lmstudio -> to_openai_format(messages)
      :anthropic -> to_anthropic_format(messages)
      :gemini -> to_gemini_format(messages)
      :mistral -> to_openai_format(messages)
      _ ->
        raise ArgumentError, """
        Unsupported provider: #{inspect(provider)}

        Supported providers: :openai, :groq, :lmstudio, :anthropic, :gemini, :mistral
        """
    end
  end

  # Response parsing

  @doc """
  Parse OpenAI response into a Message.

  ## Examples

      iex> openai_response = %{
      ...>   "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}],
      ...>   "usage" => %{"total_tokens" => 10}
      ...> }
      iex> Messages.from_openai_response(openai_response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_openai_response(map()) :: Message.t()
  def from_openai_response(response) when is_map(response) do
    choices = Map.get(response, "choices") || Map.get(response, :choices) || []
    choice = List.first(choices)

    message_data = if choice do
      Map.get(choice, "message") || Map.get(choice, :message)
    end

    content = if message_data do
      Map.get(message_data, "content") || Map.get(message_data, :content)
    end

    tool_calls = if message_data do
      Map.get(message_data, "tool_calls") || Map.get(message_data, :tool_calls) || []
    else
      []
    end

    usage_data = Map.get(response, "usage") || Map.get(response, :usage)
    model_name = Map.get(response, "model") || Map.get(response, :model)

    # Convert tool calls
    converted_tool_calls = Enum.map(tool_calls, &parse_openai_tool_call/1)

    # Build message attributes
    attrs = %{
      role: :assistant,
      metadata: %{
        model_name: model_name,
        usage: parse_openai_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if content && content != "", do: Map.put(attrs, :content, content), else: attrs
    attrs = if length(converted_tool_calls) > 0, do: Map.put(attrs, :tool_calls, converted_tool_calls), else: attrs

    Message.new!(attrs)
  end

  @doc """
  Parse Anthropic response into a Message.

  ## Examples

      iex> anthropic_response = %{
      ...>   "content" => [%{"type" => "text", "text" => "Hello"}],
      ...>   "model" => "claude-3-sonnet"
      ...> }
      iex> Messages.from_anthropic_response(anthropic_response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_anthropic_response(map()) :: Message.t()
  def from_anthropic_response(response) when is_map(response) do
    content_data = Map.get(response, "content", [])
    model = Map.get(response, "model", "claude")
    usage_data = Map.get(response, "usage", %{})

    {content_parts, tool_calls} = parse_anthropic_content(content_data)

    attrs = %{
      role: :assistant,
      content: consolidate_content_parts(content_parts),
      metadata: %{
        model_name: model,
        usage: parse_anthropic_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

    Message.new!(attrs)
  end

  @doc """
  Parse Gemini response into a Message.

  ## Examples

      iex> gemini_response = %{
      ...>   "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]
      ...> }
      iex> Messages.from_gemini_response(gemini_response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_gemini_response(map()) :: Message.t()
  def from_gemini_response(response) when is_map(response) do
    candidates = Map.get(response, "candidates", [])
    usage_data = Map.get(response, "usageMetadata", %{})

    candidate = List.first(candidates) || %{}
    content_data = Map.get(candidate, "content", %{})
    parts_data = Map.get(content_data, "parts", [])

    {content_parts, tool_calls} = parse_gemini_content(parts_data)

    attrs = %{
      role: :assistant,
      content: consolidate_content_parts(content_parts),
      metadata: %{
        model_name: "gemini-model",
        usage: parse_gemini_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

    Message.new!(attrs)
  end

  @doc """
  Parse provider response into a Message.

  Dispatches to appropriate provider-specific parser.

  ## Examples

      iex> Messages.from_provider_response(openai_response, :openai)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_provider_response(map(), atom()) :: Message.t()
  def from_provider_response(response, provider) when is_map(response) do
    case provider do
      :openai -> from_openai_response(response)
      :groq -> from_openai_response(response)
      :lmstudio -> from_openai_response(response)
      :anthropic -> from_anthropic_response(response)
      :gemini -> from_gemini_response(response)
      :mistral -> from_openai_response(response)
      _ ->
        raise ArgumentError, """
        Unsupported provider: #{inspect(provider)}

        Supported providers: :openai, :groq, :lmstudio, :anthropic, :gemini, :mistral
        """
    end
  end

  @doc """
  Normalize any message format to internal Message representation.

  Attempts to detect format and convert to Message structs.

  ## Examples

      iex> Messages.normalize_format([%{"role" => "user", "content" => "Hi"}])
      [%Message{role: :user, content: "Hi"}]

  """
  @spec normalize_format(any()) :: [Message.t()]
  def normalize_format(messages) when is_list(messages) do
    case detect_format(messages) do
      :message -> messages
      :legacy -> Enum.map(messages, &Message.from_legacy/1)
      :openai -> from_openai_messages(messages)
      :anthropic -> from_anthropic_messages(messages)
      :gemini -> from_gemini_messages(messages)
      :unknown ->
        Logger.warning("Unknown message format, attempting generic conversion")
        attempt_generic_conversion(messages)
    end
  end

  def normalize_format(single_message) do
    normalize_format([single_message])
  end

  # Private helper functions

  # OpenAI conversion helpers
  # Note: Using direct map construction instead of OpenaiEx.ChatMessage to avoid compile-time dependency
  defp message_to_openai(%Message{role: :system, content: content}) when is_binary(content) do
    %{"role" => "system", "content" => content}
  end

  defp message_to_openai(%Message{role: :user, metadata: %{content_parts: content_parts}}) when is_list(content_parts) do
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

  defp message_to_openai(%Message{role: :tool, content: content, tool_call_id: tool_call_id, name: _name}) do
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
        "arguments" => Jason.encode!(Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments, %{}))
      }
    }
  end

  # Anthropic conversion helpers
  defp message_to_anthropic(%Message{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp message_to_anthropic(%Message{role: :user, content: content}) when is_list(content) do
    anthropic_content = Enum.map(content, &content_part_to_anthropic/1)
    %{"role" => "user", "content" => anthropic_content}
  end

  defp message_to_anthropic(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    parts = []

    parts = if content && content != "", do: [%{"type" => "text", "text" => content} | parts], else: parts

    parts = if length(tool_calls) > 0 do
      tool_parts = Enum.map(tool_calls, fn call ->
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

  # Gemini conversion helpers
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

  # Response parsing helpers
  defp parse_openai_tool_call(tool_call) when is_map(tool_call) do
    id = Map.get(tool_call, "id") || Map.get(tool_call, :id)
    func = Map.get(tool_call, "function") || Map.get(tool_call, :function)
    name = Map.get(func, "name") || Map.get(func, :name)
    arguments = Map.get(func, "arguments") || Map.get(func, :arguments)

    parsed_args = case Jason.decode(arguments) do
      {:ok, decoded_args} -> decoded_args
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

  defp parse_anthropic_content(content_data) when is_list(content_data) do
    {content_parts, tool_calls} = Enum.reduce(content_data, {[], []}, fn item, {parts, tools} ->
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

  defp parse_gemini_content(parts_data) when is_list(parts_data) do
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

  defp parse_openai_usage(usage_data) when is_map(usage_data) do
    %Usage{
      requests: 1,
      input_tokens: Map.get(usage_data, "prompt_tokens") || Map.get(usage_data, :prompt_tokens) || 0,
      output_tokens: Map.get(usage_data, "completion_tokens") || Map.get(usage_data, :completion_tokens) || 0,
      total_tokens: Map.get(usage_data, "total_tokens") || Map.get(usage_data, :total_tokens) || 0
    }
  end

  defp parse_openai_usage(nil), do: %Usage{}

  defp parse_anthropic_usage(usage_data) when is_map(usage_data) do
    %Usage{
      input_tokens: Map.get(usage_data, "input_tokens", 0),
      output_tokens: Map.get(usage_data, "output_tokens", 0),
      total_tokens: Map.get(usage_data, "input_tokens", 0) + Map.get(usage_data, "output_tokens", 0)
    }
  end

  defp parse_anthropic_usage(_), do: %Usage{}

  defp parse_gemini_usage(usage_data) when is_map(usage_data) do
    %Usage{
      input_tokens: Map.get(usage_data, "promptTokenCount", 0),
      output_tokens: Map.get(usage_data, "candidatesTokenCount", 0),
      total_tokens: Map.get(usage_data, "totalTokenCount", 0)
    }
  end

  defp parse_gemini_usage(_), do: %Usage{}

  # Content consolidation
  defp consolidate_content_parts([]), do: ""
  defp consolidate_content_parts([%ContentPart{type: :text, content: content}]), do: content
  defp consolidate_content_parts(parts) when is_list(parts), do: parts

  # Format detection
  defp detect_format([]), do: :message

  defp detect_format([first | _rest]) do
    cond do
      is_struct(first, Message) -> :message
      match?({:system_prompt, _}, first) or match?({:user_prompt, _}, first) -> :legacy
      is_struct(first) and Map.has_key?(first, :role) -> :openai
      is_map(first) and Map.has_key?(first, "role") and Map.has_key?(first, "content") -> :anthropic
      is_map(first) and Map.has_key?(first, "role") and Map.has_key?(first, "parts") -> :gemini
      is_map(first) and Map.has_key?(first, :role) -> :openai
      true -> :unknown
    end
  end

  # Legacy format conversion helpers
  defp from_openai_messages(openai_messages) do
    Enum.map(openai_messages, fn msg ->
      role = case Map.get(msg, :role) || Map.get(msg, "role") do
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

  defp from_anthropic_messages(anthropic_messages) do
    Enum.map(anthropic_messages, fn msg ->
      role = case Map.get(msg, "role") do
        "user" -> :user
        "assistant" -> :assistant
        _ -> :user
      end

      content = Map.get(msg, "content")

      {text_content, tool_calls} = case content do
        content when is_binary(content) ->
          {content, []}
        content when is_list(content) ->
          parse_anthropic_content_parts(content)
        _ ->
          {inspect(content), []}
      end

      attrs = %{role: role, content: text_content}
      attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

      Message.new!(attrs)
    end)
  end

  defp parse_anthropic_content_parts(content_parts) when is_list(content_parts) do
    {text_parts, tool_calls} = Enum.reduce(content_parts, {[], []}, fn part, {texts, tools} ->
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

  defp from_gemini_messages(gemini_messages) do
    Enum.map(gemini_messages, fn msg ->
      role = case Map.get(msg, "role") do
        "user" -> :user
        "model" -> :assistant
        _ -> :user
      end

      parts = Map.get(msg, "parts", [])
      {text_content, tool_calls} = parse_gemini_parts(parts)

      attrs = %{role: role, content: text_content}
      attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

      Message.new!(attrs)
    end)
  end

  defp parse_gemini_parts(parts) when is_list(parts) do
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

  defp attempt_generic_conversion(messages) do
    Enum.map(messages, fn
      msg when is_binary(msg) -> Message.user(msg)
      msg when is_map(msg) -> Message.user(inspect(msg))
      msg -> Message.user(inspect(msg))
    end)
  end
end
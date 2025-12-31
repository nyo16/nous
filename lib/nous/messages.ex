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

  alias Nous.Message
  alias Nous.Messages.{OpenAI, Anthropic, Gemini}

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
        %{"role" => "system", "content" => "Be helpful"},
        %{"role" => "user", "content" => "Hello"}
      ]

  """
  @spec to_openai_format([Message.t()]) :: [map()]
  defdelegate to_openai_format(messages), to: OpenAI, as: :to_format

  @doc """
  Convert messages to Anthropic format.

  Returns `{system_prompt, messages}` where system prompt is extracted
  and combined, and messages are converted to Anthropic format.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_anthropic_format(conversation)
      {"Be helpful", [%{"role" => "user", "content" => "Hello"}]}

  """
  @spec to_anthropic_format([Message.t()]) :: {String.t() | nil, [map()]}
  defdelegate to_anthropic_format(messages), to: Anthropic, as: :to_format

  @doc """
  Convert messages to Gemini format.

  Returns `{system_prompt, contents}` where system prompt is extracted
  and messages are converted to Gemini contents format.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_gemini_format(conversation)
      {"Be helpful", [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]}

  """
  @spec to_gemini_format([Message.t()]) :: {String.t() | nil, [map()]}
  defdelegate to_gemini_format(messages), to: Gemini, as: :to_format

  @doc """
  Convert messages to provider-specific format.

  Dispatches to the appropriate provider-specific conversion function.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_provider_format(conversation, :openai)
      [%{"role" => "system", "content" => "Be helpful"}, %{"role" => "user", "content" => "Hello"}]

      iex> Messages.to_provider_format(conversation, :anthropic)
      {"Be helpful", [%{"role" => "user", "content" => "Hello"}]}

  """
  @spec to_provider_format([Message.t()], atom()) :: any()
  def to_provider_format(messages, provider) when is_list(messages) do
    case provider do
      :openai -> to_openai_format(messages)
      :openai_compatible -> to_openai_format(messages)
      :groq -> to_openai_format(messages)
      :lmstudio -> to_openai_format(messages)
      :ollama -> to_openai_format(messages)
      :openrouter -> to_openai_format(messages)
      :together -> to_openai_format(messages)
      :vllm -> to_openai_format(messages)
      :sglang -> to_openai_format(messages)
      :anthropic -> to_anthropic_format(messages)
      :gemini -> to_gemini_format(messages)
      :mistral -> to_openai_format(messages)
      :custom -> to_openai_format(messages)
      _ ->
        raise ArgumentError, """
        Unsupported provider: #{inspect(provider)}

        Supported providers: :openai, :openai_compatible, :groq, :lmstudio, :vllm, :sglang, :anthropic, :gemini, :mistral
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
  defdelegate from_openai_response(response), to: OpenAI, as: :from_response

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
  defdelegate from_anthropic_response(response), to: Anthropic, as: :from_response

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
  defdelegate from_gemini_response(response), to: Gemini, as: :from_response

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
      :openai_compatible -> from_openai_response(response)
      :groq -> from_openai_response(response)
      :lmstudio -> from_openai_response(response)
      :ollama -> from_openai_response(response)
      :openrouter -> from_openai_response(response)
      :together -> from_openai_response(response)
      :vllm -> from_openai_response(response)
      :sglang -> from_openai_response(response)
      :anthropic -> from_anthropic_response(response)
      :gemini -> from_gemini_response(response)
      :mistral -> from_openai_response(response)
      :custom -> from_openai_response(response)
      _ ->
        raise ArgumentError, """
        Unsupported provider: #{inspect(provider)}

        Supported providers: :openai, :openai_compatible, :groq, :lmstudio, :vllm, :sglang, :anthropic, :gemini, :mistral
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
      :openai -> OpenAI.from_messages(messages)
      :anthropic -> Anthropic.from_messages(messages)
      :gemini -> Gemini.from_messages(messages)
      :unknown ->
        Logger.warning("Unknown message format, attempting generic conversion")
        attempt_generic_conversion(messages)
    end
  end

  def normalize_format(single_message) do
    normalize_format([single_message])
  end

  # Private helpers

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

  defp attempt_generic_conversion(messages) do
    Enum.map(messages, fn
      msg when is_binary(msg) -> Message.user(msg)
      msg when is_map(msg) -> Message.user(inspect(msg))
      msg -> Message.user(inspect(msg))
    end)
  end
end

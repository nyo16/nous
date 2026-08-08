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

  # Every provider below speaks the OpenAI `/chat/completions` dialect in both
  # directions; :anthropic and the Gemini pair are the only real branches. Held
  # as attributes so the encode and decode dispatches cannot drift apart.
  @openai_dialect [
    :openai,
    :openai_compatible,
    :groq,
    :lmstudio,
    :ollama,
    :openrouter,
    :together,
    :vllm,
    :sglang,
    :mistral,
    :llamacpp,
    :custom
  ]
  @gemini_dialect [:gemini, :vertex_ai]

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
      iex> [system] = Messages.find_by_role(conversation, :system)
      iex> {system.role, system.content}
      {:system, "Be helpful"}

  """
  @spec find_by_role([Message.t()], atom()) :: [Message.t()]
  def find_by_role(messages, role) when is_list(messages) do
    Enum.filter(messages, &(&1.role == role))
  end

  @doc """
  Get the last message from a conversation.

  ## Examples

      iex> conversation = [Message.user("Hi"), Message.assistant("Hello")]
      iex> last = Messages.last_message(conversation)
      iex> {last.role, last.content}
      {:assistant, "Hello"}

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

  The agent loop calls this once per iteration over a history that only grows at
  the tail, so the per-message payloads are memoized per calling process and
  only the new tail is converted. See `Nous.Messages.Cache`.

  The memo lives in the calling process's dictionary, so it keeps the most
  recently converted history alive until that process converts another one or
  exits. `Nous.AgentRunner` and `Nous.LLM` release it when a run ends. A host
  that calls these converters itself — `AGENTS.md` documents that host as a
  LiveView — retains it for the life of that process; convert per render at your
  own cost, or let the runner own the conversion.

  ## Examples

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_provider_format(conversation, :openai)
      [%{"role" => "system", "content" => "Be helpful"}, %{"role" => "user", "content" => "Hello"}]

      iex> conversation = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.to_provider_format(conversation, :anthropic)
      {"Be helpful", [%{"role" => "user", "content" => "Hello"}]}

  """
  @spec to_provider_format([Message.t()], atom()) :: any()
  def to_provider_format(messages, provider) when is_list(messages) do
    cond do
      provider in @openai_dialect -> to_openai_format(messages)
      provider in @gemini_dialect -> to_gemini_format(messages)
      provider == :anthropic -> to_anthropic_format(messages)
      true -> raise ArgumentError, unsupported_provider_message(provider)
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
      iex> message = Messages.from_openai_response(openai_response)
      iex> {message.role, message.content}
      {:assistant, "Hello"}

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
      iex> message = Messages.from_anthropic_response(anthropic_response)
      iex> {message.role, message.content}
      {:assistant, "Hello"}

  """
  @spec from_anthropic_response(map()) :: Message.t()
  defdelegate from_anthropic_response(response), to: Anthropic, as: :from_response

  @doc """
  Parse Gemini response into a Message.

  ## Examples

      iex> gemini_response = %{
      ...>   "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]
      ...> }
      iex> message = Messages.from_gemini_response(gemini_response)
      iex> {message.role, message.content}
      {:assistant, "Hello"}

  """
  @spec from_gemini_response(map()) :: Message.t()
  defdelegate from_gemini_response(response), to: Gemini, as: :from_response

  @doc """
  Parse provider response into a Message.

  Dispatches to appropriate provider-specific parser.

  ## Examples

      iex> openai_response = %{
      ...>   "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}],
      ...>   "usage" => %{"total_tokens" => 10}
      ...> }
      iex> message = Messages.from_provider_response(openai_response, :openai)
      iex> {message.role, message.content}
      {:assistant, "Hello"}

  """
  @spec from_provider_response(map(), atom()) :: Message.t()
  def from_provider_response(response, provider) when is_map(response) do
    cond do
      provider in @openai_dialect -> from_openai_response(response)
      provider in @gemini_dialect -> from_gemini_response(response)
      provider == :anthropic -> from_anthropic_response(response)
      true -> raise ArgumentError, unsupported_provider_message(provider)
    end
  end

  @doc """
  Normalize any message format to internal Message representation.

  Attempts to detect format and convert to Message structs.

  ## Examples

      iex> [message] = Messages.normalize_format([%{"role" => "user", "content" => "Hi"}])
      iex> {message.role, message.content}
      {:user, "Hi"}

  """
  @spec normalize_format(any()) :: [Message.t()]
  def normalize_format(messages) when is_list(messages) do
    case detect_format(messages) do
      :message ->
        messages

      :legacy ->
        Enum.map(messages, &Message.from_legacy/1)

      :openai ->
        OpenAI.from_messages(messages)

      :anthropic ->
        Anthropic.from_messages(messages)

      :gemini ->
        Gemini.from_messages(messages)

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

  defp detect_format([first | _rest]), do: format_of(first)

  defp format_of(%Message{}), do: :message
  defp format_of({:system_prompt, _}), do: :legacy
  defp format_of({:user_prompt, _}), do: :legacy
  defp format_of(%{__struct__: _} = struct) when is_map_key(struct, :role), do: :openai
  defp format_of(%{"role" => _, "content" => _}), do: :anthropic
  defp format_of(%{"role" => _, "parts" => _}), do: :gemini
  defp format_of(%{role: _}), do: :openai
  defp format_of(_other), do: :unknown

  defp unsupported_provider_message(provider) do
    """
    Unsupported provider: #{inspect(provider)}

    Supported providers: :openai, :openai_compatible, :groq, :lmstudio, :llamacpp, :vllm, :sglang, :anthropic, :gemini, :vertex_ai, :mistral
    """
  end

  defp attempt_generic_conversion(messages) do
    Enum.map(messages, fn
      msg when is_binary(msg) -> Message.user(msg)
      msg when is_map(msg) -> Message.user(inspect(msg))
      msg -> Message.user(inspect(msg))
    end)
  end
end

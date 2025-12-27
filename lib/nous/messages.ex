defmodule Nous.Messages do
  require Logger

  @moduledoc """
  Message construction and conversion for OpenAI.Ex.

  This module provides functions to:
  - Create message parts (system prompts, user prompts, tool returns)
  - Extract data from responses (text, tool calls)
  - Convert between our format and OpenAI.Ex format

  ## Message Format

  We use tagged tuples internally:
  - `{:system_prompt, "text"}` - System instructions
  - `{:user_prompt, "text"}` - User input
  - `{:tool_return, %{call_id: "...", result: ...}}` - Tool results
  - `{:text, "text"}` - Model's text response
  - `{:tool_call, %{id: "...", name: "...", arguments: %{}}}` - Model's tool call

  ## Example

      # Build request messages
      messages = [
        Messages.system_prompt("Be helpful"),
        Messages.user_prompt("What is 2+2?")
      ]

      # Convert to OpenAI format
      openai_messages = Messages.to_openai_messages(messages)

      # Parse response
      response = Messages.from_openai_response(openai_response)
      text = Messages.extract_text(response.parts)

  """

  alias Nous.Types

  @doc """
  Create a system prompt message part.

  ## Example

      Messages.system_prompt("Be helpful and concise")
      # {:system_prompt, "Be helpful and concise"}

  """
  @spec system_prompt(String.t()) :: Types.system_prompt_part()
  def system_prompt(text) when is_binary(text) do
    {:system_prompt, text}
  end

  @doc """
  Create a user prompt message part.

  Accepts either a string or a list of content items for multi-modal.

  ## Examples

      # Simple text
      Messages.user_prompt("Hello!")
      # {:user_prompt, "Hello!"}

      # Multi-modal with image
      Messages.user_prompt([
        {:text, "What's in this image?"},
        {:image_url, "https://example.com/image.png"}
      ])

  """
  @spec user_prompt(String.t() | [Types.content()]) :: Types.user_prompt_part()
  def user_prompt(content) do
    {:user_prompt, content}
  end

  @doc """
  Create a tool return message part.

  ## Example

      Messages.tool_return("call_abc123", %{result: "success"})
      # {:tool_return, %{call_id: "call_abc123", result: %{result: "success"}}}

  """
  @spec tool_return(String.t(), any()) :: Types.tool_return_part()
  def tool_return(call_id, result) do
    {:tool_return, %{call_id: call_id, result: result}}
  end

  @doc """
  Extract text from response parts.

  Concatenates all text parts into a single string.

  ## Example

      parts = [{:text, "Hello "}, {:text, "world!"}]
      Messages.extract_text(parts)
      # "Hello world!"

  """
  @spec extract_text([Types.response_part()]) :: String.t()
  def extract_text(parts) do
    parts
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map(fn {:text, text} -> text end)
    |> Enum.join("")
  end

  @doc """
  Extract tool calls from response parts.

  ## Example

      parts = [
        {:text, "I'll help with that"},
        {:tool_call, %{id: "call_1", name: "search", arguments: %{"q" => "elixir"}}}
      ]
      Messages.extract_tool_calls(parts)
      # [%{id: "call_1", name: "search", arguments: %{"q" => "elixir"}}]

  """
  @spec extract_tool_calls([Types.response_part()]) :: [Types.tool_call()]
  def extract_tool_calls(parts) do
    parts
    |> Enum.filter(&match?({:tool_call, _}, &1))
    |> Enum.map(fn {:tool_call, call} -> call end)
  end

  @doc """
  Convert our message format to OpenAI.Ex ChatMessage format.

  Handles:
  - System prompts
  - User prompts (text and multi-modal)
  - Tool returns
  - Previous assistant responses with tool calls

  ## Example

      messages = [
        {:system_prompt, "Be helpful"},
        {:user_prompt, "Hello!"}
      ]

      openai_messages = Messages.to_openai_messages(messages)
      # [
      #   %OpenaiEx.ChatMessage{role: "system", content: "Be helpful"},
      #   %OpenaiEx.ChatMessage{role: "user", content: "Hello!"}
      # ]

  """
  @spec to_openai_messages([Types.request_part() | Types.model_response()]) :: [struct()]
  def to_openai_messages(messages) do
    Enum.map(messages, &to_openai_message/1)
  end

  # Convert single message to OpenAI format
  defp to_openai_message({:system_prompt, text}) do
    OpenaiEx.ChatMessage.system(text)
  end

  defp to_openai_message({:user_prompt, text}) when is_binary(text) do
    OpenaiEx.ChatMessage.user(text)
  end

  defp to_openai_message({:user_prompt, nil}) do
    OpenaiEx.ChatMessage.user("")
  end

  defp to_openai_message({:user_prompt, content}) when is_list(content) do
    converted_content = convert_content_list(content)
    OpenaiEx.ChatMessage.user(converted_content)
  end

  defp to_openai_message({:tool_return, %{call_id: id, result: result}}) do
    # Encode result as JSON string for OpenAI
    content = Jason.encode!(result)
    # tool(tool_call_id, name, content) - we don't have name, so use empty string
    OpenaiEx.ChatMessage.tool(id, "", content)
  end

  # Previous assistant response with tool calls
  defp to_openai_message(%{parts: parts}) do
    text = extract_text(parts)
    tool_calls = extract_tool_calls(parts)

    content = if text == "", do: nil, else: text

    if Enum.empty?(tool_calls) do
      OpenaiEx.ChatMessage.assistant(content)
    else
      # For messages with tool calls, just include them in the message map
      # OpenAI API expects them, so we include them manually
      openai_tool_calls = Enum.map(tool_calls, &to_openai_tool_call/1)

      # Return a plain map that OpenaiEx will accept
      %{
        "role" => "assistant",
        "content" => content,
        "tool_calls" => openai_tool_calls
      }
    end
  end

  # Convert content list to OpenAI format
  defp convert_content_list(content) do
    Enum.map(content, fn
      {:text, text} -> %{type: "text", text: text}
      {:image_url, url} -> %{type: "image_url", image_url: %{url: url}}
      {:audio_url, url} -> %{type: "input_audio", input_audio: %{data: url}}
      text when is_binary(text) -> %{type: "text", text: text}
    end)
  end

  # Convert our tool call to OpenAI format
  defp to_openai_tool_call(%{id: id, name: name, arguments: args}) do
    %{
      id: id,
      type: "function",
      function: %{
        name: name,
        arguments: Jason.encode!(args)
      }
    }
  end

  @doc """
  Parse OpenAI.Ex response into our format.

  Converts the OpenAI response structure into our internal format
  with parts, usage, model name, and timestamp.

  ## Example

      # After calling OpenaiEx.Chat.Completions.create
      {:ok, openai_response} = OpenaiEx.Chat.Completions.create(client, params)

      response = Messages.from_openai_response(openai_response)
      # %{
      #   parts: [{:text, "Hello! How can I help you?"}],
      #   usage: %Usage{...},
      #   model_name: "gpt-4",
      #   timestamp: ~U[2024-10-07 17:00:00Z]
      # }

  """
  @spec from_openai_response(map()) :: Types.model_response()
  def from_openai_response(response) when is_map(response) do
    # Handle both atom keys (from OpenaiEx structs) and string keys (from raw JSON)
    choices = Map.get(response, :choices) || Map.get(response, "choices") || []
    choice = List.first(choices)

    message = if choice do
      Map.get(choice, :message) || Map.get(choice, "message")
    else
      nil
    end

    content = if message do
      Map.get(message, :content) || Map.get(message, "content")
    else
      nil
    end

    tool_calls = if message do
      Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    else
      nil
    end

    usage_data = Map.get(response, :usage) || Map.get(response, "usage")
    model_name = Map.get(response, :model) || Map.get(response, "model")

    parts = []

    # Add text content if present
    parts =
      if content && content != "" do
        [{:text, content} | parts]
      else
        parts
      end

    # Add tool calls if present
    parts =
      if tool_calls && tool_calls != [] do
        tool_parts = Enum.map(tool_calls, &parse_tool_call/1)
        tool_parts ++ parts
      else
        parts
      end

    # Convert usage - handle both atom and string keys, and nil usage_data
    usage = if usage_data do
      %Nous.Usage{
        requests: 1,
        input_tokens: Map.get(usage_data, :prompt_tokens) || Map.get(usage_data, "prompt_tokens") || 0,
        output_tokens: Map.get(usage_data, :completion_tokens) || Map.get(usage_data, "completion_tokens") || 0,
        total_tokens: Map.get(usage_data, :total_tokens) || Map.get(usage_data, "total_tokens") || 0
      }
    else
      %Nous.Usage{requests: 1, input_tokens: 0, output_tokens: 0, total_tokens: 0}
    end

    %{
      parts: Enum.reverse(parts),
      usage: usage,
      model_name: model_name,
      timestamp: DateTime.utc_now()
    }
  end

  # Parse OpenAI tool call to our format (handle both atom and string keys)
  defp parse_tool_call(tool_call) when is_map(tool_call) do
    id = Map.get(tool_call, :id) || Map.get(tool_call, "id")
    func = Map.get(tool_call, :function) || Map.get(tool_call, "function")
    name = Map.get(func, :name) || Map.get(func, "name")
    arguments = Map.get(func, :arguments) || Map.get(func, "arguments")

    case Jason.decode(arguments) do
      {:ok, decoded_args} ->
        {:tool_call,
         %{
           id: id,
           name: name,
           arguments: decoded_args
         }}

      {:error, _decode_error} ->
        Logger.warning("Failed to decode tool arguments: #{inspect(arguments)}")
        {:tool_call,
         %{
           id: id,
           name: name,
           arguments: %{"error" => "Invalid JSON arguments", "raw" => arguments}
         }}
    end
  end

  # Generic provider-agnostic helper functions

  @doc """
  Convert messages to provider-specific format.

  Dispatches to the appropriate provider-specific conversion function
  based on the provider atom.

  ## Examples

      messages = [
        {:system_prompt, "You are helpful"},
        {:user_prompt, "Hello!"}
      ]

      # Convert to OpenAI format
      openai_msgs = Messages.to_provider_format(messages, :openai)

      # Convert to Anthropic format
      {system, anthropic_msgs} = Messages.to_provider_format(messages, :anthropic)

      # Convert to Gemini format
      {system, gemini_msgs} = Messages.to_provider_format(messages, :gemini)

  """
  @spec to_provider_format([Types.request_part() | Types.model_response()], atom()) :: any()
  def to_provider_format(messages, provider) when is_list(messages) do
    case provider do
      :openai ->
        to_openai_messages(messages)

      :groq ->
        # Groq uses OpenAI-compatible format
        to_openai_messages(messages)

      :lmstudio ->
        # LMStudio uses OpenAI-compatible format
        to_openai_messages(messages)

      :anthropic ->
        to_anthropic_format(messages)

      :gemini ->
        to_gemini_format(messages)

      :mistral ->
        # Mistral uses OpenAI-compatible format
        to_openai_messages(messages)

      _ ->
        raise ArgumentError, """
        Unsupported provider: #{inspect(provider)}

        Supported providers: :openai, :groq, :lmstudio, :anthropic, :gemini, :mistral
        """
    end
  end

  @doc """
  Parse provider-specific response into internal format.

  Dispatches to the appropriate provider-specific response parser
  based on the provider atom.

  ## Examples

      # Parse OpenAI response
      openai_response = %{"choices" => [...], "usage" => {...}}
      internal = Messages.from_provider_response(openai_response, :openai)

      # Parse Anthropic response
      anthropic_response = %{"content" => [...], "usage" => {...}}
      internal = Messages.from_provider_response(anthropic_response, :anthropic)

  """
  @spec from_provider_response(map(), atom()) :: Types.model_response()
  def from_provider_response(response, provider) when is_map(response) do
    case provider do
      :openai ->
        from_openai_response(response)

      :groq ->
        # Groq uses OpenAI-compatible format
        from_openai_response(response)

      :lmstudio ->
        # LMStudio uses OpenAI-compatible format
        from_openai_response(response)

      :anthropic ->
        from_anthropic_response(response)

      :gemini ->
        from_gemini_response(response)

      :mistral ->
        # Mistral uses OpenAI-compatible format
        from_openai_response(response)

      _ ->
        raise ArgumentError, """
        Unsupported provider: #{inspect(provider)}

        Supported providers: :openai, :groq, :lmstudio, :anthropic, :gemini, :mistral
        """
    end
  end

  @doc """
  Normalize any message format to internal representation.

  Attempts to detect the format and convert it to our internal
  message representation. Useful when working with mixed formats
  or when the source format is unknown.

  ## Examples

      # Normalize OpenAI message
      openai_msg = %OpenaiEx.ChatMessage{role: "user", content: "Hello"}
      normalized = Messages.normalize_format([openai_msg])
      # => [{:user_prompt, "Hello"}]

      # Already internal format
      internal_msgs = [{:system_prompt, "You are helpful"}]
      normalized = Messages.normalize_format(internal_msgs)
      # => [{:system_prompt, "You are helpful"}]

  """
  @spec normalize_format(any()) :: [Types.request_part() | Types.model_response()]
  def normalize_format(messages) when is_list(messages) do
    case detect_format(messages) do
      :internal ->
        messages

      :openai ->
        from_openai_messages(messages)

      :anthropic ->
        from_anthropic_messages(messages)

      :gemini ->
        from_gemini_messages(messages)

      :unknown ->
        Logger.warning("Unknown message format, attempting generic conversion")
        attempt_generic_conversion(messages)
    end
  end

  def normalize_format(single_message) do
    normalize_format([single_message])
  end

  # Provider-specific conversion helpers

  @spec to_anthropic_format([Types.request_part() | Types.model_response()]) :: {String.t() | nil, [map()]}
  defp to_anthropic_format(messages) do
    # Extract system prompts and convert the rest
    {system_prompts, other_messages} =
      Enum.split_with(messages, &match?({:system_prompt, _}, &1))

    # Combine system prompts
    system =
      if not Enum.empty?(system_prompts) do
        system_prompts
        |> Enum.map(fn {:system_prompt, text} -> text end)
        |> Enum.join("\n\n")
      else
        nil
      end

    # Convert other messages
    anthropic_messages =
      other_messages
      |> Enum.map(&to_anthropic_message/1)
      |> Enum.reject(&is_nil/1)

    {system, anthropic_messages}
  end

  @spec to_gemini_format([Types.request_part() | Types.model_response()]) :: {String.t() | nil, [map()]}
  defp to_gemini_format(messages) do
    {system_prompts, other_messages} =
      Enum.split_with(messages, &match?({:system_prompt, _}, &1))

    system =
      if not Enum.empty?(system_prompts) do
        system_prompts
        |> Enum.map(fn {:system_prompt, text} -> text end)
        |> Enum.join("\n\n")
      else
        nil
      end

    gemini_contents = Enum.map(other_messages, &to_gemini_message/1) |> Enum.reject(&is_nil/1)

    {system, gemini_contents}
  end

  # Anthropic message converters
  defp to_anthropic_message({:user_prompt, text}) when is_binary(text) do
    %{role: "user", content: text}
  end

  defp to_anthropic_message({:user_prompt, content}) when is_list(content) do
    %{role: "user", content: convert_content_list_anthropic(content)}
  end

  defp to_anthropic_message({:tool_return, %{call_id: id, result: result}}) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: id,
          content: Jason.encode!(result)
        }
      ]
    }
  end

  defp to_anthropic_message(%{parts: parts}) do
    text = extract_text(parts)
    tool_calls = extract_tool_calls(parts)

    content = []

    content =
      if text != "", do: [%{type: "text", text: text} | content], else: content

    content =
      if not Enum.empty?(tool_calls) do
        Enum.map(tool_calls, fn call ->
          %{
            type: "tool_use",
            id: call.id,
            name: call.name,
            input: call.arguments
          }
        end) ++ content
      else
        content
      end

    if not Enum.empty?(content) do
      %{role: "assistant", content: Enum.reverse(content)}
    else
      nil
    end
  end

  defp to_anthropic_message(_), do: nil

  # Gemini message converters
  defp to_gemini_message({:user_prompt, text}) when is_binary(text) do
    %{
      role: "user",
      parts: [%{text: text}]
    }
  end

  defp to_gemini_message({:user_prompt, content}) when is_list(content) do
    parts = Enum.map(content, fn
      {:text, text} -> %{text: text}
      {:image_url, url} -> %{text: "[Image: #{url}]"}  # Convert image to text placeholder for Gemini
      text when is_binary(text) -> %{text: text}
      _ -> nil
    end) |> Enum.reject(&is_nil/1)

    %{role: "user", parts: parts}
  end

  defp to_gemini_message(%{parts: parts}) do
    text = extract_text(parts)
    tool_calls = extract_tool_calls(parts)

    gemini_parts = []

    gemini_parts = if text != "", do: [%{text: text} | gemini_parts], else: gemini_parts

    gemini_parts =
      if not Enum.empty?(tool_calls) do
        Enum.map(tool_calls, fn call ->
          %{
            functionCall: %{
              name: call.name,
              args: call.arguments
            }
          }
        end) ++ gemini_parts
      else
        gemini_parts
      end

    if not Enum.empty?(gemini_parts) do
      %{role: "model", parts: Enum.reverse(gemini_parts)}
    else
      nil
    end
  end

  defp to_gemini_message(_), do: nil

  # Response parsers for other providers
  defp from_anthropic_response(response) do
    content = Map.get(response, "content", [])
    model = Map.get(response, "model", "unknown")
    usage_data = Map.get(response, "usage", %{})

    parts = parse_anthropic_content(content)
    usage = parse_anthropic_usage(usage_data)

    %{
      parts: parts,
      usage: usage,
      model_name: model,
      timestamp: DateTime.utc_now()
    }
  end

  defp from_gemini_response(response) do
    candidates = Map.get(response, "candidates", [])
    usage_data = Map.get(response, "usageMetadata", %{})

    # Get first candidate
    candidate = List.first(candidates) || %{}
    content = Map.get(candidate, "content", %{})
    parts_data = Map.get(content, "parts", [])

    parts = parse_gemini_parts(parts_data)
    usage = parse_gemini_usage(usage_data)

    %{
      parts: parts,
      usage: usage,
      model_name: "gemini-model",
      timestamp: DateTime.utc_now()
    }
  end

  # Format detection helpers
  defp detect_format([]), do: :internal

  defp detect_format([first | _rest]) do
    cond do
      # Internal format
      match?({:system_prompt, _}, first) or
      match?({:user_prompt, _}, first) or
      match?({:tool_return, _}, first) or
      match?(%{parts: _}, first) ->
        :internal

      # OpenAI format (struct with role field)
      is_struct(first) and Map.has_key?(first, :role) ->
        :openai

      # Anthropic format (maps with role and content)
      is_map(first) and Map.has_key?(first, "role") and Map.has_key?(first, "content") ->
        :anthropic

      # Gemini format (maps with role and parts)
      is_map(first) and Map.has_key?(first, "role") and Map.has_key?(first, "parts") ->
        :gemini

      # Generic map format
      is_map(first) and Map.has_key?(first, :role) ->
        :openai

      true ->
        :unknown
    end
  end

  # Format conversion helpers for normalize_format
  defp from_openai_messages(openai_messages) do
    Enum.map(openai_messages, &from_openai_message/1)
  end

  defp from_openai_message(msg) when is_struct(msg) do
    case Map.get(msg, :role) do
      "system" -> {:system_prompt, Map.get(msg, :content)}
      "user" -> {:user_prompt, Map.get(msg, :content)}
      "assistant" ->
        %{
          parts: [{:text, Map.get(msg, :content) || ""}],
          usage: %Nous.Usage{},
          model_name: "unknown",
          timestamp: DateTime.utc_now()
        }
      _ -> {:user_prompt, Map.get(msg, :content) || inspect(msg)}
    end
  end

  defp from_openai_message(msg) when is_map(msg) do
    # Handle generic map format
    role = Map.get(msg, :role) || Map.get(msg, "role")
    content = Map.get(msg, :content) || Map.get(msg, "content")

    case role do
      "system" -> {:system_prompt, content}
      "user" -> {:user_prompt, content}
      _ -> {:user_prompt, inspect(msg)}
    end
  end

  defp from_anthropic_messages(anthropic_messages) do
    # Convert Anthropic format to internal
    Enum.map(anthropic_messages, &from_anthropic_message/1)
  end

  defp from_anthropic_message(%{"role" => "user", "content" => content}) do
    {:user_prompt, content}
  end

  defp from_anthropic_message(%{"role" => "assistant", "content" => content}) when is_list(content) do
    parts = parse_anthropic_content(content)
    %{
      parts: parts,
      usage: %Nous.Usage{},
      model_name: "claude",
      timestamp: DateTime.utc_now()
    }
  end

  defp from_anthropic_message(msg) do
    {:user_prompt, inspect(msg)}
  end

  defp from_gemini_messages(gemini_messages) do
    # Convert Gemini format to internal
    Enum.map(gemini_messages, &from_gemini_message/1)
  end

  defp from_gemini_message(%{"role" => "user", "parts" => parts}) do
    text = parts
    |> Enum.map(fn part -> Map.get(part, "text", "") end)
    |> Enum.join(" ")

    {:user_prompt, text}
  end

  defp from_gemini_message(%{"role" => "model", "parts" => parts}) do
    parsed_parts = parse_gemini_parts(parts)
    %{
      parts: parsed_parts,
      usage: %Nous.Usage{},
      model_name: "gemini",
      timestamp: DateTime.utc_now()
    }
  end

  defp from_gemini_message(msg) do
    {:user_prompt, inspect(msg)}
  end

  defp attempt_generic_conversion(messages) do
    Enum.map(messages, fn
      msg when is_binary(msg) -> {:user_prompt, msg}
      msg when is_map(msg) -> {:user_prompt, inspect(msg)}
      msg -> {:user_prompt, inspect(msg)}
    end)
  end

  # Helper parsers
  defp parse_anthropic_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} -> {:text, text}
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        {:tool_call, %{id: id, name: name, arguments: input}}
      _ -> {:text, ""}
    end)
  end

  defp parse_anthropic_content(content) when is_binary(content) do
    [{:text, content}]
  end

  defp parse_anthropic_usage(usage) do
    %Nous.Usage{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      total_tokens: Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
    }
  end

  defp parse_gemini_parts(parts) when is_list(parts) do
    Enum.map(parts, fn
      %{"text" => text} -> {:text, text}
      %{"functionCall" => %{"name" => name, "args" => args}} ->
        {:tool_call, %{id: "gemini_#{:rand.uniform(10000)}", name: name, arguments: args}}
      _ -> {:text, ""}
    end)
  end

  defp parse_gemini_usage(usage) do
    %Nous.Usage{
      input_tokens: Map.get(usage, "promptTokenCount", 0),
      output_tokens: Map.get(usage, "candidatesTokenCount", 0),
      total_tokens: Map.get(usage, "totalTokenCount", 0)
    }
  end

  defp convert_content_list_anthropic(content) when is_list(content) do
    Enum.map(content, fn
      {:text, text} -> %{type: "text", text: text}
      {:image_url, url} -> %{type: "image", source: %{type: "base64", media_type: "image/jpeg", data: url}}
      text when is_binary(text) -> %{type: "text", text: text}
      _ -> %{type: "text", text: ""}
    end)
  end
end

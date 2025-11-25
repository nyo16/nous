defmodule Yggdrasil.Messages do
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

  alias Yggdrasil.Types

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
    choices = Map.get(response, :choices) || Map.get(response, "choices")
    choice = List.first(choices)

    message = Map.get(choice, :message) || Map.get(choice, "message")
    content = Map.get(message, :content) || Map.get(message, "content")
    tool_calls = Map.get(message, :tool_calls) || Map.get(message, "tool_calls")

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

    # Convert usage - handle both atom and string keys
    usage = %Yggdrasil.Usage{
      requests: 1,
      input_tokens: Map.get(usage_data, :prompt_tokens) || Map.get(usage_data, "prompt_tokens") || 0,
      output_tokens: Map.get(usage_data, :completion_tokens) || Map.get(usage_data, "completion_tokens") || 0,
      total_tokens: Map.get(usage_data, :total_tokens) || Map.get(usage_data, "total_tokens") || 0
    }

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

    {:tool_call,
     %{
       id: id,
       name: name,
       arguments: Jason.decode!(arguments)
     }}
  end
end

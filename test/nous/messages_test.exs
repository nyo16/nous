defmodule Nous.MessagesTest do
  use ExUnit.Case, async: true

  alias Nous.{Message, Messages}

  # doctest Messages  # TODO: Re-enable after fixing circular dependency

  describe "Message.system/1" do
    test "creates system message" do
      result = Message.system("Be helpful")

      assert %Message{} = result
      assert result.role == :system
      assert result.content == "Be helpful"
    end
  end

  describe "Message.user/1" do
    test "creates user message with text" do
      result = Message.user("Hello!")

      assert %Message{} = result
      assert result.role == :user
      assert result.content == "Hello!"
    end

    test "creates user message with content parts" do
      alias Nous.Message.ContentPart

      content_parts = [
        ContentPart.text("What's in this image?"),
        ContentPart.image_url("https://example.com/image.png")
      ]

      result = Message.user(content_parts)

      assert %Message{} = result
      assert result.role == :user
      assert result.content == "What's in this image?[Image: https://example.com/image.png]"
      assert result.metadata.content_parts == content_parts
    end
  end

  describe "Message.tool/3" do
    test "creates tool message" do
      result = Message.tool("call_123", %{status: "success"})

      assert %Message{} = result
      assert result.role == :tool
      assert result.tool_call_id == "call_123"
      assert result.content == ~s({"status":"success"})
    end
  end

  describe "extract_text/1" do
    test "extracts text from message with text content" do
      message = Message.user("Hello world!")

      result = Messages.extract_text(message)

      assert result == "Hello world!"
    end

    test "extracts text from list of messages" do
      messages = [
        Message.user("Hello "),
        Message.assistant("world!")
      ]

      result = Messages.extract_text(messages)

      assert result == ["Hello ", "world!"]
    end

    test "extracts text from message with content parts" do
      alias Nous.Message.ContentPart

      content_parts = [
        ContentPart.text("Hello"),
        ContentPart.image_url("https://example.com/image.png"),
        ContentPart.text(" world")
      ]

      message = Message.user(content_parts)
      result = Messages.extract_text(message)

      # Should return the text content that was generated from content parts
      assert result == "Hello[Image: https://example.com/image.png] world"
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts tool calls from assistant messages" do
      tool_calls = [
        %{"id" => "call_1", "name" => "search", "arguments" => %{"q" => "elixir"}},
        %{"id" => "call_2", "name" => "calculate", "arguments" => %{"x" => 5}}
      ]

      messages = [
        Message.user("Let me search for that"),
        Message.assistant("I'll search for that", tool_calls: tool_calls),
        Message.user("Thanks!")
      ]

      result = Messages.extract_tool_calls(messages)

      assert length(result) == 2
      assert Enum.at(result, 0)["id"] == "call_1"
      assert Enum.at(result, 1)["id"] == "call_2"
    end

    test "returns empty list when no tool calls" do
      messages = [
        Message.user("Hello"),
        Message.assistant("Just text response")
      ]

      result = Messages.extract_tool_calls(messages)

      assert result == []
    end
  end

  describe "to_openai_format/1" do
    test "converts system message" do
      messages = [Message.system("Be helpful")]

      [result] = Messages.to_openai_format(messages)

      assert result.role == "system"
      assert result.content == "Be helpful"
    end

    test "converts user message with text" do
      messages = [Message.user("Hello!")]

      [result] = Messages.to_openai_format(messages)

      assert result.role == "user"
      assert result.content == "Hello!"
    end

    test "converts user message with multi-modal content" do
      alias Nous.Message.ContentPart

      content_parts = [
        ContentPart.text("What's in this image?"),
        ContentPart.image_url("https://example.com/image.png")
      ]

      messages = [Message.user(content_parts)]

      [result] = Messages.to_openai_format(messages)

      assert result.role == "user"
      assert is_list(result.content)
      assert length(result.content) == 2
    end

    test "converts tool message" do
      messages = [Message.tool("call_123", %{result: "success"})]

      [result] = Messages.to_openai_format(messages)

      assert result.role == "tool"
      assert result.tool_call_id == "call_123"
      assert is_binary(result.content)
    end

    test "converts legacy assistant response with text only" do
      legacy_message = %{
        parts: [{:text, "Hello!"}],
        usage: %Nous.Usage{},
        model_name: "gpt-4",
        timestamp: DateTime.utc_now()
      }

      message = Message.from_legacy(legacy_message)
      [result] = Messages.to_openai_format([message])

      assert result.role == "assistant"
      assert result.content == "Hello!"
    end

    test "converts legacy assistant response with tool calls" do
      legacy_message = %{
        parts: [
          {:text, "Let me search"},
          {:tool_call, %{id: "call_1", name: "search", arguments: %{"q" => "test"}}}
        ],
        usage: %Nous.Usage{},
        model_name: "gpt-4",
        timestamp: DateTime.utc_now()
      }

      message = Message.from_legacy(legacy_message)
      [result] = Messages.to_openai_format([message])

      assert result["role"] == "assistant"
      assert result["content"] == "Let me search"
      assert is_list(result["tool_calls"])
      assert length(result["tool_calls"]) == 1
    end

    test "converts mixed message sequence" do
      legacy_message = %{
        parts: [{:text, "Hi there!"}],
        usage: %Nous.Usage{},
        model_name: "gpt-4",
        timestamp: DateTime.utc_now()
      }

      messages = [
        Message.system("Be helpful"),
        Message.user("Hello"),
        Message.from_legacy(legacy_message)
      ]

      results = Messages.to_openai_format(messages)

      assert length(results) == 3
      assert Enum.at(results, 0).role == "system"
      assert Enum.at(results, 1).role == "user"
      assert Enum.at(results, 2).role == "assistant"
    end
  end

  describe "from_openai_response/1" do
    test "parses text response" do
      openai_response = %{
        choices: [
          %{
            message: %{
              role: "assistant",
              content: "Hello! How can I help?",
              tool_calls: nil
            },
            finish_reason: "stop"
          }
        ],
        usage: %{
          prompt_tokens: 10,
          completion_tokens: 5,
          total_tokens: 15
        },
        model: "gpt-4"
      }

      result = Messages.from_openai_response(openai_response)

      assert %Message{} = result
      assert result.role == :assistant
      assert result.content == "Hello! How can I help?"
      assert result.metadata.model_name == "gpt-4"
      assert result.metadata.usage.total_tokens == 15
      assert %DateTime{} = result.metadata.timestamp
    end

    test "parses response with tool calls" do
      openai_response = %{
        choices: [
          %{
            message: %{
              role: "assistant",
              content: "Let me search",
              tool_calls: [
                %{
                  id: "call_abc123",
                  type: "function",
                  function: %{
                    name: "search",
                    arguments: ~s({"query":"elixir"})
                  }
                }
              ]
            },
            finish_reason: "tool_calls"
          }
        ],
        usage: %{
          prompt_tokens: 20,
          completion_tokens: 10,
          total_tokens: 30
        },
        model: "gpt-4"
      }

      result = Messages.from_openai_response(openai_response)

      assert %Message{} = result
      assert result.role == :assistant
      assert result.content == "Let me search"
      assert length(result.tool_calls) == 1

      tool_call = List.first(result.tool_calls)
      assert tool_call["id"] == "call_abc123"
      assert tool_call["name"] == "search"
      assert tool_call["arguments"] == %{"query" => "elixir"}
    end

    test "handles response with no content" do
      openai_response = %{
        choices: [
          %{
            message: %{
              role: "assistant",
              content: nil,
              tool_calls: [
                %{
                  id: "call_123",
                  type: "function",
                  function: %{
                    name: "get_data",
                    arguments: ~s({})
                  }
                }
              ]
            },
            finish_reason: "tool_calls"
          }
        ],
        usage: %{
          prompt_tokens: 15,
          completion_tokens: 8,
          total_tokens: 23
        },
        model: "gpt-4"
      }

      result = Messages.from_openai_response(openai_response)

      assert %Message{} = result
      assert result.role == :assistant
      assert result.content == nil
      assert length(result.tool_calls) == 1

      tool_call = List.first(result.tool_calls)
      assert tool_call["id"] == "call_123"
      assert tool_call["name"] == "get_data"
    end
  end
end

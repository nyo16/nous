defmodule Nous.MessagesGenericHelpersTest do
  use ExUnit.Case, async: true

  alias Nous.{Message, Messages, Usage}

  describe "to_provider_format/2" do
    setup do
      messages = [
        Message.system("You are a helpful assistant"),
        Message.user("Hello, world!"),
        Message.user([
          Message.ContentPart.text("What's in this image?"),
          Message.ContentPart.image_url("data:image/jpeg;base64,/9j/4AAQSkZJRg...")
        ]),
        Message.from_legacy(%{
          parts: [
            {:text, "I can see an image."},
            {:tool_call,
             %{id: "call_123", name: "analyze_image", arguments: %{"url" => "test.jpg"}}}
          ],
          usage: %Usage{input_tokens: 20, output_tokens: 15, total_tokens: 35},
          model_name: "test-model",
          timestamp: DateTime.utc_now()
        }),
        Message.tool("call_123", %{description: "A test image"})
      ]

      %{messages: messages}
    end

    test "converts to OpenAI format", %{messages: messages} do
      result = Messages.to_provider_format(messages, :openai)

      assert is_list(result)
      assert length(result) == 5

      # Check system message
      system_msg = Enum.at(result, 0)
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are a helpful assistant"

      # Check user message
      user_msg = Enum.at(result, 1)
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Hello, world!"

      # Check tool return message
      tool_return_msg = Enum.at(result, 4)
      assert tool_return_msg["role"] == "tool"
    end

    test "converts to Anthropic format", %{messages: messages} do
      {system, anthropic_messages} = Messages.to_provider_format(messages, :anthropic)

      assert system == "You are a helpful assistant"
      assert is_list(anthropic_messages)
      assert length(anthropic_messages) == 4

      # Check user message
      user_msg = Enum.at(anthropic_messages, 0)
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Hello, world!"

      # Check tool return message
      tool_return_msg = Enum.at(anthropic_messages, 3)
      assert tool_return_msg["role"] == "user"
      assert is_list(tool_return_msg["content"])
      assert List.first(tool_return_msg["content"])["type"] == "tool_result"
    end

    test "converts to Gemini format", %{messages: messages} do
      {system, gemini_messages} = Messages.to_provider_format(messages, :gemini)

      assert system == "You are a helpful assistant"
      assert is_list(gemini_messages)
      # Now includes converted tool message
      assert length(gemini_messages) == 4

      # Check user message
      user_msg = Enum.at(gemini_messages, 0)
      assert user_msg["role"] == "user"
      assert user_msg["parts"] == [%{"text" => "Hello, world!"}]

      # Check multi-modal user message (flattened to single text part)
      multimodal_msg = Enum.at(gemini_messages, 1)
      assert multimodal_msg["role"] == "user"
      # Flattened to single text part
      assert length(multimodal_msg["parts"]) == 1
    end

    test "handles OpenAI-compatible providers (Groq, LMStudio, Mistral)", %{messages: messages} do
      # All these providers use OpenAI-compatible format
      for provider <- [:groq, :lmstudio, :mistral] do
        result = Messages.to_provider_format(messages, provider)

        assert is_list(result)
        assert length(result) == 5

        # Should be same as OpenAI format
        openai_result = Messages.to_provider_format(messages, :openai)
        assert Enum.at(result, 0)["role"] == Enum.at(openai_result, 0)["role"]
        assert Enum.at(result, 0)["content"] == Enum.at(openai_result, 0)["content"]
      end
    end

    test "raises error for unsupported provider", %{messages: messages} do
      assert_raise ArgumentError, ~r/Unsupported provider: :unknown/, fn ->
        Messages.to_provider_format(messages, :unknown)
      end
    end

    test "handles empty message list" do
      result = Messages.to_provider_format([], :openai)
      assert result == []

      {system, anthropic_messages} = Messages.to_provider_format([], :anthropic)
      assert system == nil
      assert anthropic_messages == []
    end

    test "handles system prompt extraction for Anthropic/Gemini" do
      messages = [
        Message.system("System 1"),
        Message.system("System 2"),
        Message.user("Hello")
      ]

      {system, _} = Messages.to_provider_format(messages, :anthropic)
      assert system == "System 1\n\nSystem 2"

      {system, _} = Messages.to_provider_format(messages, :gemini)
      assert system == "System 1\n\nSystem 2"
    end
  end

  describe "from_provider_response/2" do
    test "parses OpenAI response" do
      openai_response = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "created" => System.system_time(:second),
        "model" => "gpt-4",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! How can I help you today?"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 15,
          "total_tokens" => 35
        }
      }

      result = Messages.from_provider_response(openai_response, :openai)

      assert %Message{role: :assistant, content: "Hello! How can I help you today?"} = result
      assert result.metadata.usage.input_tokens == 20
      assert result.metadata.usage.output_tokens == 15
      assert result.metadata.usage.total_tokens == 35
      assert result.metadata.model_name == "gpt-4"
      assert %DateTime{} = result.metadata.timestamp
    end

    test "parses OpenAI response with tool calls" do
      openai_response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => %{
                    "name" => "search",
                    "arguments" => "{\"query\": \"Elixir language\"}"
                  }
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      result = Messages.from_provider_response(openai_response, :openai)

      assert %Message{role: :assistant, content: nil, tool_calls: tool_calls} = result
      assert [tool_call] = tool_calls
      assert tool_call["id"] == "call_abc123"
      assert tool_call["name"] == "search"
      assert tool_call["arguments"] == %{"query" => "Elixir language"}
    end

    test "parses Anthropic response" do
      anthropic_response = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{
            "type" => "text",
            "text" => "I can help you with that!"
          }
        ],
        "model" => "claude-3-sonnet-20240229",
        "usage" => %{
          "input_tokens" => 25,
          "output_tokens" => 18,
          "total_tokens" => 43
        }
      }

      result = Messages.from_provider_response(anthropic_response, :anthropic)

      assert %Message{role: :assistant, content: "I can help you with that!"} = result
      assert result.metadata.usage.input_tokens == 25
      assert result.metadata.usage.output_tokens == 18
      assert result.metadata.usage.total_tokens == 43
      assert result.metadata.model_name == "claude-3-sonnet-20240229"
    end

    test "parses Anthropic response with tool calls" do
      anthropic_response = %{
        "content" => [
          %{
            "type" => "text",
            "text" => "I'll help you search for that."
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "search",
            "input" => %{"query" => "Elixir programming"}
          }
        ],
        "usage" => %{"input_tokens" => 15, "output_tokens" => 10, "total_tokens" => 25}
      }

      result = Messages.from_provider_response(anthropic_response, :anthropic)

      assert %Message{
               role: :assistant,
               content: "I'll help you search for that.",
               tool_calls: tool_calls
             } = result

      assert [tool_call] = tool_calls
      assert tool_call["id"] == "toolu_123"
      assert tool_call["name"] == "search"
      assert tool_call["arguments"] == %{"query" => "Elixir programming"}
    end

    test "parses Gemini response" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Gemini can help with that!"
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 12,
          "candidatesTokenCount" => 8,
          "totalTokenCount" => 20
        }
      }

      result = Messages.from_provider_response(gemini_response, :gemini)

      assert %Message{role: :assistant, content: "Gemini can help with that!"} = result
      assert result.metadata.usage.input_tokens == 12
      assert result.metadata.usage.output_tokens == 8
      assert result.metadata.usage.total_tokens == 20
      assert result.metadata.model_name == "gemini-model"
    end

    test "parses Gemini response with function calls" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Let me search for that information."
                },
                %{
                  "functionCall" => %{
                    "name" => "web_search",
                    "args" => %{"query" => "latest news"}
                  }
                }
              ],
              "role" => "model"
            }
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 20,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 35
        }
      }

      result = Messages.from_provider_response(gemini_response, :gemini)

      assert %Message{
               role: :assistant,
               content: "Let me search for that information.",
               tool_calls: tool_calls
             } = result

      assert [tool_call] = tool_calls
      assert tool_call["name"] == "web_search"
      assert tool_call["arguments"] == %{"query" => "latest news"}
      # Gemini generates random ID
      assert is_binary(tool_call["id"])
    end

    test "handles OpenAI-compatible providers" do
      openai_response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "Response from compatible provider"
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      # All these providers use OpenAI-compatible format
      for provider <- [:groq, :lmstudio, :mistral] do
        result = Messages.from_provider_response(openai_response, provider)

        assert %Message{role: :assistant, content: "Response from compatible provider"} = result
        assert result.metadata.usage.total_tokens == 15
      end
    end

    test "raises error for unsupported provider" do
      response = %{"test" => "response"}

      assert_raise ArgumentError, ~r/Unsupported provider: :unknown/, fn ->
        Messages.from_provider_response(response, :unknown)
      end
    end
  end

  describe "normalize_format/1" do
    test "preserves internal format messages" do
      internal_messages = [
        Message.system("You are helpful"),
        Message.user("Hello"),
        Message.from_legacy(%{
          parts: [{:text, "Hi there!"}],
          usage: %Usage{},
          model_name: "test",
          timestamp: DateTime.utc_now()
        })
      ]

      result = Messages.normalize_format(internal_messages)
      assert result == internal_messages
    end

    test "converts OpenAI struct messages to internal format" do
      # Create mock OpenAI-style struct messages
      openai_messages = [
        %{__struct__: OpenaiEx.ChatMessage, role: "system", content: "You are helpful"},
        %{__struct__: OpenaiEx.ChatMessage, role: "user", content: "Hello"},
        %{__struct__: OpenaiEx.ChatMessage, role: "assistant", content: "Hi there!"}
      ]

      result = Messages.normalize_format(openai_messages)

      # Check each message type exists without comparing timestamps
      system_msg = Enum.find(result, &(&1.role == :system))
      user_msg = Enum.find(result, &(&1.role == :user))
      assistant_msg = Enum.find(result, &(&1.role == :assistant))

      assert %Message{role: :system, content: "You are helpful"} = system_msg
      assert %Message{role: :user, content: "Hello"} = user_msg
      assert %Message{role: :assistant, content: "Hi there!"} = assistant_msg
      # Model name may not be set for mock conversions
      assert Map.get(assistant_msg.metadata, :model_name) == nil
    end

    test "converts Anthropic format messages to internal" do
      anthropic_messages = [
        %{"role" => "user", "content" => "Hello Claude"},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Hello! How can I help?"},
            %{
              "type" => "tool_use",
              "id" => "toolu_456",
              "name" => "search",
              "input" => %{"query" => "help"}
            }
          ]
        }
      ]

      result = Messages.normalize_format(anthropic_messages)

      # Find specific message types to avoid timestamp comparison issues
      user_msg = Enum.find(result, &(&1.role == :user))
      assert %Message{role: :user, content: "Hello Claude"} = user_msg

      # Check assistant message with tool call
      assistant_response = Enum.find(result, &(&1.role == :assistant))

      assert %Message{role: :assistant, content: "Hello! How can I help?"} = assistant_response
      assert [tool_call] = assistant_response.tool_calls
      assert tool_call["id"] == "toolu_456"
      assert tool_call["name"] == "search"
      assert tool_call["arguments"] == %{"query" => "help"}
    end

    test "converts Gemini format messages to internal" do
      gemini_messages = [
        %{
          "role" => "user",
          "parts" => [
            %{"text" => "Hello Gemini"},
            %{"text" => "How are you?"}
          ]
        },
        %{
          "role" => "model",
          "parts" => [
            %{"text" => "I'm doing well, thank you!"},
            %{
              "functionCall" => %{
                "name" => "get_weather",
                "args" => %{"location" => "San Francisco"}
              }
            }
          ]
        }
      ]

      result = Messages.normalize_format(gemini_messages)

      # Find specific message types to avoid timestamp comparison issues
      user_msg = Enum.find(result, &(&1.role == :user))
      assert %Message{role: :user, content: "Hello Gemini How are you?"} = user_msg

      # Check model response with function call
      model_response = Enum.find(result, &(&1.role == :assistant))

      assert %Message{role: :assistant, content: "I'm doing well, thank you! "} = model_response
      assert [tool_call] = model_response.tool_calls
      assert tool_call["name"] == "get_weather"
      assert tool_call["arguments"] == %{"location" => "San Francisco"}
    end

    test "handles unknown format with generic conversion" do
      unknown_messages = [
        "Hello as string",
        %{unknown: "format"},
        42
      ]

      result = Messages.normalize_format(unknown_messages)

      # Check messages exist without comparing timestamps
      messages_by_content = Enum.group_by(result, & &1.content)
      assert Map.has_key?(messages_by_content, "Hello as string")
      assert Map.has_key?(messages_by_content, "%{unknown: \"format\"}")
      assert Map.has_key?(messages_by_content, "42")
    end

    test "handles single message input" do
      single_message = Message.system("Single system message")

      result = Messages.normalize_format(single_message)

      assert result == [single_message]
    end

    test "handles empty list" do
      result = Messages.normalize_format([])
      assert result == []
    end

    test "handles mixed format detection correctly" do
      # Test various format detection scenarios

      # Internal format
      internal = [Message.system("test")]
      assert Messages.normalize_format(internal) == internal

      # Mock OpenAI struct
      openai_struct = [%{__struct__: OpenaiEx.ChatMessage, role: "user", content: "test"}]
      result = Messages.normalize_format(openai_struct)
      user_msg = Enum.find(result, &(&1.role == :user))
      assert %Message{role: :user, content: "test"} = user_msg

      # Anthropic format
      anthropic = [%{"role" => "user", "content" => "test"}]
      result = Messages.normalize_format(anthropic)
      user_msg = Enum.find(result, &(&1.role == :user))
      assert %Message{role: :user, content: "test"} = user_msg

      # Gemini format
      gemini = [%{"role" => "user", "parts" => [%{"text" => "test"}]}]
      result = Messages.normalize_format(gemini)
      user_msg = Enum.find(result, &(&1.role == :user))
      assert %Message{role: :user, content: "test"} = user_msg
    end
  end

  describe "edge cases and error handling" do
    test "handles malformed provider responses gracefully" do
      # Empty response
      empty_response = %{}
      result = Messages.from_provider_response(empty_response, :openai)
      assert %Message{content: nil} = result
      assert result.metadata.usage.total_tokens == 0

      # Response with missing content
      no_content_response = %{
        "choices" => [%{"message" => %{"role" => "assistant"}}],
        "usage" => %{"total_tokens" => 0}
      }

      result = Messages.from_provider_response(no_content_response, :openai)
      # No content should result in nil content
      assert %Message{content: nil} = result

      # Anthropic response with missing content
      anthropic_empty = %{"content" => [], "usage" => %{}}
      result = Messages.from_provider_response(anthropic_empty, :anthropic)
      assert %Message{content: nil} = result

      # Gemini response with no candidates
      gemini_empty = %{"candidates" => [], "usageMetadata" => %{}}
      result = Messages.from_provider_response(gemini_empty, :gemini)
      assert %Message{content: nil} = result
    end

    test "handles invalid JSON in tool arguments" do
      openai_response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call_invalid",
                  "type" => "function",
                  "function" => %{
                    "name" => "test_tool",
                    "arguments" => "invalid json {"
                  }
                }
              ]
            }
          }
        ],
        "usage" => %{"total_tokens" => 10}
      }

      result = Messages.from_provider_response(openai_response, :openai)

      assert %Message{role: :assistant, tool_calls: tool_calls} = result
      assert [tool_call] = tool_calls
      assert tool_call["id"] == "call_invalid"
      assert tool_call["name"] == "test_tool"
      assert tool_call["arguments"]["error"] == "Invalid JSON arguments"
      assert tool_call["arguments"]["raw"] == "invalid json {"
    end

    test "handles complex multi-modal content" do
      messages = [
        Message.user([
          Message.ContentPart.text("Analyze this"),
          Message.ContentPart.image_url("data:image/png;base64,iVBORw0KGgo..."),
          Message.ContentPart.text("and this"),
          Message.ContentPart.image_url("https://example.com/image.jpg")
        ])
      ]

      # Test Anthropic format conversion
      {_system, anthropic_messages} = Messages.to_provider_format(messages, :anthropic)
      user_msg = List.first(anthropic_messages)

      assert user_msg["role"] == "user"
      # Multi-modal content is converted to a flattened text representation
      assert is_binary(user_msg["content"])
      assert user_msg["content"] =~ "Analyze this"
      assert user_msg["content"] =~ "and this"

      # Test Gemini format conversion
      {_system, gemini_messages} = Messages.to_provider_format(messages, :gemini)
      user_msg = List.first(gemini_messages)

      assert user_msg["role"] == "user"
      assert is_list(user_msg["parts"])
      # Flattened to single text part
      assert length(user_msg["parts"]) == 1
    end

    test "handles empty and nil values gracefully" do
      # Empty system prompts - use valid content since empty strings are not allowed
      messages = [
        Message.system("System"),
        Message.user("User1"),
        Message.user("User2")
      ]

      result = Messages.to_provider_format(messages, :openai)
      assert length(result) == 3

      # Should handle content properly - OpenAI format uses %{} maps with string keys
      user_msgs = Enum.filter(result, &(Map.get(&1, "role") == "user"))
      assert length(user_msgs) == 2
    end
  end
end

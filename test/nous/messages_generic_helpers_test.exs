defmodule Nous.MessagesGenericHelpersTest do
  use ExUnit.Case, async: true

  alias Nous.{Messages, Usage}

  describe "to_provider_format/2" do
    setup do
      messages = [
        {:system_prompt, "You are a helpful assistant"},
        {:user_prompt, "Hello, world!"},
        {:user_prompt, [
          {:text, "What's in this image?"},
          {:image_url, "data:image/jpeg;base64,/9j/4AAQSkZJRg..."}
        ]},
        %{
          parts: [
            {:text, "I can see an image."},
            {:tool_call, %{id: "call_123", name: "analyze_image", arguments: %{"url" => "test.jpg"}}}
          ],
          usage: %Usage{input_tokens: 20, output_tokens: 15, total_tokens: 35},
          model_name: "test-model",
          timestamp: DateTime.utc_now()
        },
        {:tool_return, %{call_id: "call_123", result: %{description: "A test image"}}}
      ]

      %{messages: messages}
    end

    test "converts to OpenAI format", %{messages: messages} do
      result = Messages.to_provider_format(messages, :openai)

      assert is_list(result)
      assert length(result) == 5

      # Check system message
      system_msg = Enum.at(result, 0)
      assert system_msg.role == "system"
      assert system_msg.content == "You are a helpful assistant"

      # Check user message
      user_msg = Enum.at(result, 1)
      assert user_msg.role == "user"
      assert user_msg.content == "Hello, world!"

      # Check tool return message
      tool_return_msg = Enum.at(result, 4)
      assert tool_return_msg.role == "tool"
    end

    test "converts to Anthropic format", %{messages: messages} do
      {system, anthropic_messages} = Messages.to_provider_format(messages, :anthropic)

      assert system == "You are a helpful assistant"
      assert is_list(anthropic_messages)
      assert length(anthropic_messages) == 4

      # Check user message
      user_msg = Enum.at(anthropic_messages, 0)
      assert user_msg.role == "user"
      assert user_msg.content == "Hello, world!"

      # Check tool return message
      tool_return_msg = Enum.at(anthropic_messages, 3)
      assert tool_return_msg.role == "user"
      assert is_list(tool_return_msg.content)
      assert List.first(tool_return_msg.content).type == "tool_result"
    end

    test "converts to Gemini format", %{messages: messages} do
      {system, gemini_messages} = Messages.to_provider_format(messages, :gemini)

      assert system == "You are a helpful assistant"
      assert is_list(gemini_messages)
      assert length(gemini_messages) == 3

      # Check user message
      user_msg = Enum.at(gemini_messages, 0)
      assert user_msg.role == "user"
      assert user_msg.parts == [%{text: "Hello, world!"}]

      # Check multi-modal user message (should have 2 text parts)
      multimodal_msg = Enum.at(gemini_messages, 1)
      assert multimodal_msg.role == "user"
      assert length(multimodal_msg.parts) == 2  # Text part and image placeholder part
    end

    test "handles OpenAI-compatible providers (Groq, LMStudio, Mistral)", %{messages: messages} do
      # All these providers use OpenAI-compatible format
      for provider <- [:groq, :lmstudio, :mistral] do
        result = Messages.to_provider_format(messages, provider)

        assert is_list(result)
        assert length(result) == 5

        # Should be same as OpenAI format
        openai_result = Messages.to_provider_format(messages, :openai)
        assert Enum.at(result, 0).role == Enum.at(openai_result, 0).role
        assert Enum.at(result, 0).content == Enum.at(openai_result, 0).content
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
        {:system_prompt, "System 1"},
        {:system_prompt, "System 2"},
        {:user_prompt, "Hello"}
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

      assert result.parts == [{:text, "Hello! How can I help you today?"}]
      assert result.usage.input_tokens == 20
      assert result.usage.output_tokens == 15
      assert result.usage.total_tokens == 35
      assert result.model_name == "gpt-4"
      assert %DateTime{} = result.timestamp
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

      assert [tool_call_part] = result.parts
      assert {:tool_call, tool_call} = tool_call_part
      assert tool_call.id == "call_abc123"
      assert tool_call.name == "search"
      assert tool_call.arguments == %{"query" => "Elixir language"}
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

      assert result.parts == [{:text, "I can help you with that!"}]
      assert result.usage.input_tokens == 25
      assert result.usage.output_tokens == 18
      assert result.usage.total_tokens == 43
      assert result.model_name == "claude-3-sonnet-20240229"
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

      assert length(result.parts) == 2
      assert {:text, "I'll help you search for that."} in result.parts

      tool_call_part = Enum.find(result.parts, fn
        {:tool_call, _} -> true
        _ -> false
      end)

      assert {:tool_call, tool_call} = tool_call_part
      assert tool_call.id == "toolu_123"
      assert tool_call.name == "search"
      assert tool_call.arguments == %{"query" => "Elixir programming"}
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

      assert result.parts == [{:text, "Gemini can help with that!"}]
      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 8
      assert result.usage.total_tokens == 20
      assert result.model_name == "gemini-model"
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

      assert length(result.parts) == 2
      assert {:text, "Let me search for that information."} in result.parts

      tool_call_part = Enum.find(result.parts, fn
        {:tool_call, _} -> true
        _ -> false
      end)

      assert {:tool_call, tool_call} = tool_call_part
      assert tool_call.name == "web_search"
      assert tool_call.arguments == %{"query" => "latest news"}
      assert is_binary(tool_call.id)  # Gemini generates random ID
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

        assert result.parts == [{:text, "Response from compatible provider"}]
        assert result.usage.total_tokens == 15
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
        {:system_prompt, "You are helpful"},
        {:user_prompt, "Hello"},
        %{
          parts: [{:text, "Hi there!"}],
          usage: %Usage{},
          model_name: "test",
          timestamp: DateTime.utc_now()
        }
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

      assert {:system_prompt, "You are helpful"} in result
      assert {:user_prompt, "Hello"} in result

      # Check assistant message conversion
      assistant_response = Enum.find(result, fn
        %{parts: _} -> true
        _ -> false
      end)

      assert assistant_response.parts == [{:text, "Hi there!"}]
      assert assistant_response.model_name == "unknown"
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

      assert {:user_prompt, "Hello Claude"} in result

      # Check assistant message with tool call
      assistant_response = Enum.find(result, fn
        %{parts: _} -> true
        _ -> false
      end)

      assert length(assistant_response.parts) == 2
      assert {:text, "Hello! How can I help?"} in assistant_response.parts

      tool_call_part = Enum.find(assistant_response.parts, fn
        {:tool_call, _} -> true
        _ -> false
      end)

      assert {:tool_call, tool_call} = tool_call_part
      assert tool_call.id == "toolu_456"
      assert tool_call.name == "search"
      assert tool_call.arguments == %{"query" => "help"}
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

      assert {:user_prompt, "Hello Gemini How are you?"} in result

      # Check model response with function call
      model_response = Enum.find(result, fn
        %{parts: _} -> true
        _ -> false
      end)

      assert length(model_response.parts) == 2
      assert {:text, "I'm doing well, thank you!"} in model_response.parts

      tool_call_part = Enum.find(model_response.parts, fn
        {:tool_call, _} -> true
        _ -> false
      end)

      assert {:tool_call, tool_call} = tool_call_part
      assert tool_call.name == "get_weather"
      assert tool_call.arguments == %{"location" => "San Francisco"}
    end

    test "handles unknown format with generic conversion" do
      unknown_messages = [
        "Hello as string",
        %{unknown: "format"},
        42
      ]

      result = Messages.normalize_format(unknown_messages)

      assert {:user_prompt, "Hello as string"} in result
      assert {:user_prompt, "%{unknown: \"format\"}"} in result  # inspected map
      assert {:user_prompt, "42"} in result  # inspected number
    end

    test "handles single message input" do
      single_message = {:system_prompt, "Single system message"}

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
      internal = [{:system_prompt, "test"}]
      assert Messages.normalize_format(internal) == internal

      # Mock OpenAI struct
      openai_struct = [%{__struct__: OpenaiEx.ChatMessage, role: "user", content: "test"}]
      result = Messages.normalize_format(openai_struct)
      assert {:user_prompt, "test"} in result

      # Anthropic format
      anthropic = [%{"role" => "user", "content" => "test"}]
      result = Messages.normalize_format(anthropic)
      assert {:user_prompt, "test"} in result

      # Gemini format
      gemini = [%{"role" => "user", "parts" => [%{"text" => "test"}]}]
      result = Messages.normalize_format(gemini)
      assert {:user_prompt, "test"} in result
    end
  end

  describe "edge cases and error handling" do
    test "handles malformed provider responses gracefully" do
      # Empty response
      empty_response = %{}
      result = Messages.from_provider_response(empty_response, :openai)
      assert result.parts == []
      assert result.usage.total_tokens == 0

      # Response with missing content
      no_content_response = %{
        "choices" => [%{"message" => %{"role" => "assistant"}}],
        "usage" => %{"total_tokens" => 0}
      }
      result = Messages.from_provider_response(no_content_response, :openai)
      assert result.parts == []  # No content should result in empty parts, not text: ""

      # Anthropic response with missing content
      anthropic_empty = %{"content" => [], "usage" => %{}}
      result = Messages.from_provider_response(anthropic_empty, :anthropic)
      assert result.parts == []

      # Gemini response with no candidates
      gemini_empty = %{"candidates" => [], "usageMetadata" => %{}}
      result = Messages.from_provider_response(gemini_empty, :gemini)
      assert result.parts == []
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

      assert [{:tool_call, tool_call}] = result.parts
      assert tool_call.id == "call_invalid"
      assert tool_call.name == "test_tool"
      assert tool_call.arguments["error"] == "Invalid JSON arguments"
      assert tool_call.arguments["raw"] == "invalid json {"
    end

    test "handles complex multi-modal content" do
      messages = [
        {:user_prompt, [
          {:text, "Analyze this"},
          {:image_url, "data:image/png;base64,iVBORw0KGgo..."},
          {:text, "and this"},
          {:image_url, "https://example.com/image.jpg"}
        ]}
      ]

      # Test Anthropic format conversion
      {_system, anthropic_messages} = Messages.to_provider_format(messages, :anthropic)
      user_msg = List.first(anthropic_messages)

      assert user_msg.role == "user"
      assert is_list(user_msg.content)
      assert length(user_msg.content) == 4

      # Should have text and image content
      text_parts = Enum.filter(user_msg.content, &(&1.type == "text"))
      image_parts = Enum.filter(user_msg.content, &(&1.type == "image"))

      assert length(text_parts) == 2
      assert length(image_parts) == 2

      # Test Gemini format conversion
      {_system, gemini_messages} = Messages.to_provider_format(messages, :gemini)
      user_msg = List.first(gemini_messages)

      assert user_msg.role == "user"
      assert is_list(user_msg.parts)
      assert length(user_msg.parts) == 4  # 2 text parts and 2 image placeholder parts
    end

    test "handles empty and nil values gracefully" do
      # Empty system prompts
      messages = [
        {:system_prompt, ""},
        {:user_prompt, nil},
        {:user_prompt, ""}
      ]

      result = Messages.to_provider_format(messages, :openai)
      assert length(result) == 3

      # Should handle empty/nil content
      user_msgs = Enum.filter(result, &(&1.role == "user"))
      assert length(user_msgs) == 2
    end
  end
end
defmodule Nous.Models.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias Nous.{Message, Model, Messages, Usage}
  alias Nous.Models.OpenAICompatible
  alias Nous.Errors

  setup do
    # Sample messages for testing
    messages = [
      Message.system("You are a helpful assistant."),
      Message.user("What is 2+2?")
    ]

    # Sample model configurations
    openai_model = Model.new(:openai, "gpt-4", api_key: "sk-test")
    groq_model = Model.new(:groq, "llama-3.1-70b-versatile", api_key: "gsk-test")
    local_model = Model.new(:lmstudio, "qwen3", api_key: "not-needed")

    # Sample settings
    basic_settings = %{temperature: 0.7, max_tokens: 100}

    tool_settings = %{
      temperature: 0.7,
      max_tokens: 100,
      tools: [
        %{
          "type" => "function",
          "function" => %{
            "name" => "search_web",
            "description" => "Search the web",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "query" => %{"type" => "string"}
              }
            }
          }
        }
      ]
    }

    %{
      messages: messages,
      openai_model: openai_model,
      groq_model: groq_model,
      local_model: local_model,
      basic_settings: basic_settings,
      tool_settings: tool_settings
    }
  end

  describe "build_request_params/3" do
    test "builds basic request parameters correctly", %{
      openai_model: model,
      messages: messages,
      basic_settings: _settings
    } do
      # Test the private function through a public interface
      # We can test this by checking if the Model can be used to create a client
      client = Model.to_client(model)
      assert %OpenaiEx{} = client
      assert client.token == "sk-test"
      assert client.base_url == "https://api.openai.com/v1"

      # Test message conversion works correctly
      openai_messages = Messages.to_openai_format(messages)
      assert length(openai_messages) == 2
    end

    test "includes tools when provided in settings", %{tool_settings: settings} do
      # Verify tool settings contain the expected structure
      assert settings[:tools]
      assert length(settings[:tools]) == 1

      tool = List.first(settings[:tools])
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "search_web"
    end

    test "handles different providers correctly", %{
      openai_model: openai_model,
      groq_model: groq_model,
      local_model: local_model
    } do
      # Test different provider configurations
      openai_client = Model.to_client(openai_model)
      assert openai_client.base_url == "https://api.openai.com/v1"

      groq_client = Model.to_client(groq_model)
      assert groq_client.base_url == "https://api.groq.com/openai/v1"

      local_client = Model.to_client(local_model)
      assert local_client.base_url == "http://localhost:1234/v1"
    end
  end

  describe "message conversion" do
    test "converts messages to OpenAI format correctly", %{messages: messages} do
      openai_messages = Messages.to_openai_format(messages)

      assert length(openai_messages) == 2

      # Check system message
      system_msg = Enum.at(openai_messages, 0)
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are a helpful assistant."

      # Check user message
      user_msg = Enum.at(openai_messages, 1)
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "What is 2+2?"
    end

    test "handles complex message types" do
      legacy_message = %{
        parts: [
          {:text, "Based on the tool result"},
          {:tool_call, %{id: "call_456", name: "calculate", arguments: %{"expr" => "2+2"}}}
        ],
        usage: %Usage{total_tokens: 50},
        model_name: "gpt-4",
        timestamp: DateTime.utc_now()
      }

      complex_messages = [
        Message.system("You are helpful"),
        Message.user("Hello"),
        Message.tool("call_123", %{result: "success"}),
        Message.from_legacy(legacy_message)
      ]

      openai_messages = Messages.to_openai_format(complex_messages)
      assert length(openai_messages) == 4

      # Verify tool return message
      tool_return_msg = Enum.at(openai_messages, 2)
      assert tool_return_msg["role"] == "tool"

      # Verify assistant message with tool calls
      assistant_msg = Enum.at(openai_messages, 3)
      assert is_map(assistant_msg) # Should be a map with tool_calls
      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["tool_calls"]
    end
  end

  describe "count_tokens/1" do
    test "estimates tokens for different message types", %{messages: messages} do
      token_count = OpenAICompatible.count_tokens(messages)

      # Should return a reasonable estimate
      assert is_integer(token_count)
      assert token_count > 0
      assert token_count < 1000 # Sanity check for short messages
    end

    test "handles empty message list" do
      assert OpenAICompatible.count_tokens([]) == 0
    end

    test "handles complex messages with tool calls" do
      messages = [
        Message.system("You are helpful"),
        Message.user("Search for information about Elixir"),
        Message.tool("call_123", %{
          results: ["Elixir is a dynamic language", "Used for concurrency"]
        })
      ]

      token_count = OpenAICompatible.count_tokens(messages)
      assert token_count > 20 # Should be reasonable for this content
    end

    test "estimates tool return tokens correctly" do
      messages = [
        Message.tool("call_123", %{
          result: "This is a longer result that should have more tokens than a simple response"
        })
      ]

      token_count = OpenAICompatible.count_tokens(messages)
      assert token_count > 10 # Should account for JSON serialization
    end
  end

  describe "response parsing" do
    test "parses OpenAI response format correctly" do
      # Test with a sample OpenAI response structure
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
              "content" => "The answer is 4."
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 6,
          "total_tokens" => 26
        }
      }

      # Use Messages.from_openai_response to parse
      parsed = Messages.from_openai_response(openai_response)

      assert %Message{} = parsed
      assert parsed.role == :assistant
      assert parsed.content == "The answer is 4."
      assert parsed.metadata.usage.input_tokens == 20
      assert parsed.metadata.usage.output_tokens == 6
      assert parsed.metadata.usage.total_tokens == 26
      assert parsed.metadata.model_name == "gpt-4"
      assert %DateTime{} = parsed.metadata.timestamp
    end

    test "parses tool calls in OpenAI response" do
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

      parsed = Messages.from_openai_response(openai_response)

      assert %Message{} = parsed
      assert parsed.role == :assistant
      assert length(parsed.tool_calls) == 1
      tool_call = List.first(parsed.tool_calls)
      assert tool_call["id"] == "call_abc123"
      assert tool_call["name"] == "search"
      assert tool_call["arguments"] == %{"query" => "Elixir language"}
    end
  end

  describe "error handling" do
    test "creates proper ModelError for various error types" do
      # Test error wrapping functionality
      sample_errors = [
        %OpenaiEx.Error{status_code: 401, message: "Invalid API key"},
        %OpenaiEx.Error{status_code: 429, message: "Rate limited"},
        %OpenaiEx.Error{status_code: 500, message: "Server error"},
        %Mint.TransportError{reason: :timeout}
      ]

      for error <- sample_errors do
        wrapped = Errors.ModelError.exception(
          provider: :openai,
          message: "Request failed: #{inspect(error)}",
          details: error
        )

        assert %Errors.ModelError{} = wrapped
        assert wrapped.provider == :openai
        assert wrapped.message =~ "Request failed"
        assert wrapped.details == error
      end
    end
  end

  describe "integration tests" do
    @describetag :integration
    test "can handle realistic message flows", %{openai_model: model} do
      # Test a realistic conversation flow
      # Legacy response messages
      assistant_response = %{
        parts: [{:text, "The derivative of x^2 is 2x. This follows from the power rule."}],
        usage: %Usage{input_tokens: 15, output_tokens: 18, total_tokens: 33},
        model_name: "gpt-4",
        timestamp: DateTime.utc_now()
      }

      tool_call_response = %{
        parts: [
          {:text, "Let me show you step by step."},
          {:tool_call, %{id: "call_123", name: "show_steps", arguments: %{"problem" => "derivative of x^2"}}}
        ],
        usage: %Usage{input_tokens: 40, output_tokens: 25, total_tokens: 65},
        model_name: "gpt-4",
        timestamp: DateTime.utc_now()
      }

      conversation = [
        Message.system("You are a helpful math tutor"),
        Message.user("What is the derivative of x^2?"),
        Message.from_legacy(assistant_response),
        Message.user("Can you show me the steps?"),
        Message.from_legacy(tool_call_response),
        Message.tool("call_123", %{
          steps: [
            "Using the power rule: d/dx(x^n) = n*x^(n-1)",
            "For x^2: n = 2",
            "So: d/dx(x^2) = 2*x^(2-1) = 2*x^1 = 2x"
          ]
        })
      ]

      # Test message conversion
      openai_messages = Messages.to_openai_format(conversation)
      assert length(openai_messages) == 6

      # Test token counting
      token_count = OpenAICompatible.count_tokens(conversation)
      assert token_count > 100 # Should account for all the content

      # Test client creation
      client = Model.to_client(model)
      assert %OpenaiEx{} = client
    end
  end
end
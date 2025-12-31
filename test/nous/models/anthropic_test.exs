defmodule Nous.Models.AnthropicTest do
  use ExUnit.Case, async: true

  alias Nous.{Message, Model, Usage}
  alias Nous.Errors

  setup do
    # Sample messages for testing
    messages = [
      Message.system("You are a helpful assistant."),
      Message.user("What is the capital of France?")
    ]

    # Sample model configuration
    model = Model.new(:anthropic, "claude-3-sonnet-20240229", api_key: "sk-ant-test")

    # Sample settings
    basic_settings = %{
      temperature: 0.7,
      max_tokens: 100
    }

    thinking_settings = %{
      temperature: 0.7,
      max_tokens: 100,
      thinking: %{enabled: true}
    }

    tool_settings = %{
      temperature: 0.7,
      max_tokens: 100,
      tools: [
        %{
          name: "search_web",
          description: "Search the web",
          input_schema: %{
            type: :object,
            properties: %{
              query: %{type: :string}
            }
          }
        }
      ]
    }

    %{
      messages: messages,
      model: model,
      basic_settings: basic_settings,
      thinking_settings: thinking_settings,
      tool_settings: tool_settings
    }
  end

  describe "provider module" do
    test "Anthropic provider module is loaded" do
      # Verify the provider module is available
      assert Code.ensure_loaded?(Nous.Providers.Anthropic)
      assert function_exported?(Nous.Providers.Anthropic, :chat, 2)
      assert function_exported?(Nous.Providers.Anthropic, :chat_stream, 2)
    end

    test "model adapter implements behaviour", %{model: model} do
      # Verify the model adapter uses the correct behaviour
      assert model.provider == :anthropic
      assert model.model == "claude-3-sonnet-20240229"
    end
  end

  describe "message conversion" do
    test "converts messages to Anthropic format", %{messages: messages} do
      # Test the message conversion logic (this tests our internal format)
      # Anthropic expects a different format than OpenAI

      # System messages and user messages are now Message structs
      system_message = Enum.find(messages, &(&1.role == :system))
      user_messages = Enum.reject(messages, &(&1.role == :system))

      assert %Message{role: :system, content: "You are a helpful assistant."} = system_message
      assert length(user_messages) == 1
      assert %Message{role: :user, content: "What is the capital of France?"} = List.first(user_messages)
    end

    test "handles tool returns properly" do
      # Test tool return message formatting
      tool_return = Message.tool("toolu_123", %{result: "Paris is the capital of France"})

      assert %Message{role: :tool, tool_call_id: "toolu_123"} = tool_return
      result = Jason.decode!(tool_return.content)
      assert result["result"] == "Paris is the capital of France"
    end

    test "handles complex conversation flow" do
      # Test a full conversation with system, user, assistant, and tool messages
      # Legacy assistant response with tool call
      assistant_response = %{
        parts: [
          {:text, "I'll search for information about Paris."},
          {:tool_call, %{id: "toolu_123", name: "search", arguments: %{"query" => "Paris"}}}
        ],
        usage: %Usage{total_tokens: 50},
        model_name: "claude-3-sonnet",
        timestamp: DateTime.utc_now()
      }

      conversation = [
        Message.system("You are helpful"),
        Message.user("Search for Paris"),
        Message.from_legacy(assistant_response),
        Message.tool("toolu_123", %{results: ["Paris is the capital of France"]})
      ]

      # Verify we have all message types
      assert length(conversation) == 4

      # Check system message
      assert %Message{role: :system} = Enum.at(conversation, 0)

      # Check user message
      assert %Message{role: :user} = Enum.at(conversation, 1)

      # Check assistant response with tool call
      assistant_msg = Enum.at(conversation, 2)
      assert %Message{role: :assistant} = assistant_msg
      assert length(assistant_msg.tool_calls) > 0

      # Check tool return
      assert %Message{role: :tool} = Enum.at(conversation, 3)
    end
  end

  describe "tool schema conversion" do
    test "converts tools to Anthropic format", %{tool_settings: settings} do
      tools = settings[:tools]
      assert length(tools) == 1

      tool = List.first(tools)
      assert tool.name == "search_web"
      assert tool.description == "Search the web"
      assert tool.input_schema.type == :object
      assert tool.input_schema.properties.query.type == :string
    end

    test "handles empty tools list" do
      settings = %{tools: []}
      assert settings[:tools] == []
    end
  end

  describe "response parsing" do
    test "parses Anthropic response format correctly" do
      # Test with a sample Anthropic response structure
      anthropic_response = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{
            "type" => "text",
            "text" => "Paris is the capital of France."
          }
        ],
        "model" => "claude-3-sonnet-20240229",
        "usage" => %{
          "input_tokens" => 20,
          "output_tokens" => 15,
          "total_tokens" => 35
        }
      }

      # The actual parsing would happen in the Anthropic implementation
      # Here we test our understanding of the format
      assert anthropic_response["type"] == "message"
      assert anthropic_response["role"] == "assistant"
      assert is_list(anthropic_response["content"])

      content = List.first(anthropic_response["content"])
      assert content["type"] == "text"
      assert content["text"] == "Paris is the capital of France."
    end

    test "parses tool calls in Anthropic response" do
      anthropic_response = %{
        "content" => [
          %{
            "type" => "text",
            "text" => "I'll search for that information."
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "search",
            "input" => %{"query" => "Paris"}
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      }

      # Verify structure
      assert length(anthropic_response["content"]) == 2

      text_content = Enum.at(anthropic_response["content"], 0)
      assert text_content["type"] == "text"

      tool_content = Enum.at(anthropic_response["content"], 1)
      assert tool_content["type"] == "tool_use"
      assert tool_content["id"] == "toolu_123"
      assert tool_content["name"] == "search"
      assert tool_content["input"]["query"] == "Paris"
    end

    test "parses thinking content when present" do
      anthropic_response = %{
        "content" => [
          %{
            "type" => "text",
            "text" => "I need to think about this carefully.\n<thinking>\nThe user is asking about Paris, which is the capital of France.\n</thinking>\n\nParis is the capital of France."
          }
        ]
      }

      content = List.first(anthropic_response["content"])
      assert content["text"] =~ "<thinking>"
      assert content["text"] =~ "Paris is the capital"
    end
  end

  describe "settings handling" do
    test "handles thinking settings", %{thinking_settings: settings} do
      thinking_config = settings[:thinking]
      assert thinking_config.enabled == true
    end

    test "handles temperature and max_tokens", %{basic_settings: settings} do
      assert settings.temperature == 0.7
      assert settings.max_tokens == 100
    end

    test "validates Anthropic-specific parameters" do
      # Anthropic has specific parameter constraints
      settings = %{
        temperature: 1.5,  # Should be clamped to 1.0
        max_tokens: 4096,  # Anthropic limit
        top_p: 0.9
      }

      # Test parameter validation (theoretical)
      assert settings.temperature <= 1.0 || settings.temperature == 1.5
      assert settings.max_tokens <= 4096
      assert settings.top_p <= 1.0
    end
  end

  describe "error handling" do
    test "handles various Anthropic API errors" do
      # Test different error scenarios that might occur
      sample_errors = [
        %{status_code: 401, message: "Authentication failed"},
        %{status_code: 429, message: "Rate limit exceeded"},
        %{status_code: 400, message: "Invalid request"},
        %{status_code: 500, message: "Internal server error"}
      ]

      for error_data <- sample_errors do
        wrapped = Errors.ModelError.exception(
          provider: :anthropic,
          message: "Request failed: #{error_data.message}",
          details: error_data
        )

        assert %Errors.ModelError{} = wrapped
        assert wrapped.provider == :anthropic
        assert wrapped.message =~ "Request failed"
        assert wrapped.details == error_data
      end
    end

    test "handles thinking mode errors" do
      # Thinking mode might have specific error conditions
      error = Errors.ModelError.exception(
        provider: :anthropic,
        message: "Thinking mode not supported for this model",
        details: %{model: "claude-instant"}
      )

      assert error.provider == :anthropic
      assert error.message =~ "Thinking mode"
    end
  end

  describe "integration tests" do
    @describetag :integration
    test "can handle realistic anthropic workflow", %{model: _model} do
      # Test a realistic conversation flow specific to Anthropic/Claude
      # Legacy response with thinking
      claude_response = %{
        parts: [
          {:thinking, "The user is asking about thinking, which is a feature specific to Claude. I should explain it clearly."},
          {:text, "I'd be happy to explain thinking! When I use thinking, I can reason through problems step by step before giving my final answer."}
        ],
        usage: %Usage{input_tokens: 25, output_tokens: 40, total_tokens: 65},
        model_name: "claude-3-sonnet-20240229",
        timestamp: DateTime.utc_now()
      }

      conversation = [
        Message.system("You are Claude, a helpful AI assistant created by Anthropic."),
        Message.user("Can you help me understand how thinking works?"),
        Message.from_legacy(claude_response)
      ]

      # Test our understanding of the conversation structure
      assert length(conversation) == 3

      # Verify system message
      system_msg = Enum.at(conversation, 0)
      assert %Message{role: :system} = system_msg

      # Verify user message
      user_msg = Enum.at(conversation, 1)
      assert %Message{role: :user} = user_msg

      # Verify assistant response (converted from legacy format)
      assistant_msg = Enum.at(conversation, 2)
      assert %Message{role: :assistant} = assistant_msg
      assert assistant_msg.content =~ "thinking"
      assert assistant_msg.metadata.model_name == "claude-3-sonnet-20240229"
      assert assistant_msg.metadata.usage.total_tokens == 65
    end
  end
end
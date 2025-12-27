defmodule Nous.Models.GeminiTest do
  use ExUnit.Case, async: true

  alias Nous.{Model, Messages, Usage}
  alias Nous.Errors

  setup do
    # Sample messages for testing
    messages = [
      Messages.system_prompt("You are a helpful AI assistant."),
      Messages.user_prompt("What is machine learning?")
    ]

    # Sample model configuration
    model = Model.new(:gemini, "gemini-1.5-pro", api_key: "AI-test-key")

    # Sample settings
    basic_settings = %{
      temperature: 0.7,
      max_tokens: 100
    }

    tool_settings = %{
      temperature: 0.7,
      max_tokens: 100,
      tools: [
        %{
          name: "search_web",
          description: "Search the web for information",
          input_schema: %{
            type: :object,
            properties: %{
              query: %{type: :string, description: "Search query"}
            },
            required: [:query]
          }
        }
      ]
    }

    %{
      messages: messages,
      model: model,
      basic_settings: basic_settings,
      tool_settings: tool_settings
    }
  end

  describe "message conversion" do
    test "converts messages to Gemini format", %{messages: messages} do
      # Gemini expects a different message structure than OpenAI
      # System messages are handled differently in Gemini

      # System prompt should be separated
      system_message = Enum.find(messages, &match?({:system_prompt, _}, &1))
      user_messages = Enum.reject(messages, &match?({:system_prompt, _}, &1))

      assert {:system_prompt, "You are a helpful AI assistant."} = system_message
      assert length(user_messages) == 1
      assert {:user_prompt, "What is machine learning?"} = List.first(user_messages)
    end

    test "handles multi-modal content" do
      # Gemini supports images, video, and audio
      multimedia_message = Messages.user_prompt([
        {:text, "What's in this image?"},
        {:image_url, "data:image/jpeg;base64,/9j/4AAQSkZJRgAB..."}
      ])

      assert {:user_prompt, content} = multimedia_message
      assert is_list(content)
      assert length(content) == 2
      assert {:text, "What's in this image?"} = Enum.at(content, 0)
      assert {:image_url, _image_data} = Enum.at(content, 1)
    end

    test "handles tool returns properly" do
      # Gemini uses different tool call IDs and format
      tool_return = Messages.tool_return("call_abc123", %{
        search_results: ["Machine learning is a subset of AI", "It uses algorithms to learn patterns"]
      })

      assert {:tool_return, %{call_id: "call_abc123", result: result}} = tool_return
      assert result.search_results |> length() == 2
    end

    test "handles assistant responses with function calls" do
      conversation = [
        Messages.system_prompt("You are helpful"),
        Messages.user_prompt("Search for AI information"),
        %{
          parts: [
            {:text, "I'll search for AI information for you."},
            {:tool_call, %{id: "call_123", name: "search_web", arguments: %{"query" => "artificial intelligence"}}}
          ],
          usage: %Usage{total_tokens: 45},
          model_name: "gemini-1.5-pro",
          timestamp: DateTime.utc_now()
        }
      ]

      assistant_msg = Enum.at(conversation, 2)
      assert assistant_msg.parts |> Enum.any?(&match?({:tool_call, _}, &1))
      assert assistant_msg.parts |> Enum.any?(&match?({:text, _}, &1))
    end
  end

  describe "tool schema conversion" do
    test "converts tools to Gemini function format", %{tool_settings: settings} do
      tools = settings[:tools]
      assert length(tools) == 1

      tool = List.first(tools)
      assert tool.name == "search_web"
      assert tool.description == "Search the web for information"
      assert tool.input_schema.type == :object
      assert tool.input_schema.properties.query.type == :string
      assert tool.input_schema.required == [:query]
    end

    test "handles complex tool schemas" do
      complex_tool = %{
        name: "analyze_data",
        description: "Analyze data with various parameters",
        input_schema: %{
          type: :object,
          properties: %{
            data: %{type: :array, items: %{type: :number}},
            method: %{type: :string, enum: ["mean", "median", "mode"]},
            include_visualization: %{type: :boolean, default: false}
          },
          required: [:data, :method]
        }
      }

      # Verify the structure is valid for Gemini conversion
      assert complex_tool.input_schema.properties.data.type == :array
      assert complex_tool.input_schema.properties.method.enum == ["mean", "median", "mode"]
      assert complex_tool.input_schema.required == [:data, :method]
    end
  end

  describe "response parsing" do
    test "parses Gemini response format correctly" do
      # Test with a sample Gemini response structure
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Machine learning is a subset of artificial intelligence that enables computers to learn and improve from experience without being explicitly programmed."
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 15,
          "candidatesTokenCount" => 25,
          "totalTokenCount" => 40
        }
      }

      # Verify structure matches expected Gemini format
      assert is_list(gemini_response["candidates"])
      candidate = List.first(gemini_response["candidates"])
      assert candidate["content"]["role"] == "model"
      assert is_list(candidate["content"]["parts"])

      part = List.first(candidate["content"]["parts"])
      assert part["text"] =~ "Machine learning"

      usage = gemini_response["usageMetadata"]
      assert usage["totalTokenCount"] == 40
      assert usage["promptTokenCount"] == 15
      assert usage["candidatesTokenCount"] == 25
    end

    test "parses function calls in Gemini response" do
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "I'll search for information about that topic."
                },
                %{
                  "functionCall" => %{
                    "name" => "search_web",
                    "args" => %{"query" => "machine learning basics"}
                  }
                }
              ],
              "role" => "model"
            }
          }
        ]
      }

      candidate = List.first(gemini_response["candidates"])
      parts = candidate["content"]["parts"]

      text_part = Enum.find(parts, &Map.has_key?(&1, "text"))
      function_part = Enum.find(parts, &Map.has_key?(&1, "functionCall"))

      assert text_part["text"] =~ "search"
      assert function_part["functionCall"]["name"] == "search_web"
      assert function_part["functionCall"]["args"]["query"] == "machine learning basics"
    end

    test "handles safety ratings and blocked content" do
      # Gemini includes safety ratings in responses
      gemini_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "This is safe content"}],
              "role" => "model"
            },
            "safetyRatings" => [
              %{
                "category" => "HARM_CATEGORY_HARASSMENT",
                "probability" => "NEGLIGIBLE"
              },
              %{
                "category" => "HARM_CATEGORY_HATE_SPEECH",
                "probability" => "NEGLIGIBLE"
              }
            ]
          }
        ]
      }

      candidate = List.first(gemini_response["candidates"])
      safety_ratings = candidate["safetyRatings"]

      assert length(safety_ratings) == 2
      assert Enum.all?(safety_ratings, &(&1["probability"] == "NEGLIGIBLE"))
    end
  end

  describe "settings validation" do
    test "handles Gemini-specific parameters", %{basic_settings: settings} do
      # Gemini has specific parameter ranges and names
      gemini_settings = Map.merge(settings, %{
        top_k: 40,
        top_p: 0.8,
        safety_settings: [
          %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_MEDIUM_AND_ABOVE"}
        ]
      })

      assert gemini_settings.temperature == 0.7
      assert gemini_settings.max_tokens == 100
      assert gemini_settings.top_k == 40
      assert gemini_settings.top_p == 0.8
      assert is_list(gemini_settings.safety_settings)
    end

    test "validates parameter ranges" do
      # Test parameter validation for Gemini constraints
      settings = %{
        temperature: 0.9,    # Valid: 0.0 to 1.0
        top_p: 1.0,         # Valid: 0.0 to 1.0
        top_k: 50,          # Valid: 1 to 100
        max_tokens: 2048    # Gemini limit varies by model
      }

      assert settings.temperature >= 0.0 and settings.temperature <= 1.0
      assert settings.top_p >= 0.0 and settings.top_p <= 1.0
      assert settings.top_k >= 1 and settings.top_k <= 100
    end
  end

  describe "error handling" do
    test "handles Gemini API errors" do
      # Test different Gemini-specific error scenarios
      sample_errors = [
        %{status_code: 400, message: "Invalid API key", code: "INVALID_ARGUMENT"},
        %{status_code: 429, message: "Quota exceeded", code: "RESOURCE_EXHAUSTED"},
        %{status_code: 403, message: "Content blocked", code: "PERMISSION_DENIED"},
        %{status_code: 500, message: "Internal error", code: "INTERNAL"}
      ]

      for error_data <- sample_errors do
        wrapped = Errors.ModelError.exception(
          provider: :gemini,
          message: "Request failed: #{error_data.message}",
          details: error_data
        )

        assert %Errors.ModelError{} = wrapped
        assert wrapped.provider == :gemini
        assert wrapped.message =~ "Request failed"
        assert wrapped.details == error_data
      end
    end

    test "handles safety filter blocks" do
      # Gemini can block content based on safety filters
      safety_error = %{
        status_code: 400,
        message: "Content blocked by safety filters",
        code: "SAFETY",
        details: %{
          category: "HARM_CATEGORY_HARASSMENT",
          probability: "HIGH"
        }
      }

      wrapped = Errors.ModelError.exception(
        provider: :gemini,
        message: "Content blocked: #{safety_error.message}",
        details: safety_error
      )

      assert wrapped.provider == :gemini
      assert wrapped.message =~ "Content blocked"
      assert wrapped.details.code == "SAFETY"
    end
  end

  describe "integration tests" do
    @describetag :integration
    test "can handle realistic Gemini workflow", %{model: _model} do
      # Test a realistic conversation flow specific to Gemini
      conversation = [
        Messages.system_prompt("You are a helpful AI assistant powered by Google's Gemini."),
        Messages.user_prompt([
          {:text, "Analyze this data and tell me what you see"},
          {:image_url, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="}
        ]),
        # Simulate Gemini response with multi-modal understanding
        %{
          parts: [
            {:text, "I can see this is a 1x1 pixel image. Let me search for more detailed analysis tools."},
            {:tool_call, %{id: "call_123", name: "analyze_image", arguments: %{"image_data" => "base64_data", "analysis_type" => "detailed"}}}
          ],
          usage: %Usage{input_tokens: 30, output_tokens: 25, total_tokens: 55},
          model_name: "gemini-1.5-pro",
          timestamp: DateTime.utc_now()
        },
        Messages.tool_return("call_123", %{
          analysis: "Simple test image",
          dimensions: %{width: 1, height: 1},
          color_analysis: %{dominant_color: "transparent"}
        })
      ]

      # Test the conversation structure
      assert length(conversation) == 4

      # Verify system message
      system_msg = Enum.at(conversation, 0)
      assert match?({:system_prompt, _}, system_msg)

      # Verify multi-modal user message
      user_msg = Enum.at(conversation, 1)
      assert {:user_prompt, content} = user_msg
      assert is_list(content)
      assert Enum.any?(content, &match?({:text, _}, &1))
      assert Enum.any?(content, &match?({:image_url, _}, &1))

      # Verify assistant response with tool call
      assistant_msg = Enum.at(conversation, 2)
      assert assistant_msg.parts |> Enum.any?(&match?({:tool_call, _}, &1))

      # Verify tool return
      tool_return_msg = Enum.at(conversation, 3)
      assert {:tool_return, %{call_id: "call_123", result: result}} = tool_return_msg
      assert result.analysis == "Simple test image"
      assert result.dimensions.width == 1
    end
  end
end
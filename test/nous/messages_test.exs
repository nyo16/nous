defmodule Nous.MessagesTest do
  use ExUnit.Case, async: true

  alias Nous.Messages

  doctest Messages

  describe "system_prompt/1" do
    test "creates system prompt part" do
      result = Messages.system_prompt("Be helpful")

      assert result == {:system_prompt, "Be helpful"}
    end
  end

  describe "user_prompt/1" do
    test "creates user prompt with text" do
      result = Messages.user_prompt("Hello!")

      assert result == {:user_prompt, "Hello!"}
    end

    test "creates user prompt with content list" do
      content = [
        {:text, "What's in this image?"},
        {:image_url, "https://example.com/image.png"}
      ]

      result = Messages.user_prompt(content)

      assert result == {:user_prompt, content}
    end
  end

  describe "tool_return/2" do
    test "creates tool return part" do
      result = Messages.tool_return("call_123", %{status: "success"})

      assert result ==
               {:tool_return, %{call_id: "call_123", result: %{status: "success"}}}
    end
  end

  describe "extract_text/1" do
    test "extracts and concatenates text parts" do
      parts = [
        {:text, "Hello "},
        {:text, "world!"}
      ]

      result = Messages.extract_text(parts)

      assert result == "Hello world!"
    end

    test "ignores non-text parts" do
      parts = [
        {:text, "Hello"},
        {:tool_call, %{id: "call_1", name: "search", arguments: %{}}},
        {:text, " world"}
      ]

      result = Messages.extract_text(parts)

      assert result == "Hello world"
    end

    test "returns empty string when no text parts" do
      parts = [
        {:tool_call, %{id: "call_1", name: "search", arguments: %{}}}
      ]

      result = Messages.extract_text(parts)

      assert result == ""
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts tool calls from parts" do
      parts = [
        {:text, "Let me search for that"},
        {:tool_call, %{id: "call_1", name: "search", arguments: %{"q" => "elixir"}}},
        {:tool_call, %{id: "call_2", name: "calculate", arguments: %{"x" => 5}}}
      ]

      result = Messages.extract_tool_calls(parts)

      assert length(result) == 2
      assert Enum.at(result, 0).id == "call_1"
      assert Enum.at(result, 1).id == "call_2"
    end

    test "returns empty list when no tool calls" do
      parts = [{:text, "Just text"}]

      result = Messages.extract_tool_calls(parts)

      assert result == []
    end
  end

  describe "to_openai_messages/1" do
    test "converts system prompt" do
      messages = [Messages.system_prompt("Be helpful")]

      [result] = Messages.to_openai_messages(messages)

      assert result.role == "system"
      assert result.content == "Be helpful"
    end

    test "converts user prompt with text" do
      messages = [Messages.user_prompt("Hello!")]

      [result] = Messages.to_openai_messages(messages)

      assert result.role == "user"
      assert result.content == "Hello!"
    end

    test "converts user prompt with multi-modal content" do
      messages = [
        Messages.user_prompt([
          {:text, "What's in this image?"},
          {:image_url, "https://example.com/image.png"}
        ])
      ]

      [result] = Messages.to_openai_messages(messages)

      assert result.role == "user"
      assert is_list(result.content)
      assert length(result.content) == 2
    end

    test "converts tool return" do
      messages = [Messages.tool_return("call_123", %{result: "success"})]

      [result] = Messages.to_openai_messages(messages)

      assert result.role == "tool"
      assert result.tool_call_id == "call_123"
      assert is_binary(result.content)
    end

    test "converts previous assistant response with text only" do
      messages = [
        %{
          parts: [{:text, "Hello!"}],
          usage: %Nous.Usage{},
          model_name: "gpt-4",
          timestamp: DateTime.utc_now()
        }
      ]

      [result] = Messages.to_openai_messages(messages)

      assert result.role == "assistant"
      assert result.content == "Hello!"
    end

    test "converts previous assistant response with tool calls" do
      messages = [
        %{
          parts: [
            {:text, "Let me search"},
            {:tool_call, %{id: "call_1", name: "search", arguments: %{"q" => "test"}}}
          ],
          usage: %Nous.Usage{},
          model_name: "gpt-4",
          timestamp: DateTime.utc_now()
        }
      ]

      [result] = Messages.to_openai_messages(messages)

      assert result["role"] == "assistant"
      assert result["content"] == "Let me search"
      assert is_list(result["tool_calls"])
      assert length(result["tool_calls"]) == 1
    end

    test "converts mixed message sequence" do
      messages = [
        Messages.system_prompt("Be helpful"),
        Messages.user_prompt("Hello"),
        %{
          parts: [{:text, "Hi there!"}],
          usage: %Nous.Usage{},
          model_name: "gpt-4",
          timestamp: DateTime.utc_now()
        }
      ]

      results = Messages.to_openai_messages(messages)

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

      assert result.model_name == "gpt-4"
      assert result.parts == [{:text, "Hello! How can I help?"}]
      assert result.usage.total_tokens == 15
      assert %DateTime{} = result.timestamp
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

      assert length(result.parts) == 2
      assert {:text, "Let me search"} in result.parts

      tool_call = Enum.find(result.parts, &match?({:tool_call, _}, &1))
      assert {:tool_call, call_data} = tool_call
      assert call_data.id == "call_abc123"
      assert call_data.name == "search"
      assert call_data.arguments == %{"query" => "elixir"}
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

      # Should only have tool call, no text
      assert length(result.parts) == 1
      assert match?({:tool_call, _}, List.first(result.parts))
    end
  end
end

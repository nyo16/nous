defmodule Nous.MessagesGeminiTest do
  use ExUnit.Case, async: true
  alias Nous.Messages.Gemini
  alias Nous.Message
  alias Nous.Usage
  alias Nous.StreamNormalizer.Gemini, as: GeminiStream

  describe "from_response/1" do
    test "extracts thought block into reasoning_content" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Thinking process", "thought" => true},
                %{"text" => "Final answer"}
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "Final answer"
      assert msg.reasoning_content == "Thinking process"
    end

    test "parses a real Gemini API response" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Elixir is a functional programming language.",
                  "thoughtSignature" => "EjQKMgG+Pvb7FjrlsiLUH2M4hqMc3WbSE9Q3Pqw+"
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0
          }
        ],
        "modelVersion" => "gemini-3.1-flash-lite-preview",
        "responseId" => "S4KoabjaAtTskdUPh_rm-AM",
        "usageMetadata" => %{
          "candidatesTokenCount" => 740,
          "promptTokenCount" => 6,
          "promptTokensDetails" => [%{"modality" => "TEXT", "tokenCount" => 6}],
          "totalTokenCount" => 746
        }
      }

      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "Elixir is a functional programming language."
      # thoughtSignature is not thinking content - no reasoning present
      assert msg.reasoning_content == nil or msg.reasoning_content == ""
    end

    test "extracts modelVersion into metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hello"}]}}
        ],
        "modelVersion" => "gemini-3.1-flash-lite-preview"
      }

      msg = Gemini.from_response(response)
      assert msg.metadata.model_name == "gemini-3.1-flash-lite-preview"
    end

    test "falls back to default model_name when modelVersion is absent" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hello"}]}}
        ]
      }

      msg = Gemini.from_response(response)
      assert msg.metadata.model_name == "gemini-model"
    end

    test "parses usage metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hi"}]}}
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      msg = Gemini.from_response(response)
      assert %Usage{} = msg.metadata.usage
      assert msg.metadata.usage.input_tokens == 10
      assert msg.metadata.usage.output_tokens == 20
      assert msg.metadata.usage.total_tokens == 30
    end

    test "handles missing usage metadata" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Hi"}]}}
        ]
      }

      msg = Gemini.from_response(response)
      assert %Usage{} = msg.metadata.usage
      assert msg.metadata.usage.input_tokens == 0
      assert msg.metadata.usage.output_tokens == 0
    end

    test "parses function calls" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "get_weather",
                    "args" => %{"location" => "Paris"}
                  }
                }
              ]
            }
          }
        ]
      }

      msg = Gemini.from_response(response)
      assert length(msg.tool_calls) == 1
      [call] = msg.tool_calls
      assert call["name"] == "get_weather"
      assert call["arguments"] == %{"location" => "Paris"}
      assert String.starts_with?(call["id"], "gemini_")
    end

    test "handles empty candidates" do
      response = %{"candidates" => []}
      msg = Gemini.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "" or msg.content == nil
    end
  end

  describe "to_format/1" do
    test "includes reasoning_content as a thought part" do
      msg = Message.new!(%{role: :assistant, content: "Answer", reasoning_content: "Thoughts"})

      {_sys, formatted} = Gemini.to_format([msg])
      gemini_msg = List.first(formatted)

      assert gemini_msg["role"] == "model"

      parts = gemini_msg["parts"]

      assert Enum.any?(parts, fn part ->
               part["thought"] == true and part["text"] == "Thoughts"
             end)

      assert Enum.any?(parts, fn part -> part["text"] == "Answer" end)
    end

    test "extracts system messages into system prompt" do
      messages = [
        Message.new!(%{role: :system, content: "Be helpful"}),
        Message.new!(%{role: :user, content: "Hello"})
      ]

      {system_prompt, contents} = Gemini.to_format(messages)
      assert system_prompt == "Be helpful"
      assert length(contents) == 1
      assert hd(contents)["role"] == "user"
    end

    test "returns nil system prompt when no system messages" do
      messages = [Message.new!(%{role: :user, content: "Hello"})]

      {system_prompt, _contents} = Gemini.to_format(messages)
      assert system_prompt == nil
    end

    test "converts user messages" do
      messages = [Message.new!(%{role: :user, content: "What is Elixir?"})]

      {_sys, [msg]} = Gemini.to_format(messages)
      assert msg == %{"role" => "user", "parts" => [%{"text" => "What is Elixir?"}]}
    end

    test "converts assistant messages to model role" do
      messages = [Message.new!(%{role: :assistant, content: "Hello!"})]

      {_sys, [msg]} = Gemini.to_format(messages)
      assert msg["role"] == "model"
      assert Enum.any?(msg["parts"], &(&1["text"] == "Hello!"))
    end

    test "converts tool result messages to functionResponse" do
      messages = [
        Message.new!(%{
          role: :tool,
          content: ~s({"temp": 22}),
          tool_call_id: "get_weather"
        })
      ]

      {_sys, [msg]} = Gemini.to_format(messages)
      assert msg["role"] == "user"
      [part] = msg["parts"]
      assert part["functionResponse"]["name"] == "get_weather"
      assert part["functionResponse"]["response"] == %{"temp" => 22}
    end

    test "wraps plain text tool result" do
      messages = [
        Message.new!(%{
          role: :tool,
          content: "some plain result",
          tool_call_id: "my_tool"
        })
      ]

      {_sys, [msg]} = Gemini.to_format(messages)
      [part] = msg["parts"]
      assert part["functionResponse"]["response"] == %{"result" => "some plain result"}
    end

    test "concatenates multiple system messages" do
      messages = [
        Message.new!(%{role: :system, content: "First instruction"}),
        Message.new!(%{role: :system, content: "Second instruction"}),
        Message.new!(%{role: :user, content: "Hi"})
      ]

      {system_prompt, contents} = Gemini.to_format(messages)
      assert system_prompt == "First instruction\n\nSecond instruction"
      assert length(contents) == 1
    end
  end

  describe "from_messages/1" do
    test "converts user messages" do
      gemini_msgs = [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert msg.role == :user
      assert msg.content == "Hello"
    end

    test "converts model messages to assistant role" do
      gemini_msgs = [%{"role" => "model", "parts" => [%{"text" => "Hi there"}]}]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert msg.role == :assistant
      assert msg.content == "Hi there"
    end

    test "separates thought parts into reasoning_content" do
      gemini_msgs = [
        %{
          "role" => "model",
          "parts" => [
            %{"text" => "Let me think...", "thought" => true},
            %{"text" => "The answer is 42"}
          ]
        }
      ]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert msg.content == "The answer is 42"
      assert msg.reasoning_content == "Let me think..."
    end

    test "parses function calls from messages" do
      gemini_msgs = [
        %{
          "role" => "model",
          "parts" => [
            %{"functionCall" => %{"name" => "search", "args" => %{"q" => "elixir"}}}
          ]
        }
      ]

      [msg] = Gemini.from_messages(gemini_msgs)
      assert length(msg.tool_calls) == 1
      [call] = msg.tool_calls
      assert call["name"] == "search"
      assert call["arguments"] == %{"q" => "elixir"}
    end
  end

  describe "StreamNormalizer" do
    test "emits thinking delta when thought is true" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"text" => "Thinking step", "thought" => true}
              ]
            }
          }
        ]
      }

      events = GeminiStream.normalize_chunk(chunk)
      assert [{:thinking_delta, "Thinking step"}] = events
    end
  end
end

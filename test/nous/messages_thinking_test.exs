defmodule Nous.MessagesThinkingTest do
  use ExUnit.Case, async: true
  alias Nous.{Message, Messages.OpenAI}
  alias Nous.StreamNormalizer.OpenAI, as: StreamNormalizer

  describe "OpenAI formats reasoning" do
    test "from_response extracts reasoning_content" do
      response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "Final answer",
              "reasoning_content" => "Let me think..."
            }
          }
        ],
        "model" => "deepseek-r1"
      }

      msg = OpenAI.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "Final answer"
      assert msg.reasoning_content == "Let me think..."
    end

    test "message_to_openai includes reasoning_content" do
      msg = Message.new!(%{role: :assistant, content: "Answer", reasoning_content: "Thoughts"})

      formatted = OpenAI.to_format([msg]) |> List.first()

      assert formatted["role"] == "assistant"
      assert formatted["content"] == "Answer"
      assert formatted["reasoning_content"] == "Thoughts"
    end
  end

  describe "StreamNormalizer handles reasoning" do
    test "extracts reasoning_content from string delta map" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"reasoning_content" => "I'm thinking"}
          }
        ]
      }

      events = StreamNormalizer.normalize_chunk(chunk)
      assert [{:thinking_delta, "I'm thinking"}] = events
    end

    test "extracts reasoning from atom delta map" do
      chunk = %{
        choices: [
          %{
            delta: %{reasoning: "vLLM style"}
          }
        ]
      }

      events = StreamNormalizer.normalize_chunk(chunk)
      assert [{:thinking_delta, "vLLM style"}] = events
    end

    test "extracts both from complete response" do
      chunk = %{
        "choices" => [
          %{
            "message" => %{
              "content" => "Hello",
              "reasoning_content" => "Aha!"
            },
            "finish_reason" => "stop"
          }
        ]
      }

      events = StreamNormalizer.convert_complete_response(chunk)

      assert [
               {:thinking_delta, "Aha!"},
               {:text_delta, "Hello"},
               {:finish, "stop"}
             ] = events
    end
  end
end

defmodule Nous.MessagesGeminiTest do
  use ExUnit.Case, async: true
  alias Nous.Messages.Gemini
  alias Nous.Message
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
  end
  
  describe "to_format/1" do
    test "includes reasoning_content as a thought part" do
      msg = Message.new!(%{role: :assistant, content: "Answer", reasoning_content: "Thoughts"})
      
      {_sys, formatted} = Gemini.to_format([msg])
      gemini_msg = List.first(formatted)
      
      assert gemini_msg["role"] == "model"
      
      parts = gemini_msg["parts"]
      assert Enum.any?(parts, fn part -> part["thought"] == true and part["text"] == "Thoughts" end)
      assert Enum.any?(parts, fn part -> part["text"] == "Answer" end)
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

defmodule Nous.MessagesAnthropicTest do
  use ExUnit.Case, async: true
  alias Nous.Messages.Anthropic
  alias Nous.Message

  describe "from_response/1" do
    test "extracts thinking block into reasoning_content" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "This is my reasoning", "signature" => "sig123"},
          %{"type" => "text", "text" => "Final answer"}
        ],
        "model" => "claude-3-7-sonnet"
      }

      msg = Anthropic.from_response(response)
      assert msg.role == :assistant
      assert msg.content == "Final answer"
      assert msg.reasoning_content == "This is my reasoning"
    end
  end

  describe "to_format/1" do
    test "includes reasoning_content as a thinking block in assistant messages" do
      msg = Message.new!(%{role: :assistant, content: "Answer", reasoning_content: "Thoughts"})

      {_sys, formatted} = Anthropic.to_format([msg])
      anthropic_msg = List.first(formatted)

      assert anthropic_msg["role"] == "assistant"

      content = anthropic_msg["content"]

      assert Enum.any?(content, fn part ->
               part["type"] == "thinking" and part["thinking"] == "Thoughts"
             end)

      assert Enum.any?(content, fn part -> part["type"] == "text" and part["text"] == "Answer" end)
    end
  end
end

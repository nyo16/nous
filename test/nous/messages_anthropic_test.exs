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

  describe "multimodal message formatting" do
    alias Nous.Message.ContentPart

    test "formats user message with data URL image from metadata" do
      msg =
        Message.user([
          ContentPart.text("Describe this image"),
          ContentPart.image_url("data:image/jpeg;base64,/9j/4AAQSkZJRg==")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      assert formatted["role"] == "user"

      [text_part, image_part] = formatted["content"]
      assert text_part == %{"type" => "text", "text" => "Describe this image"}
      assert image_part["type"] == "image"
      assert image_part["source"]["type"] == "base64"
      assert image_part["source"]["media_type"] == "image/jpeg"
      assert image_part["source"]["data"] == "/9j/4AAQSkZJRg=="
    end

    test "extracts correct media_type from PNG data URL" do
      msg =
        Message.user([
          ContentPart.text("What is this?"),
          ContentPart.image_url("data:image/png;base64,iVBORw0KGgo=")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image"))

      assert image_part["source"]["media_type"] == "image/png"
      assert image_part["source"]["data"] == "iVBORw0KGgo="
    end

    test "formats HTTP URL as url source type" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image_url("https://example.com/photo.jpg")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image"))

      assert image_part["source"]["type"] == "url"
      assert image_part["source"]["url"] == "https://example.com/photo.jpg"
    end

    test "formats :image content part with explicit media_type" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image("raw_base64_data", media_type: "image/webp")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image"))

      assert image_part["source"]["type"] == "base64"
      assert image_part["source"]["media_type"] == "image/webp"
      assert image_part["source"]["data"] == "raw_base64_data"
    end

    test "does not duplicate thinking block in assistant messages" do
      msg = Message.new!(%{role: :assistant, content: "Answer", reasoning_content: "Thoughts"})

      {_sys, [formatted]} = Anthropic.to_format([msg])
      thinking_parts = Enum.filter(formatted["content"], &(&1["type"] == "thinking"))

      assert length(thinking_parts) == 1
      assert hd(thinking_parts)["thinking"] == "Thoughts"
    end

    test "formats multiple images in one message" do
      msg =
        Message.user([
          ContentPart.text("Compare these images"),
          ContentPart.image_url("data:image/jpeg;base64,abc123"),
          ContentPart.image_url("data:image/png;base64,def456")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      image_parts = Enum.filter(formatted["content"], &(&1["type"] == "image"))

      assert length(image_parts) == 2
      assert Enum.at(image_parts, 0)["source"]["media_type"] == "image/jpeg"
      assert Enum.at(image_parts, 1)["source"]["media_type"] == "image/png"
    end
  end
end

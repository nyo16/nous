defmodule Nous.MessagesOpenAITest do
  use ExUnit.Case, async: true
  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Messages.OpenAI

  describe "to_format/1 request marshalling" do
    test "system and user text messages map to role/content maps" do
      assert [
               %{"role" => "system", "content" => "Be helpful"},
               %{"role" => "user", "content" => "Hello"}
             ] = OpenAI.to_format([Message.system("Be helpful"), Message.user("Hello")])
    end

    test "a plain assistant message has content and no tool_calls key" do
      [msg] = OpenAI.to_format([Message.assistant("Hi there")])
      assert msg["role"] == "assistant"
      assert msg["content"] == "Hi there"
      refute Map.has_key?(msg, "tool_calls")
    end

    test "an assistant message with tool_calls emits OpenAI function-call shape" do
      assistant =
        Message.assistant("",
          tool_calls: [
            %{"id" => "call_1", "name" => "get_weather", "arguments" => %{"city" => "Paris"}}
          ]
        )

      [msg] = OpenAI.to_format([assistant])

      assert msg["role"] == "assistant"
      assert [tc] = msg["tool_calls"]
      assert tc["id"] == "call_1"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "get_weather"
      # arguments are JSON-encoded on the wire, not a raw map.
      assert tc["function"]["arguments"] == ~s({"city":"Paris"})
    end

    test "a tool result message maps to role: tool with tool_call_id" do
      [msg] = OpenAI.to_format([Message.tool("call_1", "sunny, 22C", name: "get_weather")])

      assert msg["role"] == "tool"
      assert msg["content"] == "sunny, 22C"
      assert msg["tool_call_id"] == "call_1"
    end

    test "a multimodal user message maps content to a parts array (text + image_url)" do
      parts = [
        ContentPart.text("describe this"),
        ContentPart.image_url("https://example.com/cat.png")
      ]

      [msg] = OpenAI.to_format([Message.user(parts)])

      assert msg["role"] == "user"
      assert is_list(msg["content"])

      assert %{"type" => "text", "text" => "describe this"} in msg["content"]

      assert Enum.any?(msg["content"], fn
               %{"type" => "image_url", "image_url" => %{"url" => url}} ->
                 url == "https://example.com/cat.png"

               _ ->
                 false
             end)
    end

    test "a full conversation round-trips order: system, user, assistant+tool_call, tool" do
      conversation = [
        Message.system("sys"),
        Message.user("q"),
        Message.assistant("", tool_calls: [%{"id" => "c1", "name" => "f", "arguments" => %{}}]),
        Message.tool("c1", "result", name: "f")
      ]

      roles = OpenAI.to_format(conversation) |> Enum.map(& &1["role"])
      assert roles == ["system", "user", "assistant", "tool"]
    end
  end

  describe "decode_arguments/1" do
    test "returns {:ok, map} for valid JSON object" do
      assert {:ok, %{"city" => "Paris"}} = OpenAI.decode_arguments(~s({"city":"Paris"}))
    end

    test "returns {:ok, %{}} for nil or empty string" do
      assert {:ok, %{}} == OpenAI.decode_arguments(nil)
      assert {:ok, %{}} == OpenAI.decode_arguments("")
    end

    test "returns {:error, {:invalid_json, raw}} for malformed JSON" do
      assert {:error, {:invalid_json, "{not json"}} == OpenAI.decode_arguments("{not json")
    end

    test "returns {:error, {:invalid_json, raw}} for JSON that isn't an object" do
      assert {:error, {:invalid_json, "[1,2,3]"}} == OpenAI.decode_arguments("[1,2,3]")
    end
  end

  describe "from_response with malformed tool_call arguments" do
    test "tags the tool_call with _invalid_arguments instead of injecting fake args" do
      response = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => "{not json"
                  }
                }
              ]
            }
          }
        ],
        "model" => "gpt-4"
      }

      msg = OpenAI.from_response(response)
      [call] = msg.tool_calls

      assert call["name"] == "get_weather"
      # arguments should NOT contain the synthetic "error"/"raw" map that
      # would have been passed straight to the tool function.
      refute Map.has_key?(call["arguments"], "error")
      assert call["arguments"] == %{}
      assert call["_invalid_arguments"] == "{not json"
    end

    test "does not crash on a tool_call missing the function wrapper" do
      # Regression: Map.get(nil, "name") raised BadMapError, aborting the whole
      # response parse. A non-conformant OpenAI-compatible backend can emit this.
      response = %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "tool_calls" => [%{"id" => "call_x"}]}}
        ],
        "model" => "gpt-4"
      }

      msg = OpenAI.from_response(response)
      [call] = msg.tool_calls
      assert call["id"] == "call_x"
      assert call["arguments"] == %{}
    end
  end
end

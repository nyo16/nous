defmodule Nous.MessagesOpenAITest do
  use ExUnit.Case, async: true
  alias Nous.Messages.OpenAI

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

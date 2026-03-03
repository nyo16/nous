defmodule Nous.StreamNormalizer.OpenAIComprehensiveTest do
  use ExUnit.Case, async: true
  alias Nous.StreamNormalizer.OpenAI, as: StreamNormalizer

  describe "vLLM specific handling" do
    test "extracts reasoning content from 'reasoning' field" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"reasoning" => "Let me calculate"}
          }
        ]
      }

      events = StreamNormalizer.normalize_chunk(chunk)
      assert [{:thinking_delta, "Let me calculate"}] = events
    end
  end

  describe "SGLang/DeepSeek specific handling" do
    test "extracts reasoning content from 'reasoning_content' field" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"reasoning_content" => "Step 1"}
          }
        ]
      }

      events = StreamNormalizer.normalize_chunk(chunk)
      assert [{:thinking_delta, "Step 1"}] = events
    end
  end

  describe "Complete response with reasoning fallback" do
    test "handles reasoning from message.reasoning" do
      chunk = %{
        "choices" => [
          %{
            "message" => %{"content" => "4", "reasoning" => "2+2=4"},
            "finish_reason" => "stop"
          }
        ]
      }

      events = StreamNormalizer.convert_complete_response(chunk)

      assert [
               {:thinking_delta, "2+2=4"},
               {:text_delta, "4"},
               {:finish, "stop"}
             ] = events
    end

    test "handles reasoning from message.reasoning_content" do
      chunk = %{
        "choices" => [
          %{
            "message" => %{"content" => "4", "reasoning_content" => "2+2=4"},
            "finish_reason" => "stop"
          }
        ]
      }

      events = StreamNormalizer.convert_complete_response(chunk)

      assert [
               {:thinking_delta, "2+2=4"},
               {:text_delta, "4"},
               {:finish, "stop"}
             ] = events
    end
  end
end

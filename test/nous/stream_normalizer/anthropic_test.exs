defmodule Nous.StreamNormalizer.AnthropicTest do
  use ExUnit.Case, async: true

  alias Nous.StreamNormalizer.Anthropic

  describe "normalize_chunk/1 - text deltas" do
    test "content_block_delta with text_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      }

      assert [{:text_delta, "Hello"}] = Anthropic.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - thinking deltas" do
    test "content_block_delta with thinking_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."}
      }

      assert [{:thinking_delta, "Let me think..."}] = Anthropic.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - tool call deltas" do
    test "content_block_delta with input_json_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"query\":"}
      }

      assert [{:tool_call_delta, "{\"query\":"}] = Anthropic.normalize_chunk(chunk)
    end

    test "content_block_start with tool_use block" do
      chunk = %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_01ABC",
          "name" => "search"
        }
      }

      assert [{:tool_call_delta, %{"id" => "toolu_01ABC", "name" => "search"}}] =
               Anthropic.normalize_chunk(chunk)
    end

    test "content_block_start with text block returns unknown" do
      chunk = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }

      assert [{:unknown, _}] = Anthropic.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - finish" do
    test "message_delta with stop_reason" do
      chunk = %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 42}
      }

      assert [{:finish, "end_turn"}] = Anthropic.normalize_chunk(chunk)
    end

    test "message_delta with tool_use stop_reason" do
      chunk = %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 10}
      }

      assert [{:finish, "tool_use"}] = Anthropic.normalize_chunk(chunk)
    end

    test "message_delta without stop_reason returns unknown" do
      chunk = %{
        "type" => "message_delta",
        "delta" => %{},
        "usage" => %{"output_tokens" => 0}
      }

      assert [{:unknown, _}] = Anthropic.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - stream_done" do
    test "stream_done tuple produces finish" do
      assert [{:finish, "stop"}] = Anthropic.normalize_chunk({:stream_done, "stop"})
    end

    test "stream_done with custom reason" do
      assert [{:finish, "complete"}] = Anthropic.normalize_chunk({:stream_done, "complete"})
    end
  end

  describe "normalize_chunk/1 - errors" do
    test "error event" do
      chunk = %{
        "type" => "error",
        "error" => %{
          "type" => "overloaded_error",
          "message" => "Overloaded"
        }
      }

      assert [{:error, "Overloaded"}] = Anthropic.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - unknown events" do
    test "message_start returns unknown" do
      chunk = %{
        "type" => "message_start",
        "message" => %{"id" => "msg_01ABC", "role" => "assistant"}
      }

      assert [{:unknown, _}] = Anthropic.normalize_chunk(chunk)
    end

    test "message_stop returns unknown" do
      chunk = %{"type" => "message_stop"}

      assert [{:unknown, _}] = Anthropic.normalize_chunk(chunk)
    end

    test "content_block_stop returns unknown" do
      chunk = %{"type" => "content_block_stop", "index" => 0}

      assert [{:unknown, _}] = Anthropic.normalize_chunk(chunk)
    end

    test "unrecognized delta type returns unknown" do
      chunk = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "unknown_type", "data" => "foo"}
      }

      assert [{:unknown, _}] = Anthropic.normalize_chunk(chunk)
    end
  end

  describe "complete_response?/1" do
    test "true for full message response" do
      chunk = %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "stop_reason" => "end_turn"
      }

      assert Anthropic.complete_response?(chunk)
    end

    test "false for streaming delta" do
      chunk = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "Hi"}
      }

      refute Anthropic.complete_response?(chunk)
    end

    test "false for non-map" do
      refute Anthropic.complete_response?({:stream_done, "stop"})
    end
  end

  describe "convert_complete_response/1" do
    test "converts text response" do
      chunk = %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello world"}],
        "stop_reason" => "end_turn"
      }

      assert [{:text_delta, "Hello world"}, {:finish, "end_turn"}] =
               Anthropic.convert_complete_response(chunk)
    end

    test "converts thinking response" do
      chunk = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me reason..."},
          %{"type" => "text", "text" => "The answer is 42"}
        ],
        "stop_reason" => "end_turn"
      }

      assert [
               {:thinking_delta, "Let me reason..."},
               {:text_delta, "The answer is 42"},
               {:finish, "end_turn"}
             ] = Anthropic.convert_complete_response(chunk)
    end

    test "converts tool use response" do
      chunk = %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_01ABC",
            "name" => "search",
            "input" => %{"query" => "weather"}
          }
        ],
        "stop_reason" => "tool_use"
      }

      assert [
               {:tool_call_delta,
                %{"id" => "toolu_01ABC", "name" => "search", "input" => %{"query" => "weather"}}},
               {:finish, "tool_use"}
             ] = Anthropic.convert_complete_response(chunk)
    end

    test "defaults stop_reason to end_turn" do
      chunk = %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hi"}]
      }

      assert [{:text_delta, "Hi"}, {:finish, "end_turn"}] =
               Anthropic.convert_complete_response(chunk)
    end

    test "returns unknown for invalid chunk" do
      assert [{:unknown, %{}}] = Anthropic.convert_complete_response(%{})
    end
  end
end

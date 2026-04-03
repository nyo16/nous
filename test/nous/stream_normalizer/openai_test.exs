defmodule Nous.StreamNormalizer.OpenAITest do
  @moduledoc """
  Comprehensive tests for the OpenAI stream normalizer.

  Supplements openai_comprehensive_test.exs with full coverage of
  atom-keyed, string-keyed, edge cases, and complete response handling.
  """

  use ExUnit.Case, async: true

  alias Nous.StreamNormalizer.OpenAI, as: Normalizer

  describe "normalize_chunk/1 - string-keyed text deltas" do
    test "extracts content from string-keyed delta" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "hello"}}]}

      assert [{:text_delta, "hello"}] = Normalizer.normalize_chunk(chunk)
    end

    test "ignores empty string content" do
      chunk = %{"choices" => [%{"delta" => %{"content" => ""}}]}

      assert [{:unknown, _}] = Normalizer.normalize_chunk(chunk)
    end

    test "ignores nil content" do
      chunk = %{"choices" => [%{"delta" => %{"content" => nil}}]}

      assert [{:unknown, _}] = Normalizer.normalize_chunk(chunk)
    end

    test "handles delta with no content key" do
      chunk = %{"choices" => [%{"delta" => %{}}]}

      assert [{:unknown, _}] = Normalizer.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - atom-keyed text deltas" do
    test "extracts content from atom-keyed delta" do
      chunk = %{choices: [%{delta: %{content: "world"}}]}

      assert [{:text_delta, "world"}] = Normalizer.normalize_chunk(chunk)
    end

    test "extracts finish_reason from atom-keyed choice" do
      chunk = %{choices: [%{delta: %{}, finish_reason: "stop"}]}

      assert [{:finish, "stop"}] = Normalizer.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - finish reasons" do
    test "extracts finish_reason 'stop'" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}

      assert [{:finish, "stop"}] = Normalizer.normalize_chunk(chunk)
    end

    test "extracts finish_reason 'length'" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "length"}]}

      assert [{:finish, "length"}] = Normalizer.normalize_chunk(chunk)
    end

    test "extracts finish_reason 'tool_calls'" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}

      assert [{:finish, "tool_calls"}] = Normalizer.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - stream_done" do
    test "converts {:stream_done, reason} to {:finish, reason}" do
      assert [{:finish, "stop"}] = Normalizer.normalize_chunk({:stream_done, "stop"})
    end

    test "converts {:stream_done, arbitrary} to {:finish, arbitrary}" do
      assert [{:finish, "custom_reason"}] =
               Normalizer.normalize_chunk({:stream_done, "custom_reason"})
    end
  end

  describe "normalize_chunk/1 - tool calls" do
    test "extracts tool_calls from string-keyed delta" do
      calls = [%{"id" => "call_1", "function" => %{"name" => "get_weather"}}]
      chunk = %{"choices" => [%{"delta" => %{"tool_calls" => calls}}]}

      assert [{:tool_call_delta, ^calls}] = Normalizer.normalize_chunk(chunk)
    end

    test "extracts tool_calls from atom-keyed delta" do
      calls = [%{id: "call_1", function: %{name: "get_weather"}}]
      chunk = %{choices: [%{delta: %{tool_calls: calls}}]}

      assert [{:tool_call_delta, ^calls}] = Normalizer.normalize_chunk(chunk)
    end
  end

  describe "normalize_chunk/1 - unknown chunks" do
    test "returns {:unknown, ...} for empty choices" do
      chunk = %{"choices" => []}

      assert [{:unknown, _}] = Normalizer.normalize_chunk(chunk)
    end

    test "returns {:unknown, ...} for no choices key" do
      chunk = %{"id" => "some_id", "object" => "chat.completion.chunk"}

      assert [{:unknown, _}] = Normalizer.normalize_chunk(chunk)
    end

    test "returns {:unknown, ...} for delta with only empty fields" do
      chunk = %{"choices" => [%{"delta" => %{"content" => nil, "tool_calls" => nil}}]}

      assert [{:unknown, _}] = Normalizer.normalize_chunk(chunk)
    end
  end

  describe "complete_response?/1" do
    test "true when message key exists (string-keyed)" do
      chunk = %{"choices" => [%{"message" => %{"content" => "hello"}}]}

      assert Normalizer.complete_response?(chunk)
    end

    test "true when message key exists (atom-keyed)" do
      chunk = %{choices: [%{message: %{content: "hello"}}]}

      assert Normalizer.complete_response?(chunk)
    end

    test "false when only delta key exists" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "hello"}}]}

      refute Normalizer.complete_response?(chunk)
    end

    test "false for empty choices" do
      chunk = %{"choices" => []}

      refute Normalizer.complete_response?(chunk)
    end

    test "false for no choices" do
      chunk = %{"other" => "data"}

      refute Normalizer.complete_response?(chunk)
    end
  end

  describe "convert_complete_response/1" do
    test "converts message content to text_delta + finish" do
      chunk = %{
        "choices" => [
          %{"message" => %{"content" => "Hello world"}, "finish_reason" => "stop"}
        ]
      }

      events = Normalizer.convert_complete_response(chunk)

      assert [{:text_delta, "Hello world"}, {:finish, "stop"}] = events
    end

    test "handles missing finish_reason (defaults to 'stop')" do
      chunk = %{"choices" => [%{"message" => %{"content" => "hi"}}]}

      events = Normalizer.convert_complete_response(chunk)

      assert [{:text_delta, "hi"}, {:finish, "stop"}] = events
    end

    test "handles empty content" do
      chunk = %{"choices" => [%{"message" => %{"content" => ""}, "finish_reason" => "stop"}]}

      events = Normalizer.convert_complete_response(chunk)

      # Only finish, no text_delta for empty content
      assert [{:finish, "stop"}] = events
    end

    test "includes reasoning as thinking_delta" do
      chunk = %{
        "choices" => [
          %{
            "message" => %{"content" => "4", "reasoning" => "2+2=4"},
            "finish_reason" => "stop"
          }
        ]
      }

      events = Normalizer.convert_complete_response(chunk)

      assert [{:thinking_delta, "2+2=4"}, {:text_delta, "4"}, {:finish, "stop"}] = events
    end

    test "returns {:unknown, ...} for empty choices" do
      chunk = %{"choices" => []}

      events = Normalizer.convert_complete_response(chunk)

      assert [{:unknown, _}] = events
    end
  end

  describe "normalize_chunk/1 - reasoning priority" do
    test "reasoning takes priority over content when both present in delta" do
      chunk = %{
        "choices" => [
          %{"delta" => %{"reasoning" => "thinking...", "content" => "answer"}}
        ]
      }

      # Reasoning has priority in the cond chain
      assert [{:thinking_delta, "thinking..."}] = Normalizer.normalize_chunk(chunk)
    end

    test "content emitted when no reasoning" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "just text"}}]}

      assert [{:text_delta, "just text"}] = Normalizer.normalize_chunk(chunk)
    end
  end
end

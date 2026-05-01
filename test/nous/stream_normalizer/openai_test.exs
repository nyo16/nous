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

  describe "normalize_chunk/1 - multi-event chunks" do
    test "emits both reasoning and content when present in same delta" do
      # Some providers (e.g. vLLM/DeepSeek) interleave thinking and content
      # in a single chunk during the transition. Both must be emitted.
      chunk = %{
        "choices" => [
          %{"delta" => %{"reasoning" => "thinking...", "content" => "answer"}}
        ]
      }

      assert [{:thinking_delta, "thinking..."}, {:text_delta, "answer"}] =
               Normalizer.normalize_chunk(chunk)
    end

    test "content emitted when no reasoning" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "just text"}}]}

      assert [{:text_delta, "just text"}] = Normalizer.normalize_chunk(chunk)
    end

    test "emits tool_call_delta and finish in the same chunk" do
      # OpenAI sends the final tool_calls delta together with finish_reason.
      # Both must be emitted; previously finish_reason was silently dropped
      # (the cond chain returned only the tool_call event).
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [%{"id" => "call_1", "function" => %{"name" => "x"}}]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      events = Normalizer.normalize_chunk(chunk)
      assert [{:tool_call_delta, [_]}, {:finish, "tool_calls"}] = events
    end

    test "complete_response emits tool_calls before finish" do
      # Non-streaming responses (LM Studio / vLLM / Ollama / llamacpp when
      # stream:true degenerates) carry tool_calls in `message.tool_calls`.
      # Previously these were silently dropped and finish_reason "stop" was
      # returned instead of "tool_calls".
      chunk = %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [%{"id" => "call_1", "function" => %{"name" => "x"}}]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      assert [{:tool_call_delta, [_]}, {:finish, "tool_calls"}] =
               Normalizer.convert_complete_response(chunk)
    end
  end

  describe "normalize_chunk/1 - usage events" do
    test "final usage-only chunk emits {:usage, %Usage{}}" do
      chunk = %{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15
        }
      }

      assert [
               {:usage,
                %Nous.Usage{
                  input_tokens: 10,
                  output_tokens: 5,
                  total_tokens: 15
                }}
             ] = Normalizer.normalize_chunk(chunk)
    end

    test "delta chunk with text plus usage emits both events" do
      chunk = %{
        "choices" => [%{"delta" => %{"content" => "hi"}, "finish_reason" => nil}],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      assert [{:text_delta, "hi"}, {:usage, %Nous.Usage{total_tokens: 2}}] =
               Normalizer.normalize_chunk(chunk)
    end

    test "missing usage produces no usage event (back-compat)" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "hi"}}]}

      assert [{:text_delta, "hi"}] = Normalizer.normalize_chunk(chunk)
    end
  end
end

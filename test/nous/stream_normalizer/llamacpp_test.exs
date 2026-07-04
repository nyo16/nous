defmodule Nous.StreamNormalizer.LlamaCppTest do
  use ExUnit.Case, async: true

  alias Nous.StreamNormalizer.LlamaCpp

  describe "normalize_chunk/1 — streaming deltas" do
    test "content delta becomes text_delta" do
      chunk = %{choices: [%{delta: %{content: "hello"}, finish_reason: nil}]}
      assert LlamaCpp.normalize_chunk(chunk) == [{:text_delta, "hello"}]
    end

    test "finish_reason becomes finish" do
      chunk = %{choices: [%{delta: %{}, finish_reason: "stop"}]}
      assert LlamaCpp.normalize_chunk(chunk) == [{:finish, "stop"}]
    end

    test "empty choices is unknown" do
      assert LlamaCpp.normalize_chunk(%{choices: []}) == [{:unknown, %{choices: []}}]
    end

    test "non-map chunk is unknown" do
      assert LlamaCpp.normalize_chunk(:garbage) == [{:unknown, :garbage}]
    end
  end

  describe "normalize_chunk/1 — degenerate complete responses" do
    # llama.cpp (like LM Studio/vLLM/Ollama) can return one complete
    # response object on a stream: message instead of delta. Content and
    # tool calls must survive, not just the finish_reason.
    test "complete response with content emits text and finish" do
      chunk = %{choices: [%{message: %{content: "full answer"}, finish_reason: "stop"}]}

      assert LlamaCpp.normalize_chunk(chunk) == [
               {:text_delta, "full answer"},
               {:finish, "stop"}
             ]
    end

    test "complete response with tool calls keeps them" do
      calls = [%{"id" => "c1", "function" => %{"name" => "search", "arguments" => "{}"}}]

      chunk = %{
        choices: [%{message: %{content: nil, tool_calls: calls}, finish_reason: "tool_calls"}]
      }

      assert LlamaCpp.normalize_chunk(chunk) == [
               {:tool_call_delta, calls},
               {:finish, "tool_calls"}
             ]
    end
  end

  describe "complete_response?/1" do
    test "true when a message is present, false for deltas" do
      assert LlamaCpp.complete_response?(%{choices: [%{message: %{content: "x"}}]})
      refute LlamaCpp.complete_response?(%{choices: [%{delta: %{content: "x"}}]})
      refute LlamaCpp.complete_response?(%{choices: []})
      refute LlamaCpp.complete_response?(:garbage)
    end
  end
end

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

  describe "normalize_chunk/1 — tool calls and reasoning (llama_cpp_ex >= 0.8.63)" do
    # The real struct LlamaCppEx.stream_chat_completion/3 emits.
    defp chunk(delta, finish_reason \\ nil) do
      %LlamaCppEx.ChatCompletionChunk{
        id: "chatcmpl-1",
        object: "chat.completion.chunk",
        choices: [%{index: 0, delta: delta, finish_reason: finish_reason}]
      }
    end

    # The shapes it emits with `:tools`: the call starts with id + name and
    # empty arguments, then argument fragments.
    test "tool_calls deltas assemble into one call with decoded arguments" do
      chunks = [
        chunk(%{role: "assistant", content: ""}),
        chunk(%{
          tool_calls: [
            %{
              index: 0,
              id: "call_1",
              type: "function",
              function: %{name: "get_weather", arguments: ""}
            }
          ]
        }),
        chunk(%{tool_calls: [%{index: 0, function: %{arguments: ~s({"city":)}}]}),
        chunk(%{tool_calls: [%{index: 0, function: %{arguments: ~s("Oslo"})}}]}),
        chunk(%{}, "tool_calls")
      ]

      events = chunks |> Nous.StreamNormalizer.normalize(LlamaCpp) |> Enum.to_list()

      assert List.last(events) == {:finish, "tool_calls"}

      calls =
        events
        |> Enum.reduce(Nous.StreamNormalizer.ToolCallAccumulator.new(), fn
          {:tool_call_delta, fragment}, acc ->
            Nous.StreamNormalizer.ToolCallAccumulator.feed(acc, fragment)

          _other, acc ->
            acc
        end)
        |> Nous.StreamNormalizer.ToolCallAccumulator.finalize()

      assert [%{"id" => "call_1", "name" => "get_weather", "arguments" => %{"city" => "Oslo"}}] =
               calls
    end

    test "reasoning_content becomes thinking_delta" do
      chunk = %{choices: [%{delta: %{reasoning_content: "hmm"}, finish_reason: nil}]}
      assert LlamaCpp.normalize_chunk(chunk) == [{:thinking_delta, "hmm"}]
    end

    # A failed stream ends with a bare {:error, reason} element; it must not be
    # filtered out as an unknown chunk, and it is the same error type the
    # non-streaming path returns.
    test "an {:error, reason} element becomes a ProviderError event" do
      reason = "chat template failed: the model's chat template does not support tool calls"

      assert [{:error, %Nous.Errors.ProviderError{provider: :llamacpp, details: ^reason}}] =
               [{:error, reason}] |> Nous.StreamNormalizer.normalize(LlamaCpp) |> Enum.to_list()
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

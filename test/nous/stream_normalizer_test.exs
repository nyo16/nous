defmodule Nous.StreamNormalizerTest do
  @moduledoc """
  Tests for the StreamNormalizer.normalize/2 pipeline function.

  This tests the critical pipeline that sits between raw provider streams
  and consumers — including error passthrough, unknown filtering, and
  normalizer dispatch.
  """

  use ExUnit.Case, async: true

  alias Nous.StreamNormalizer

  describe "normalize/2 error passthrough" do
    test "converts {:stream_error, %{status: 500}} to {:error, ...}" do
      stream = [{:stream_error, %{status: 500}}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:error, %{status: 500}}] = events
    end

    test "converts {:stream_error, %{reason: :timeout}} to {:error, ...}" do
      stream = [{:stream_error, %{reason: :timeout, timeout_ms: 60_000}}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:error, %{reason: :timeout, timeout_ms: 60_000}}] = events
    end

    test "converts {:stream_error, %{reason: :buffer_overflow}} to {:error, ...}" do
      stream = [{:stream_error, %{reason: :buffer_overflow}}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:error, %{reason: :buffer_overflow}}] = events
    end

    test "error events are NOT filtered out by the reject step" do
      stream = [
        %{"choices" => [%{"delta" => %{"content" => "hello"}}]},
        {:stream_error, %{status: 502}},
        {:stream_done, "stop"}
      ]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert {:text_delta, "hello"} in events
      assert {:error, %{status: 502}} in events
    end

    test "stream_error before any data still propagates" do
      stream = [{:stream_error, %{status: 401}}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:error, %{status: 401}}] = events
    end
  end

  describe "normalize/2 with OpenAI normalizer (default)" do
    test "passes text deltas through" do
      stream = [%{"choices" => [%{"delta" => %{"content" => "hello"}}]}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:text_delta, "hello"}] = events
    end

    test "passes finish events through" do
      stream = [%{"choices" => [%{"finish_reason" => "stop"}]}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:finish, "stop"}] = events
    end

    test "converts {:stream_done, ...} to {:finish, ...}" do
      stream = [{:stream_done, "stop"}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:finish, "stop"}] = events
    end

    test "filters {:unknown, ...} events" do
      stream = [
        %{"choices" => [%{"delta" => %{"content" => "hi"}}]},
        %{"choices" => [%{"delta" => %{}}]},
        {:stream_done, "stop"}
      ]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert {:text_delta, "hi"} in events
      assert {:finish, "stop"} in events

      refute Enum.any?(events, fn
               {:unknown, _} -> true
               _ -> false
             end)
    end

    test "handles thinking deltas" do
      stream = [%{"choices" => [%{"delta" => %{"reasoning" => "let me think"}}]}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:thinking_delta, "let me think"}] = events
    end

    test "handles tool call deltas" do
      tool_calls = [%{"id" => "call_1", "function" => %{"name" => "test"}}]
      stream = [%{"choices" => [%{"delta" => %{"tool_calls" => tool_calls}}]}]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert [{:tool_call_delta, ^tool_calls}] = events
    end

    test "full stream sequence" do
      stream = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}}]},
        %{"choices" => [%{"finish_reason" => "stop"}]},
        {:stream_done, "stop"}
      ]

      events = StreamNormalizer.normalize(stream) |> Enum.to_list()

      assert {:text_delta, "Hello"} in events
      assert {:text_delta, " world"} in events
      # May have 1 or 2 finish events (from finish_reason + stream_done)
      finish_events = Enum.filter(events, &match?({:finish, _}, &1))
      assert length(finish_events) >= 1
    end
  end

  describe "normalize/2 with Anthropic normalizer" do
    test "passes Anthropic text deltas through" do
      stream = [
        %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => "hello"}
        }
      ]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Anthropic) |> Enum.to_list()

      assert [{:text_delta, "hello"}] = events
    end

    test "passes Anthropic error maps through as {:error, ...}" do
      stream = [
        %{"type" => "error", "error" => %{"message" => "rate limited"}}
      ]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Anthropic) |> Enum.to_list()

      assert [{:error, "rate limited"}] = events
    end

    test "stream_error tuples converted before reaching Anthropic normalizer" do
      stream = [
        %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => "hi"}
        },
        {:stream_error, %{status: 500}}
      ]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Anthropic) |> Enum.to_list()

      assert {:text_delta, "hi"} in events
      assert {:error, %{status: 500}} in events
    end

    test "handles {:stream_done, ...}" do
      stream = [{:stream_done, "stop"}]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Anthropic) |> Enum.to_list()

      assert [{:finish, "stop"}] = events
    end
  end

  describe "normalize/2 with Gemini normalizer" do
    test "passes Gemini text deltas through" do
      stream = [
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hello"}]}}]}
      ]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Gemini) |> Enum.to_list()

      assert [{:text_delta, "hello"}] = events
    end

    test "stream_error tuples converted before reaching Gemini normalizer" do
      stream = [{:stream_error, %{reason: :timeout}}]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Gemini) |> Enum.to_list()

      assert [{:error, %{reason: :timeout}}] = events
    end

    test "handles Gemini error responses" do
      stream = [%{"error" => %{"message" => "quota exceeded"}}]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Gemini) |> Enum.to_list()

      assert [{:error, "quota exceeded"}] = events
    end

    test "handles {:stream_done, ...}" do
      stream = [{:stream_done, "stop"}]

      events =
        StreamNormalizer.normalize(stream, StreamNormalizer.Gemini) |> Enum.to_list()

      assert [{:finish, "stop"}] = events
    end
  end

  describe "normalize/2 with custom normalizer" do
    defmodule TestNormalizer do
      @behaviour Nous.StreamNormalizer

      @impl true
      def normalize_chunk(%{"custom" => text}), do: [{:text_delta, text}]
      def normalize_chunk(_), do: [{:unknown, :ignored}]

      @impl true
      def complete_response?(_), do: false

      @impl true
      def convert_complete_response(_), do: []
    end

    test "accepts a custom normalizer module" do
      stream = [%{"custom" => "hello"}, %{"other" => "bye"}]

      events = StreamNormalizer.normalize(stream, TestNormalizer) |> Enum.to_list()

      assert [{:text_delta, "hello"}] = events
    end

    test "custom normalizer does not receive {:stream_error, ...}" do
      stream = [%{"custom" => "hi"}, {:stream_error, %{status: 503}}]

      events = StreamNormalizer.normalize(stream, TestNormalizer) |> Enum.to_list()

      assert {:text_delta, "hi"} in events
      assert {:error, %{status: 503}} in events
    end
  end
end

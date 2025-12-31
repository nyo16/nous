defmodule Nous.Providers.HTTPTest do
  use ExUnit.Case, async: true

  alias Nous.Providers.HTTP

  # ============================================================================
  # SSE Buffer Parsing Tests
  # ============================================================================

  describe "parse_sse_buffer/1" do
    test "parses single complete event" do
      buffer = "data: {\"text\": \"hello\"}\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"text" => "hello"}]
      assert remaining == ""
    end

    test "parses multiple complete events" do
      buffer = "data: {\"id\": 1}\n\ndata: {\"id\": 2}\n\ndata: {\"id\": 3}\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]
      assert remaining == ""
    end

    test "handles incomplete event (no trailing double newline)" do
      buffer = "data: {\"partial\": true}"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == []
      assert remaining == "data: {\"partial\": true}"
    end

    test "returns remaining buffer for partial events" do
      buffer = "data: {\"first\": 1}\n\ndata: {\"incomplete\":"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"first" => 1}]
      assert remaining == "data: {\"incomplete\":"
    end

    test "handles empty buffer" do
      {events, remaining} = HTTP.parse_sse_buffer("")
      assert events == []
      assert remaining == ""
    end

    test "handles nil buffer" do
      {events, remaining} = HTTP.parse_sse_buffer(nil)
      assert events == []
      assert remaining == ""
    end

    test "handles [DONE] marker" do
      buffer = "data: [DONE]\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [{:stream_done, "stop"}]
      assert remaining == ""
    end

    test "handles events before [DONE]" do
      buffer = "data: {\"text\": \"last message\"}\n\ndata: [DONE]\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"text" => "last message"}, {:stream_done, "stop"}]
      assert remaining == ""
    end

    test "handles CRLF line endings" do
      buffer = "data: {\"text\": \"hello\"}\r\n\r\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"text" => "hello"}]
      assert remaining == ""
    end

    test "handles mixed line endings" do
      buffer = "data: {\"a\": 1}\n\ndata: {\"b\": 2}\r\n\r\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"a" => 1}, %{"b" => 2}]
      assert remaining == ""
    end

    test "handles whitespace-only events (ignored)" do
      buffer = "   \n\ndata: {\"real\": true}\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert events == [%{"real" => true}]
      assert remaining == ""
    end

    test "handles malformed JSON" do
      buffer = "data: {invalid json}\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert length(events) == 1
      assert match?({:parse_error, _}, hd(events))
      assert remaining == ""
    end

    test "continues after malformed JSON" do
      buffer = "data: {invalid}\n\ndata: {\"valid\": true}\n\n"
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      # One parse error, one valid event
      assert length(events) == 2
      assert match?({:parse_error, _}, Enum.at(events, 0))
      assert Enum.at(events, 1) == %{"valid" => true}
      assert remaining == ""
    end

    test "handles large buffer without overflow" do
      # Create a reasonable size buffer
      data = String.duplicate("x", 1000)
      buffer = "data: {\"data\": \"#{data}\"}\n\n"
      {events, _remaining} = HTTP.parse_sse_buffer(buffer)

      assert length(events) == 1
      assert events |> hd() |> Map.get("data") |> String.length() == 1000
    end
  end

  # ============================================================================
  # SSE Event Parsing Tests
  # ============================================================================

  describe "parse_sse_event/1" do
    test "parses simple data field" do
      event = "data: {\"key\": \"value\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"key" => "value"}
    end

    test "parses data field without space after colon" do
      event = "data:{\"key\": \"value\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"key" => "value"}
    end

    test "parses [DONE] marker" do
      assert HTTP.parse_sse_event("data: [DONE]") == {:stream_done, "stop"}
      assert HTTP.parse_sse_event("data:[DONE]") == {:stream_done, "stop"}
    end

    test "ignores comment lines (starting with :)" do
      event = ": this is a comment"
      assert HTTP.parse_sse_event(event) == nil
    end

    test "ignores comment lines mixed with data" do
      event = ": comment\ndata: {\"value\": 42}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"value" => 42}
    end

    test "handles multiple data fields (concatenated per SSE spec)" do
      event = "data: {\"line1\": true}\ndata: {\"line2\": true}"
      result = HTTP.parse_sse_event(event)

      # Per SSE spec, multiple data fields are joined with newlines
      # This will fail JSON parsing since it's two JSON objects joined
      assert match?({:parse_error, _}, result)
    end

    test "handles empty event" do
      assert HTTP.parse_sse_event("") == nil
      assert HTTP.parse_sse_event("   ") == nil
      assert HTTP.parse_sse_event("\n") == nil
    end

    test "handles nil input" do
      assert HTTP.parse_sse_event(nil) == nil
    end

    test "ignores event: field" do
      event = "event: message\ndata: {\"text\": \"hi\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"text" => "hi"}
    end

    test "ignores id: field" do
      event = "id: 123\ndata: {\"text\": \"hi\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"text" => "hi"}
    end

    test "ignores retry: field" do
      event = "retry: 5000\ndata: {\"text\": \"hi\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"text" => "hi"}
    end

    test "handles event with only comments" do
      event = ": comment 1\n: comment 2"
      assert HTTP.parse_sse_event(event) == nil
    end

    test "handles complex JSON in data" do
      json = %{
        "nested" => %{
          "array" => [1, 2, 3],
          "object" => %{"deep" => true}
        },
        "unicode" => "こんにちは",
        "special_chars" => "line1\nline2\ttab"
      }
      event = "data: #{Jason.encode!(json)}"
      result = HTTP.parse_sse_event(event)

      assert result == json
    end

    test "handles escaped characters in JSON" do
      event = "data: {\"text\": \"quote: \\\"hello\\\"\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"text" => "quote: \"hello\""}
    end
  end

  # ============================================================================
  # Header Builder Tests
  # ============================================================================

  describe "bearer_auth_header/1" do
    test "builds header for valid API key" do
      assert HTTP.bearer_auth_header("sk-test-key") == [{"authorization", "Bearer sk-test-key"}]
    end

    test "returns empty list for nil" do
      assert HTTP.bearer_auth_header(nil) == []
    end

    test "returns empty list for empty string" do
      assert HTTP.bearer_auth_header("") == []
    end

    test "returns empty list for 'not-needed'" do
      assert HTTP.bearer_auth_header("not-needed") == []
    end

    test "handles non-string input" do
      assert HTTP.bearer_auth_header(123) == []
      assert HTTP.bearer_auth_header(%{}) == []
      assert HTTP.bearer_auth_header([]) == []
    end
  end

  describe "api_key_header/2" do
    test "builds header for valid API key" do
      assert HTTP.api_key_header("sk-ant-key", "x-api-key") == [{"x-api-key", "sk-ant-key"}]
    end

    test "returns empty list for nil API key" do
      assert HTTP.api_key_header(nil, "x-api-key") == []
    end

    test "returns empty list for empty string API key" do
      assert HTTP.api_key_header("", "x-api-key") == []
    end

    test "handles custom header names" do
      assert HTTP.api_key_header("key123", "authorization") == [{"authorization", "key123"}]
      assert HTTP.api_key_header("key456", "X-Custom-Auth") == [{"X-Custom-Auth", "key456"}]
    end

    test "handles non-string inputs" do
      assert HTTP.api_key_header(123, "x-api-key") == []
      assert HTTP.api_key_header("key", 123) == []
    end
  end

  # ============================================================================
  # Input Validation Tests
  # ============================================================================

  describe "post/4 input validation" do
    test "returns error for non-string URL" do
      result = HTTP.post(123, %{}, [])
      assert {:error, %ArgumentError{}} = result
    end

    test "returns error for non-map body" do
      result = HTTP.post("http://test.com", "string body", [])
      assert {:error, %ArgumentError{}} = result
    end

    test "returns error for non-list headers" do
      result = HTTP.post("http://test.com", %{}, %{})
      assert {:error, %ArgumentError{}} = result
    end
  end

  describe "stream/4 input validation" do
    test "returns error for non-string URL" do
      result = HTTP.stream(123, %{}, [])
      assert {:error, %ArgumentError{}} = result
    end

    test "returns error for non-map body" do
      result = HTTP.stream("http://test.com", "string body", [])
      assert {:error, %ArgumentError{}} = result
    end

    test "returns error for non-list headers" do
      result = HTTP.stream("http://test.com", %{}, %{})
      assert {:error, %ArgumentError{}} = result
    end
  end

  # ============================================================================
  # Real-World SSE Examples
  # ============================================================================

  describe "real-world SSE formats" do
    test "parses OpenAI streaming format" do
      # Simulated OpenAI streaming chunk
      buffer = """
      data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

      data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

      data: [DONE]

      """
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert length(events) == 3
      assert hd(events)["choices"] |> hd() |> get_in(["delta", "content"]) == "Hello"
      assert Enum.at(events, 1)["choices"] |> hd() |> get_in(["delta", "content"]) == " world"
      assert Enum.at(events, 2) == {:stream_done, "stop"}
      assert remaining == ""
    end

    test "parses Anthropic streaming format" do
      # Simulated Anthropic streaming chunks
      buffer = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}

      event: message_stop
      data: {"type":"message_stop"}

      """
      {events, remaining} = HTTP.parse_sse_buffer(buffer)

      assert length(events) == 3
      assert hd(events)["delta"]["text"] == "Hello"
      assert Enum.at(events, 1)["delta"]["text"] == " there"
      assert Enum.at(events, 2)["type"] == "message_stop"
      assert remaining == ""
    end

    test "parses chunked delivery of partial events" do
      # Simulate receiving data in chunks
      chunk1 = "data: {\"chunk\":"
      chunk2 = " 1}\n\ndata"
      chunk3 = ": {\"chunk\": 2}\n\n"

      # First chunk - incomplete
      {events1, buffer1} = HTTP.parse_sse_buffer(chunk1)
      assert events1 == []
      assert buffer1 == "data: {\"chunk\":"

      # Second chunk - completes first event, starts second
      {events2, buffer2} = HTTP.parse_sse_buffer(buffer1 <> chunk2)
      assert events2 == [%{"chunk" => 1}]
      assert buffer2 == "data"

      # Third chunk - completes second event
      {events3, buffer3} = HTTP.parse_sse_buffer(buffer2 <> chunk3)
      assert events3 == [%{"chunk" => 2}]
      assert buffer3 == ""
    end

    test "handles rapid succession of events" do
      # Many events in quick succession (no trailing newline between chunks)
      events_data = Enum.map(1..100, fn i ->
        "data: {\"seq\": #{i}}\n\n"
      end) |> Enum.join("")

      {events, remaining} = HTTP.parse_sse_buffer(events_data)

      assert length(events) == 100
      assert Enum.at(events, 0) == %{"seq" => 1}
      assert Enum.at(events, 99) == %{"seq" => 100}
      assert remaining == ""
    end
  end

  # ============================================================================
  # Edge Cases and Error Handling
  # ============================================================================

  describe "edge cases" do
    test "handles empty data field" do
      event = "data: "
      result = HTTP.parse_sse_event(event)
      # Empty data should be nil after trimming
      assert result == nil
    end

    test "handles data field with only whitespace" do
      event = "data:    "
      result = HTTP.parse_sse_event(event)
      assert result == nil
    end

    test "handles unicode in data" do
      event = "data: {\"emoji\": \"🎉\", \"japanese\": \"日本語\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"emoji" => "🎉", "japanese" => "日本語"}
    end

    test "handles very long single-line JSON" do
      long_string = String.duplicate("a", 10_000)
      event = "data: {\"long\": \"#{long_string}\"}"
      result = HTTP.parse_sse_event(event)

      assert result["long"] == long_string
    end

    test "handles newlines within JSON strings (escaped)" do
      event = "data: {\"text\": \"line1\\nline2\\nline3\"}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"text" => "line1\nline2\nline3"}
    end

    test "handles deeply nested JSON" do
      nested = %{
        "l1" => %{
          "l2" => %{
            "l3" => %{
              "l4" => %{
                "l5" => "deep"
              }
            }
          }
        }
      }
      event = "data: #{Jason.encode!(nested)}"
      result = HTTP.parse_sse_event(event)

      assert get_in(result, ["l1", "l2", "l3", "l4", "l5"]) == "deep"
    end

    test "handles arrays in JSON" do
      event = "data: {\"items\": [1, 2, 3, {\"nested\": true}]}"
      result = HTTP.parse_sse_event(event)

      assert result["items"] == [1, 2, 3, %{"nested" => true}]
    end

    test "handles boolean and null values" do
      event = "data: {\"bool\": true, \"null\": null, \"num\": 42.5}"
      result = HTTP.parse_sse_event(event)

      assert result == %{"bool" => true, "null" => nil, "num" => 42.5}
    end
  end
end

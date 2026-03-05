defmodule Nous.Providers.HTTP.JSONArrayParserTest do
  use ExUnit.Case, async: true

  alias Nous.Providers.HTTP.JSONArrayParser

  describe "parse_buffer/1" do
    test "parses a complete JSON array" do
      buffer = ~s|[{"text":"hello"},{"text":"world"}]|
      {events, remaining} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"text" => "hello"}, %{"text" => "world"}]
      assert remaining == ""
    end

    test "parses a single complete object in array" do
      buffer = ~s|[{"id":1}]|
      {events, remaining} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"id" => 1}]
      assert remaining == ""
    end

    test "handles incomplete object at end" do
      buffer = ~s|[{"id":1},{"id":2},{"id|
      {events, remaining} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"id" => 1}, %{"id" => 2}]
      assert remaining == ~s|{"id|
    end

    test "handles no complete objects yet" do
      buffer = ~s|[{"partial|
      {events, remaining} = JSONArrayParser.parse_buffer(buffer)

      assert events == []
      assert remaining == ~s|{"partial|
    end

    test "handles empty buffer" do
      {events, remaining} = JSONArrayParser.parse_buffer("")
      assert events == []
      assert remaining == ""
    end

    test "handles nil buffer" do
      {events, remaining} = JSONArrayParser.parse_buffer(nil)
      assert events == []
      assert remaining == ""
    end

    test "handles just the opening bracket" do
      {events, remaining} = JSONArrayParser.parse_buffer("[")
      assert events == []
      assert remaining == ""
    end

    test "handles whitespace between objects" do
      buffer = ~s|[ {"a":1} , {"b":2} , {"c":3} ]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
    end

    test "handles newlines between objects (typical streaming)" do
      buffer = "[{\"a\":1}\n,{\"b\":2}\n,{\"c\":3}\n]"
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
    end

    test "handles nested objects" do
      buffer = ~s|[{"outer":{"inner":"value"}}]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"outer" => %{"inner" => "value"}}]
    end

    test "handles nested arrays in objects" do
      buffer = ~s|[{"items":[1,2,{"nested":true}]}]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"items" => [1, 2, %{"nested" => true}]}]
    end

    test "handles braces inside strings" do
      buffer = ~s|[{"text":"a {curly} thing"}]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"text" => "a {curly} thing"}]
    end

    test "handles escaped quotes inside strings" do
      buffer = ~s|[{"text":"say \\"hello\\""}]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"text" => ~s|say "hello"|}]
    end

    test "handles escaped backslash before quote" do
      buffer = ~s|[{"path":"C:\\\\Users\\\\test"}]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"path" => "C:\\Users\\test"}]
    end

    test "handles unicode content" do
      buffer = ~s|[{"emoji":"🎉","jp":"日本語"}]|
      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert events == [%{"emoji" => "🎉", "jp" => "日本語"}]
    end

    test "simulates chunked delivery" do
      # Chunk 1: opening bracket + first partial object
      chunk1 = ~s|[{"candi|
      {events1, buf1} = JSONArrayParser.parse_buffer(chunk1)
      assert events1 == []
      assert buf1 == ~s|{"candi|

      # Chunk 2: completes first object, starts second
      chunk2 = ~s|dates":[{"text":"hi"}]}\n,{"candi|
      {events2, buf2} = JSONArrayParser.parse_buffer(buf1 <> chunk2)
      assert events2 == [%{"candidates" => [%{"text" => "hi"}]}]
      assert buf2 == ~s|{"candi|

      # Chunk 3: completes second object + closing bracket
      chunk3 = ~s|dates":[{"text":"bye"}]}\n]|
      {events3, buf3} = JSONArrayParser.parse_buffer(buf2 <> chunk3)
      assert events3 == [%{"candidates" => [%{"text" => "bye"}]}]
      assert buf3 == ""
    end

    test "parses real Gemini streaming response shape" do
      buffer = """
      [{"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}],"modelVersion":"gemini-2.0-flash"}
      ,{"candidates":[{"content":{"parts":[{"text":" there!"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":3,"totalTokenCount":8},"modelVersion":"gemini-2.0-flash"}
      ]
      """

      {events, _} = JSONArrayParser.parse_buffer(buffer)

      assert length(events) == 2

      [first, second] = events

      assert get_in(first, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) ==
               "Hello"

      assert get_in(second, [
               "candidates",
               Access.at(0),
               "content",
               "parts",
               Access.at(0),
               "text"
             ]) == " there!"

      assert get_in(second, ["candidates", Access.at(0), "finishReason"]) == "STOP"
    end

    test "handles many objects efficiently" do
      objects = Enum.map(1..200, fn i -> ~s|{"seq":#{i}}| end) |> Enum.join(",")
      buffer = "[" <> objects <> "]"

      {events, remaining} = JSONArrayParser.parse_buffer(buffer)

      assert length(events) == 200
      assert hd(events) == %{"seq" => 1}
      assert List.last(events) == %{"seq" => 200}
      assert remaining == ""
    end
  end
end

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

  # The resumable arity is only safe if a scan resumed from a saved
  # {pos, depth, in_string} produces byte-identical output to a full
  # rescan. The hazards are all chunk-boundary artefacts: a `\` split from
  # the byte it escapes, a multi-byte UTF-8 codepoint cut in half, a quote
  # as the last byte of a chunk, and nesting that spans many chunks.
  # So: feed every input split at EVERY byte boundary and assert the event
  # stream matches both the one-shot parse and the legacy rescan-per-chunk
  # driver. (perf-audit HIGH: O(n²) rescan.)
  @equivalence_inputs [
    {"simple array", ~s|[{"a":1},{"b":2},{"c":3}]|},
    {"escaped quotes", ~s|[{"text":"say \\"hello\\" now"}]|},
    {"backslash pairs", ~s|[{"path":"C:\\\\Users\\\\x\\\\y"}]|},
    {"escaped backslash at end of string", ~s|[{"t":"a\\\\","u":"b"}]|},
    {"escaped backslash then object break", ~s|[{"t":"end\\\\"},{"v":2}]|},
    {"braces inside strings", ~s|[{"text":"a {curly} }}} thing"}]|},
    {"multibyte", ~s|[{"emoji":"🎉","jp":"日本語ですよ","mix":"a🎉b"}]|},
    {"escape adjacent to multibyte", ~s|[{"t":"x\\\\🎉y","u":"\\"🎉\\""}]|},
    {"deep nesting", ~s|[{"a":{"b":{"c":{"d":{"e":[1,2,{"f":"g"}]}}}}}]|},
    {"whitespace and separators", "[ {\"a\":1}\n , {\"b\":2} \t,\r\n {\"c\":3} ]"},
    {"unterminated tail", ~s|[{"a":1},{"b":|},
    {"control-char escapes", ~s|[{"t":"line1\\nline2\\ttab"}]|},
    {"empty", ""},
    {"bare opening bracket", "["}
  ]

  # Thread scan_state exactly as the stream backends now do.
  defp drive_resumable(chunks) do
    {events, buffer, _scan_state} =
      Enum.reduce(chunks, {[], "", nil}, fn chunk, {acc, buffer, scan_state} ->
        {events, buffer, scan_state} = JSONArrayParser.parse_buffer(buffer <> chunk, scan_state)
        {acc ++ events, buffer, scan_state}
      end)

    {events, buffer}
  end

  # Pre-fix behaviour: full rescan of the accumulated buffer on every chunk.
  defp drive_rescan(chunks) do
    Enum.reduce(chunks, {[], ""}, fn chunk, {acc, buffer} ->
      {events, buffer} = JSONArrayParser.parse_buffer(buffer <> chunk)
      {acc ++ events, buffer}
    end)
  end

  defp assert_split_equivalence(input) do
    one_shot = JSONArrayParser.parse_buffer(input)

    for k <- 0..byte_size(input) do
      <<head::binary-size(^k), tail::binary>> = input
      chunks = Enum.reject([head, tail], &(&1 == ""))
      resumed = drive_resumable(chunks)

      assert resumed == drive_rescan(chunks),
             "resumed scan diverged from a full rescan, split at byte #{k} of #{inspect(input)}"

      assert resumed == one_shot,
             "resumed scan diverged from the one-shot parse, split at byte #{k} of #{inspect(input)}"
    end
  end

  describe "parse_buffer/2 (resumable)" do
    for {name, input} <- @equivalence_inputs do
      @equiv_input input

      test "resumed scan matches a full rescan at every split point — #{name}" do
        assert_split_equivalence(@equiv_input)
      end

      test "byte-at-a-time delivery matches the one-shot parse — #{name}" do
        chunks = for <<b <- @equiv_input>>, do: <<b>>
        assert drive_resumable(chunks) == JSONArrayParser.parse_buffer(@equiv_input)
      end
    end

    test "returns a {pos, depth, in_string} resume token for an incomplete object" do
      assert {[], ~s|{"a":1|, {6, 1, false}} = JSONArrayParser.parse_buffer(~s|[{"a":1|, nil)
    end

    test "returns a nil scan_state once the object closes" do
      assert {[%{"a" => 1}], "", nil} = JSONArrayParser.parse_buffer(~s|{"a":1}]|, {6, 1, false})
    end

    test "carries in_string across a chunk that ends on a quote" do
      # `[{"` — the `[` is skipped, two bytes scanned, ending inside a string.
      assert {[], ~s|{"|, {2, 1, true}} = JSONArrayParser.parse_buffer(~s|[{"|, nil)
    end

    test "stops before a lone trailing backslash so the escape stays intact" do
      # The `\` must NOT be consumed: the byte it escapes is in the next chunk.
      assert {[], remaining, {pos, _depth, true}} =
               JSONArrayParser.parse_buffer(~s|[{"t":"a\\|, nil)

      assert binary_part(remaining, pos, byte_size(remaining) - pos) == "\\"
    end

    test "drops a scan_state when the buffer no longer starts at an object" do
      # A caller that didn't hand back the buffer we returned: the token is
      # meaningless, so re-trim and do a correct (merely slower) full parse.
      assert {[%{"a" => 1}], "", nil} =
               JSONArrayParser.parse_buffer(~s|[{"a":1}]|, {999, 7, true})
    end

    test "drops a scan_state whose offset outruns the buffer" do
      assert {[%{"a" => 1}], "", nil} =
               JSONArrayParser.parse_buffer(~s|{"a":1}|, {999, 7, true})
    end

    test "handles a non-binary buffer" do
      assert JSONArrayParser.parse_buffer(nil, nil) == {[], "", nil}
    end

    test "resumes a single object spanning hundreds of chunks" do
      text = String.duplicate("x", 60 * 1024)
      input = ~s|[{"candidates":[{"content":{"parts":[{"text":"| <> text <> ~s|"}]}}]}]|

      chunks =
        input
        |> Stream.unfold(fn
          <<>> -> nil
          <<h::binary-size(1400), t::binary>> -> {h, t}
          b -> {b, <<>>}
        end)
        |> Enum.to_list()

      assert length(chunks) > 40
      assert drive_resumable(chunks) == JSONArrayParser.parse_buffer(input)
      assert {[%{"candidates" => [_]}], ""} = drive_resumable(chunks)
    end
  end
end

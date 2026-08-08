defmodule Nous.HTTP.BufferTest do
  use ExUnit.Case, async: true

  alias Nous.HTTP.Buffer

  # A parser from before the resumable contract existed: arity 1 only.
  defmodule LegacyParser do
    def parse_buffer(buffer) do
      case String.split(buffer, "|", parts: 2) do
        [event, rest] -> {[%{"e" => event}], rest}
        [rest] -> {[], rest}
      end
    end
  end

  # A parser that opts into the resumable arity. Records every scan_state
  # it is handed so the test can prove the backend threads it back.
  defmodule ResumableParser do
    def parse_buffer(buffer) do
      {events, rest, _} = parse_buffer(buffer, nil)
      {events, rest}
    end

    def parse_buffer(buffer, scan_state) do
      send(self(), {:scan_state_in, scan_state})

      case String.split(buffer, "|", parts: 2) do
        [event, rest] -> {[%{"e" => event}], rest, nil}
        [rest] -> {[], rest, {byte_size(rest), :partial}}
      end
    end
  end

  describe "max_buffer_size/0" do
    test "is 10 MB" do
      assert Buffer.max_buffer_size() == 10 * 1024 * 1024
    end
  end

  describe "parse_stream_buffer/2 (SSE default)" do
    test "parses complete events and keeps the incomplete tail" do
      assert Buffer.parse_stream_buffer("data: {\"a\":1}\n\ndata: {\"b\":", nil) ==
               {[%{"a" => 1}], "data: {\"b\":"}
    end

    test "translates buffer overflow into a stream_error event" do
      oversized = String.duplicate("x", Buffer.max_buffer_size() + 1)

      assert Buffer.parse_stream_buffer(oversized, nil) ==
               {[{:stream_error, %{reason: :buffer_overflow}}], ""}
    end
  end

  describe "parse_stream_buffer/3" do
    test "yields the scanned-byte count for the SSE path" do
      assert Buffer.parse_stream_buffer("data: {\"a\":1}\n\n", nil, nil) ==
               {[%{"a" => 1}], "", 0}
    end

    test "yields a nil scan_state for a parser that only exports parse_buffer/1" do
      assert Buffer.parse_stream_buffer("one|two", LegacyParser, nil) ==
               {[%{"e" => "one"}], "two", nil}
    end

    test "ignores an inbound scan_state for a non-resumable parser" do
      assert Buffer.parse_stream_buffer("one|two", LegacyParser, {99, :stale}) ==
               {[%{"e" => "one"}], "two", nil}
    end

    test "routes to parse_buffer/2 and returns the parser's scan_state" do
      assert Buffer.parse_stream_buffer("partial", ResumableParser, nil) ==
               {[], "partial", {7, :partial}}
    end

    test "hands the previous scan_state back to the parser" do
      Buffer.parse_stream_buffer("partial", ResumableParser, {7, :partial})

      assert_received {:scan_state_in, {7, :partial}}
    end
  end

  # Thread scan_state exactly as the stream backends do: the buffer the
  # parser handed back, plus the next chunk, plus the token it came with.
  defp drive_sse(chunks) do
    {events, buffer, _scan_state} =
      Enum.reduce(chunks, {[], "", nil}, fn chunk, {acc, buffer, scan_state} ->
        {events, buffer, scan_state} =
          Buffer.parse_stream_buffer(buffer <> chunk, nil, scan_state)

        {acc ++ events, buffer, scan_state}
      end)

    {events, buffer}
  end

  defp chunk_bytes(binary, size) do
    binary
    |> Stream.unfold(fn
      <<>> -> nil
      b when byte_size(b) <= size -> {b, <<>>}
      b -> {binary_part(b, 0, size), binary_part(b, size, byte_size(b) - size)}
    end)
    |> Enum.to_list()
  end

  describe "parse_stream_buffer/3 (resumable SSE scan)" do
    test "records how far the separator search reached" do
      assert Buffer.parse_stream_buffer("data: {\"a\":", nil, nil) == {[], "data: {\"a\":", 11}
    end

    test "finds an \\n\\n separator split exactly across two chunks" do
      assert drive_sse(["data: {\"a\":1}\n", "\ndata: {\"b\":2}\n\n"]) ==
               {[%{"a" => 1}, %{"b" => 2}], ""}
    end

    test "finds a \\r\\n\\r\\n separator split at any of its interior bytes" do
      for k <- 1..3 do
        <<head::binary-size(^k), tail::binary>> = "\r\n\r\n"
        chunks = ["data: {\"a\":1}" <> head, tail <> "data: {\"b\":2}\r\n\r\n"]

        assert drive_sse(chunks) == {[%{"a" => 1}, %{"b" => 2}], ""},
               "separator split after #{k} byte(s) was missed"
      end
    end

    test "byte-at-a-time delivery matches the one-shot parse" do
      input = "data: {\"a\":1}\n\ndata: [DONE]\r\n\r\ndata: {\"b\":2}\n\n"

      assert drive_sse(chunk_bytes(input, 1)) == Buffer.parse_sse_buffer(input)
    end

    test "parses several complete events arriving in a single chunk" do
      assert Buffer.parse_stream_buffer(
               "data: {\"a\":1}\n\ndata: {\"b\":2}\r\n\r\ndata: {\"c\":",
               nil,
               nil
             ) == {[%{"a" => 1}, %{"b" => 2}], "data: {\"c\":", 11}
    end

    test "rescans from byte 0 when the scan_state is not an offset into this buffer" do
      assert Buffer.parse_stream_buffer("data: {\"a\":1}\n\n", nil, {99, :stale}) ==
               {[%{"a" => 1}], "", 0}

      assert Buffer.parse_stream_buffer("data: {\"a\":1}\n\n", nil, 999) ==
               {[%{"a" => 1}], "", 0}
    end

    @tag timeout: 120_000
    test "does not rescan the accumulated buffer on every chunk" do
      # One 4 MB event over ~3000 chunks. Re-splitting the whole buffer per
      # chunk measures 5.3 s here (24.4 s at 8 MB — the audit's 20.1 s);
      # resuming at the recorded offset measures 13 ms. The bound sits two
      # orders of magnitude above the resumed cost and five times below the
      # rescan, so only a genuine regression trips it.
      payload = String.duplicate("x", 4 * 1024 * 1024)
      chunks = chunk_bytes("data: {\"text\":\"" <> payload <> "\"}\n\n", 1400)

      {elapsed_us, {events, remaining}} = :timer.tc(fn -> drive_sse(chunks) end)

      assert [%{"text" => text}] = events
      assert byte_size(text) == byte_size(payload)
      assert remaining == ""

      assert elapsed_us < 1_000_000,
             "the SSE scan took #{div(elapsed_us, 1000)}ms — the scan offset is being ignored"
    end
  end

  describe "flush_stream_buffer/2" do
    test "forces the trailing SSE event through with a synthetic separator" do
      assert Buffer.flush_stream_buffer("data: {\"a\":1}", nil) == {[%{"a" => 1}], ""}
    end

    test "reports overflow only when the input itself is over the cap" do
      at_cap = String.duplicate("x", Buffer.max_buffer_size())
      over_cap = at_cap <> "x"

      refute match?({[{:stream_error, _}], _}, Buffer.flush_stream_buffer(at_cap, nil))

      assert Buffer.flush_stream_buffer(over_cap, nil) ==
               {[{:stream_error, %{reason: :buffer_overflow}}], ""}
    end

    test "re-parses the remaining buffer as-is for a custom parser" do
      assert Buffer.flush_stream_buffer("one|two", LegacyParser) == {[%{"e" => "one"}], "two"}
    end
  end

  describe "flush_stream_buffer/3" do
    test "threads scan_state into a resumable parser" do
      assert Buffer.flush_stream_buffer("one|two", ResumableParser, {3, :partial}) ==
               {[%{"e" => "one"}], "two", nil}

      assert_received {:scan_state_in, {3, :partial}}
    end

    test "resumes the SSE scan from the recorded offset" do
      {[], remaining, scan_state} = Buffer.parse_stream_buffer("data: {\"a\":1}", nil, nil)

      assert Buffer.flush_stream_buffer(remaining, nil, scan_state) == {[%{"a" => 1}], "", nil}
    end

    test "completes an event whose separator is half the synthetic one" do
      # The buffer already ends in `\n`, so the flush's own `\n\n` closes the
      # event — but only if the resumed search backs up over that last byte.
      {[], remaining, scan_state} = Buffer.parse_stream_buffer("data: {\"a\":1}\n", nil, nil)

      assert Buffer.flush_stream_buffer(remaining, nil, scan_state) == {[%{"a" => 1}], "\n", nil}
    end
  end

  describe "Nous.Providers.HTTP delegation" do
    test "keeps the pre-extraction API shape" do
      assert Nous.Providers.HTTP.max_buffer_size() == Buffer.max_buffer_size()

      assert Nous.Providers.HTTP.parse_stream_buffer("data: {\"a\":1}\n\n", nil) ==
               {[%{"a" => 1}], ""}

      assert Nous.Providers.HTTP.flush_stream_buffer("data: {\"a\":1}", nil) ==
               {[%{"a" => 1}], ""}

      assert Nous.Providers.HTTP.parse_sse_buffer("data: {\"a\":1}\n\n") == {[%{"a" => 1}], ""}
      assert Nous.Providers.HTTP.parse_sse_event("data: [DONE]") == {:stream_done, "stop"}
    end
  end
end

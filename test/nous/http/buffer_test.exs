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
    test "yields a nil scan_state for the SSE path" do
      assert Buffer.parse_stream_buffer("data: {\"a\":1}\n\n", nil, nil) ==
               {[%{"a" => 1}], "", nil}
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

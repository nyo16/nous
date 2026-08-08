defmodule Nous.HTTP.StreamBackend.ChunkingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nous.HTTP.Buffer
  alias Nous.HTTP.StreamBackend.Chunking

  # `Chunking` is the single definition of the chunk/flush half of both
  # streaming backends' `next_chunk/1`. These assert the contract those
  # backends depend on, not that the functions return a tuple.

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        buffer: "",
        scan_state: nil,
        stream_parser: nil,
        done: false,
        # Stand-in for the transport-owned fields (ref, task, inflight, ...).
        transport: :untouched
      },
      overrides
    )
  end

  defp sse(json), do: "data: " <> json <> "\n\n"

  describe "absorb/2" do
    test "emits a completed event and drops it from the buffer" do
      assert {:emit, [%{"delta" => "hi"}], new_state} =
               Chunking.absorb(state(), sse(~s({"delta":"hi"})))

      assert new_state.buffer == ""
      refute new_state.done
    end

    test "carries a partial event across chunks and emits it once completed" do
      assert {:cont, s1} = Chunking.absorb(state(), ~s(data: {"delta":))
      assert s1.buffer != ""

      assert {:emit, [%{"delta" => "hi"}], s2} = Chunking.absorb(s1, ~s("hi"}\n\n))
      assert s2.buffer == ""
    end

    test "survives a split inside the event delimiter itself" do
      # The delimiter is "\n\n"; splitting between the two newlines is the
      # case a resumable scan offset gets wrong if buffer and scan_state are
      # ever stored apart.
      assert {:cont, s1} = Chunking.absorb(state(), ~s(data: {"delta":"hi"}\n))
      assert {:emit, [%{"delta" => "hi"}], s2} = Chunking.absorb(s1, "\n")
      assert s2.buffer == ""
    end

    test "emits every event when one chunk completes several" do
      chunk = sse(~s({"i":1})) <> sse(~s({"i":2})) <> sse(~s({"i":3}))

      assert {:emit, events, new_state} = Chunking.absorb(state(), chunk)
      assert events == [%{"i" => 1}, %{"i" => 2}, %{"i" => 3}]
      assert new_state.buffer == ""
    end

    test "drops parse errors but still delivers the valid events beside them" do
      chunk = sse("this is not json") <> sse(~s({"i":2}))

      assert {:emit, [%{"i" => 2}], _state} = Chunking.absorb(state(), chunk)
    end

    test "a chunk of only unparseable events yields no emission" do
      assert {:cont, _state} = Chunking.absorb(state(), sse("this is not json"))
    end

    test "leaves transport-owned state fields untouched" do
      assert {:emit, _events, new_state} =
               Chunking.absorb(state(%{transport: :sentinel}), sse(~s({"a":1})))

      assert new_state.transport == :sentinel
    end

    test "terminates the stream when the accumulator exceeds the cap" do
      oversized = :binary.copy("x", Buffer.max_buffer_size() + 1)

      {result, log} = with_log(fn -> Chunking.absorb(state(), oversized) end)

      assert {:emit, [{:stream_error, %{reason: :buffer_overflow}}], new_state} = result
      assert new_state.done
      assert log =~ "SSE buffer overflow"
    end

    test "a buffer at exactly the cap is not an overflow" do
      at_cap = :binary.copy("x", Buffer.max_buffer_size())

      assert {:cont, new_state} = Chunking.absorb(state(), at_cap)
      refute new_state.done
    end
  end

  describe "flush/1" do
    test "delivers a trailing event that never received its delimiter" do
      assert {[%{"delta" => "bye"}], new_state} =
               Chunking.flush(state(%{buffer: ~s(data: {"delta":"bye"})}))

      assert new_state.done
      assert new_state.buffer == ""
      assert new_state.scan_state == nil
    end

    test "halts when the tail holds nothing usable" do
      assert {:halt, new_state} = Chunking.flush(state())
      assert new_state.done
    end

    test "halts rather than emitting a tail that only fails to parse" do
      assert {:halt, new_state} = Chunking.flush(state(%{buffer: "data: not json"}))
      assert new_state.done
    end
  end
end

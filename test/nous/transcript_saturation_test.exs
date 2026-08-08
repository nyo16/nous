defmodule Nous.TranscriptSaturationTest do
  # Saturating Nous.TaskSupervisor mutates a process-wide supervisor, so it is
  # only safe from a sync module — and transcript_test.exs is async: true and
  # should stay that way. Hence a separate module for the refusal paths.
  # `use Nous.TaskSupervisorSaturation` will not compile in an async module.
  use ExUnit.Case, async: false
  use Nous.TaskSupervisorSaturation

  import ExUnit.CaptureLog

  alias Nous.Message
  alias Nous.Transcript

  setup do
    saturate!()
    :ok
  end

  describe "task supervisor saturation" do
    test "compact_async/3 refuses instead of relocating the caller's callback" do
      messages = for i <- 1..20, do: Message.user("msg #{i}")
      test_pid = self()

      log =
        capture_log(fn ->
          assert Transcript.compact_async(messages, 10, fn compacted ->
                   send(test_pid, {:compacted, compacted})
                 end) == {:error, :saturated}
        end)

      assert log =~ "at its :max_children ceiling"

      # The callback is caller-supplied code. It is not fired, and — the part
      # that matters — it is not run in the calling process either, which is
      # why this degrades to an error rather than to inline execution.
      refute_receive {:compacted, _}, 100
    end

    test "maybe_compact_async/3 refuses instead of relocating the caller's callback" do
      messages = for i <- 1..25, do: Message.user("msg #{i}")
      test_pid = self()

      log =
        capture_log(fn ->
          assert Transcript.maybe_compact_async(
                   messages,
                   [every: 20, keep_last: 10],
                   fn result -> send(test_pid, result) end
                 ) == {:error, :saturated}
        end)

      assert log =~ "at its :max_children ceiling"

      # Not even {:unchanged, messages}: the trigger was never evaluated, and
      # reporting "no compaction needed" would misdescribe a refusal.
      refute_receive {:compacted, _}, 100
      refute_receive {:unchanged, _}, 0
    end
  end
end

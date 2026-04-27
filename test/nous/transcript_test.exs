defmodule Nous.TranscriptTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Transcript

  describe "compact/2" do
    test "returns messages unchanged when under threshold" do
      messages = for i <- 1..5, do: Message.user("msg #{i}")
      assert Transcript.compact(messages, 10) == messages
    end

    test "compacts messages over threshold" do
      messages = for i <- 1..20, do: Message.user("msg #{i}")
      compacted = Transcript.compact(messages, 10)

      # 1 summary + 10 recent
      assert length(compacted) == 11

      # First message should be a summary
      [summary | recent] = compacted
      assert summary.role == :system
      assert summary.content =~ "Compacted 10 earlier messages"

      # Recent messages should be the last 10
      assert length(recent) == 10
      last_msg = List.last(recent)
      assert last_msg.content == "msg 20"
    end

    test "preserves leading system messages" do
      system = Message.system("You are helpful")
      messages = [system | for(i <- 1..15, do: Message.user("msg #{i}"))]
      compacted = Transcript.compact(messages, 5)

      # System message preserved at start
      assert hd(compacted).role == :system
      assert hd(compacted).content == "You are helpful"

      # Second message should be the summary
      assert Enum.at(compacted, 1).role == :system
      assert Enum.at(compacted, 1).content =~ "Compacted"
    end

    test "handles exact threshold" do
      messages = for i <- 1..10, do: Message.user("msg #{i}")
      assert Transcript.compact(messages, 10) == messages
    end

    test "handles single message" do
      messages = [Message.user("hello")]
      assert Transcript.compact(messages, 10) == messages
    end

    test "handles empty list" do
      assert Transcript.compact([], 10) == []
    end

    test "never splits a tool_call/tool_result pair across the boundary" do
      # Regression for H-1: with the naive split, a :tool message at the
      # head of `recent` would be orphaned from its assistant tool_call
      # in `old`, and the next provider call would 400 with "tool_use ids
      # did not have corresponding tool_result".
      tc = %{id: "call_1", function: %{name: "x", arguments: "{}"}}

      messages = [
        Message.system("sys"),
        Message.user("u1"),
        Message.user("u2"),
        Message.user("u3"),
        # The boundary should land at this assistant with keep_last: 4
        Message.assistant("calling tool", tool_calls: [tc]),
        Message.tool("call_1", "tool result"),
        Message.user("u4"),
        Message.assistant("done")
      ]

      compacted = Transcript.compact(messages, 4)

      # The :tool message must NOT appear at the head of `recent`.
      [_system, _summary | recent] = compacted
      refute hd(recent).role == :tool
    end
  end

  describe "estimate_tokens/1" do
    test "counts words" do
      assert Transcript.estimate_tokens("hello world") == 2
      assert Transcript.estimate_tokens("one two three four five") == 5
    end

    test "handles nil and empty" do
      assert Transcript.estimate_tokens(nil) == 0
      assert Transcript.estimate_tokens("") == 0
    end

    test "handles multiline text" do
      assert Transcript.estimate_tokens("hello\nworld\nfoo") == 3
    end
  end

  describe "estimate_messages_tokens/1" do
    test "sums tokens across messages" do
      messages = [
        Message.user("hello world"),
        Message.assistant("hi there friend")
      ]

      assert Transcript.estimate_messages_tokens(messages) == 5
    end

    test "handles empty list" do
      assert Transcript.estimate_messages_tokens([]) == 0
    end
  end

  describe "compact_async/2" do
    test "returns a task that resolves to compacted messages" do
      messages = for i <- 1..20, do: Message.user("msg #{i}")
      task = Transcript.compact_async(messages, 10)
      compacted = Task.await(task)

      assert length(compacted) == 11
      assert hd(compacted).role == :system
      assert hd(compacted).content =~ "Compacted 10 earlier messages"
    end

    test "handles messages under threshold" do
      messages = for i <- 1..5, do: Message.user("msg #{i}")
      task = Transcript.compact_async(messages, 10)
      assert Task.await(task) == messages
    end
  end

  describe "compact_async/3" do
    test "fires callback with compacted messages" do
      messages = for i <- 1..20, do: Message.user("msg #{i}")
      test_pid = self()

      {:ok, _pid} =
        Transcript.compact_async(messages, 10, fn compacted ->
          send(test_pid, {:compacted, compacted})
        end)

      assert_receive {:compacted, compacted}, 5_000
      assert length(compacted) == 11
      assert hd(compacted).content =~ "Compacted"
    end
  end

  describe "maybe_compact/2" do
    test "compacts when message count exceeds :every" do
      messages = for i <- 1..25, do: Message.user("msg #{i}")
      result = Transcript.maybe_compact(messages, every: 20, keep_last: 10)

      assert length(result) == 11
      assert hd(result).content =~ "Compacted"
    end

    test "does not compact when under :every threshold" do
      messages = for i <- 1..15, do: Message.user("msg #{i}")
      result = Transcript.maybe_compact(messages, every: 20, keep_last: 10)

      assert result == messages
    end

    test "compacts when token budget threshold exceeded" do
      # Each message is ~2 words/tokens ("msg N"), budget is 20 tokens at 80%
      # 16 tokens triggers compaction (> 20 * 0.8 = 16)
      messages = for i <- 1..10, do: Message.user("msg #{i}")
      result = Transcript.maybe_compact(messages, token_budget: 20, keep_last: 5)

      assert length(result) == 6
      assert hd(result).content =~ "Compacted"
    end

    test "does not compact when under token budget threshold" do
      messages = for i <- 1..3, do: Message.user("msg #{i}")
      result = Transcript.maybe_compact(messages, token_budget: 200, keep_last: 5)

      assert result == messages
    end

    test "custom threshold percentage" do
      # 10 messages * ~2 tokens = ~20 tokens, budget 100, threshold 0.1 = 10
      messages = for i <- 1..10, do: Message.user("msg #{i}")

      result =
        Transcript.maybe_compact(messages,
          token_budget: 100,
          threshold: 0.1,
          keep_last: 5
        )

      assert length(result) == 6
      assert hd(result).content =~ "Compacted"
    end

    test "both triggers — count fires first" do
      messages = for i <- 1..25, do: Message.user("msg #{i}")

      result =
        Transcript.maybe_compact(messages,
          every: 20,
          token_budget: 999_999,
          keep_last: 10
        )

      assert length(result) == 11
    end

    test "both triggers — token budget fires first" do
      messages = for i <- 1..10, do: Message.user("msg #{i}")

      result =
        Transcript.maybe_compact(messages,
          every: 999,
          token_budget: 10,
          keep_last: 5
        )

      assert length(result) == 6
    end

    test "neither trigger fires" do
      messages = for i <- 1..5, do: Message.user("msg #{i}")

      result =
        Transcript.maybe_compact(messages,
          every: 100,
          token_budget: 999_999,
          keep_last: 3
        )

      assert result == messages
    end
  end

  describe "maybe_compact_async/3" do
    test "fires callback with :compacted when triggered" do
      messages = for i <- 1..25, do: Message.user("msg #{i}")
      test_pid = self()

      {:ok, _pid} =
        Transcript.maybe_compact_async(
          messages,
          [every: 20, keep_last: 10],
          fn result -> send(test_pid, result) end
        )

      assert_receive {:compacted, compacted}, 5_000
      assert length(compacted) == 11
    end

    test "fires callback with :unchanged when not triggered" do
      messages = for i <- 1..5, do: Message.user("msg #{i}")
      test_pid = self()

      {:ok, _pid} =
        Transcript.maybe_compact_async(
          messages,
          [every: 100, keep_last: 10],
          fn result -> send(test_pid, result) end
        )

      assert_receive {:unchanged, unchanged}, 5_000
      assert unchanged == messages
    end
  end

  describe "should_compact?/2" do
    test "returns true when over threshold" do
      messages = for _ <- 1..25, do: Message.user("msg")
      assert Transcript.should_compact?(messages, 20)
    end

    test "returns false when under threshold" do
      messages = for _ <- 1..10, do: Message.user("msg")
      refute Transcript.should_compact?(messages, 20)
    end
  end
end

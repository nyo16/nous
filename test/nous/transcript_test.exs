defmodule Nous.TranscriptTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Transcript

  doctest Nous.Transcript

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

  describe "prune_tool_results/2" do
    test "leaves a result one character under the cap untouched" do
      content = String.duplicate("x", 100)
      msg = Message.tool("call_1", content)

      assert [^msg] = Transcript.prune_tool_results([msg], 101)
    end

    test "leaves a result exactly at the cap untouched" do
      content = String.duplicate("x", 100)
      msg = Message.tool("call_1", content)

      assert [^msg] = Transcript.prune_tool_results([msg], 100)
    end

    test "prunes a result one character over the cap" do
      content = String.duplicate("x", 101)
      msg = Message.tool("call_1", content)

      assert [pruned] = Transcript.prune_tool_results([msg], 100)
      refute pruned.content == content
      assert pruned.content =~ "bytes elided by transcript pruning"
    end

    test "keeps the head and the tail and names the dropped byte count" do
      head = String.duplicate("H", 4096)
      middle = String.duplicate("M", 50_000)
      tail = String.duplicate("T", 1024)
      msg = Message.tool("call_1", head <> middle <> tail)

      assert [pruned] = Transcript.prune_tool_results([msg])

      assert String.starts_with?(pruned.content, head)
      assert String.ends_with?(pruned.content, tail)
      # Everything between the kept head and tail is accounted for.
      assert pruned.content =~ "[... 50000 bytes elided"
      # And the marker is not merely appended to the original payload.
      assert byte_size(pruned.content) < 6_000
    end

    test "is codepoint-safe on multibyte content" do
      content = String.duplicate("日", 10_000)
      msg = Message.tool("call_1", content)

      assert [pruned] = Transcript.prune_tool_results([msg])
      assert String.valid?(pruned.content)
      assert String.starts_with?(pruned.content, String.duplicate("日", 4096))
    end

    test "never reorders, drops or adds messages" do
      big = String.duplicate("x", 20_000)

      messages = [
        Message.system("sys"),
        Message.user("u1"),
        Message.assistant("calling", tool_calls: [%{id: "call_1", name: "read"}]),
        Message.tool("call_1", big),
        Message.user("u2"),
        Message.assistant("done")
      ]

      pruned = Transcript.prune_tool_results(messages)

      assert length(pruned) == length(messages)
      assert Enum.map(pruned, & &1.role) == Enum.map(messages, & &1.role)

      # The tool_call/tool_result pair is still adjacent and still paired.
      assert [_sys, _u1, call, result | _] = pruned
      assert [%{id: "call_1"}] = call.tool_calls
      assert result.tool_call_id == "call_1"
    end

    test "leaves oversized non-tool messages alone" do
      big = String.duplicate("x", 20_000)

      messages = [
        Message.system(big),
        Message.user(big),
        Message.assistant(big)
      ]

      assert Transcript.prune_tool_results(messages) == messages
    end

    test "leaves a tool result whose content is not plain text alone" do
      parts = [Nous.Message.ContentPart.text(String.duplicate("x", 20_000))]
      msg = %Message{role: :tool, tool_call_id: "call_1", content: parts}

      assert [^msg] = Transcript.prune_tool_results([msg])
    end

    test "handles an empty list" do
      assert Transcript.prune_tool_results([]) == []
    end
  end

  describe "balance_tool_call_boundary/2" do
    test "pulls orphaned tool results at the head of recent back into old" do
      call = Message.assistant("calling", tool_calls: [%{id: "c1", name: "x"}])
      result = Message.tool("c1", "done")
      next = Message.user("next")

      assert {[^call, ^result], [^next]} =
               Transcript.balance_tool_call_boundary([call], [result, next])
    end

    test "pulls back an entire parallel tool-result run" do
      call =
        Message.assistant("calling",
          tool_calls: [%{id: "c1", name: "x"}, %{id: "c2", name: "y"}]
        )

      r1 = Message.tool("c1", "a")
      r2 = Message.tool("c2", "b")
      next = Message.user("next")

      assert {[^call, ^r1, ^r2], [^next]} =
               Transcript.balance_tool_call_boundary([call], [r1, r2, next])
    end

    test "pulls back the remainder when the boundary lands mid-run" do
      # The other direction: some results already landed in old, the rest are
      # at the head of recent. Both halves must end up on the same side.
      call =
        Message.assistant("calling",
          tool_calls: [%{id: "c1", name: "x"}, %{id: "c2", name: "y"}]
        )

      r1 = Message.tool("c1", "a")
      r2 = Message.tool("c2", "b")
      next = Message.user("next")

      assert {[^call, ^r1, ^r2], [^next]} =
               Transcript.balance_tool_call_boundary([call, r1], [r2, next])
    end

    test "leaves a boundary that does not split a pair untouched" do
      old = [Message.user("u1"), Message.assistant("a1")]
      recent = [Message.user("u2"), Message.assistant("a2")]

      assert {^old, ^recent} = Transcript.balance_tool_call_boundary(old, recent)
    end

    test "handles empty sides" do
      assert {[], []} = Transcript.balance_tool_call_boundary([], [])

      msg = Message.user("u1")
      assert {[^msg], []} = Transcript.balance_tool_call_boundary([msg], [])
    end
  end

  describe "estimate_tokens/1" do
    test "estimates from byte length, not word count" do
      # 11 bytes / 4 and 23 bytes / 4. The word-count estimator this replaced
      # happened to agree here...
      assert Transcript.estimate_tokens("hello world") == 2
      assert Transcript.estimate_tokens("one two three four five") == 5

      # ...and disagrees badly on long words and on code, which is the point.
      assert Transcript.estimate_tokens("antidisestablishmentarianism") == 7
      assert Transcript.estimate_tokens("def f(x), do: {:ok, x}") == 5
    end

    test "handles nil and empty" do
      assert Transcript.estimate_tokens(nil) == 0
      assert Transcript.estimate_tokens("") == 0
    end

    test "handles multiline text" do
      assert Transcript.estimate_tokens("hello\nworld\nfoo") == 3
    end

    test "counts UTF-8 bytes, so multibyte text estimates high" do
      # Three CJK characters are 9 bytes but ~3 tokens for most tokenizers.
      # Documented as a known bias; asserted so a silent change is caught.
      assert Transcript.estimate_tokens("日本語") == 2
    end
  end

  describe "estimate_messages_tokens/1" do
    test "sums tokens across messages" do
      messages = [
        Message.user("hello world"),
        Message.assistant("hi there friend")
      ]

      # 11 + 15 = 26 bytes, divided once.
      assert Transcript.estimate_messages_tokens(messages) == 6
    end

    test "sums bytes before dividing rather than rounding per message" do
      # Three 3-byte messages: 9 bytes / 4 = 2. Per-message rounding would
      # floor each to 0 and report 0.
      messages = for _ <- 1..3, do: Message.user("abc")

      assert Transcript.estimate_messages_tokens(messages) == 2
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
      # 9 x "msg N" (5 bytes) + "msg 10" (6 bytes) = 51 bytes = 12 estimated
      # tokens, which clears the 10 * 0.8 = 8 token trigger.
      messages = for i <- 1..10, do: Message.user("msg #{i}")
      result = Transcript.maybe_compact(messages, token_budget: 10, keep_last: 5)

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

defmodule Nous.Session.LogTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Session.{Event, Log}
  doctest Nous.Session.Event
  doctest Nous.Session.Log

  defp append!(log, type, data), do: elem(Log.append(log, type, data), 1)

  defp proj(messages) do
    Enum.map(messages, &{&1.role, &1.content, &1.tool_call_id, &1.name, &1.tool_calls})
  end

  # A complete tool-calling exchange: the shape every projection rule has to
  # handle, built once so the tests below read as assertions rather than setup.
  defp exchange do
    Log.new()
    |> append!(:system_message, %{content: "sys"})
    |> append!(:user_message, %{content: "u1"})
    |> append!(:step_start, %{})
    |> append!(:assistant_message, %{
      content: "",
      tool_calls: [%{"id" => "c1", "name" => "echo", "arguments" => %{}}]
    })
    |> append!(:tool_call, %{id: "c1", name: "echo"})
    |> append!(:tool_result, %{tool_call_id: "c1", name: "echo", content: "res"})
    |> append!(:assistant_message, %{content: "final"})
    |> append!(:step_end, %{})
  end

  describe "append/3 and seq" do
    test "seq is contiguous and equals the index for any append sequence" do
      types = [
        :user_message,
        :step_start,
        :assistant_message,
        :tool_call,
        :tool_result,
        :request_header,
        :turn_end
      ]

      log = Enum.reduce(types, Log.new(), &append!(&2, &1, %{content: "x"}))

      seqs = Enum.map(Log.events(log), & &1.seq)
      assert seqs == Enum.to_list(0..(length(types) - 1))
      assert Log.count(log) == length(types)
    end

    test "events/1 returns oldest first" do
      log =
        Log.new()
        |> append!(:user_message, %{content: "first"})
        |> append!(:user_message, %{content: "second"})

      assert Enum.map(Log.events(log), & &1.data.content) == ["first", "second"]
    end

    test "an unknown type is refused, not appended" do
      assert {:error, {:unknown_event_type, :nope}} = Log.append(Log.new(), :nope, %{})
    end

    test "a surface_op on a bookkeeping event is refused" do
      # A replace from an event the surface cannot see would shadow surface
      # events for a reason no fold could explain.
      assert {:error, {:surface_op_on_non_surface_event, :step_start}} =
               Log.append(Log.new(), :step_start, %{surface_op: {:replace, 0, 1}})
    end

    test "data holding a live-process handle is refused at append, not at persist" do
      assert {:error, {:unserializable_event_data, _}} =
               Log.append(Log.new(), :user_message, %{content: "x", pid: self()})

      assert {:error, {:unserializable_event_data, _}} =
               Log.append(Log.new(), :user_message, %{content: "x", nested: [%{ref: make_ref()}]})
    end

    test "a malformed surface_op is refused" do
      assert {:error, {:invalid_surface_op, _}} =
               Log.append(Log.new(), :user_message, %{content: "x", surface_op: {:replace, 5, 2}})

      assert {:error, {:invalid_surface_op, _}} =
               Log.append(Log.new(), :user_message, %{content: "x", surface_op: :nonsense})
    end

    test "append!/3 keeps the log unchanged on an invalid event rather than raising" do
      log = append!(Log.new(), :user_message, %{content: "ok"})

      kept =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:result, Log.append!(log, :nope, %{})})
        end)

      assert_received {:result, ^log}
      assert kept =~ "dropping invalid"
    end
  end

  describe "surface/1" do
    test "bookkeeping events are excluded" do
      surface_types = exchange() |> Log.surface() |> Enum.map(& &1.type)

      assert surface_types == [
               :system_message,
               :user_message,
               :assistant_message,
               :tool_result,
               :assistant_message
             ]
    end
  end

  describe "derive_messages/1" do
    test "projects the exchange to the message list a provider expects" do
      assert proj(Log.derive_messages(exchange())) == [
               {:system, "sys", nil, nil, []},
               {:user, "u1", nil, nil, []},
               {:assistant, "", nil, nil,
                [%{"id" => "c1", "name" => "echo", "arguments" => %{}}]},
               {:tool, "res", "c1", "echo", []},
               {:assistant, "final", nil, nil, []}
             ]
    end

    test "an assistant event with neither content nor tool calls IS derived" do
      # The plan called for dropping this from the fold, on the grounds that some
      # providers reject an empty assistant turn. That is a fact about what a
      # request may contain, not about what happened, and this fold is history.
      # Dropping it was a measurable D2 break: `Context.last_message/1` returned
      # the user message instead, output extraction found nothing, and a run whose
      # model replied with empty content — a content filter, a max_tokens cutoff, a
      # provider hiccup — turned from `{:ok, ""}` into `{:error, :no_output}`.
      log =
        append!(Log.new(), :assistant_message, %{
          content: "",
          metadata: %{usage: %{total_tokens: 7}}
        })

      assert [%Event{type: :assistant_message}] = Log.events(log)
      assert [%Message{role: :assistant, content: ""}] = Log.derive_messages(log)
    end

    test "reasoning content survives the projection" do
      log = append!(Log.new(), :assistant_message, %{content: "a", reasoning_content: "because"})

      assert [%Message{reasoning_content: "because"}] = Log.derive_messages(log)
    end
  end

  describe "replace: shadow without deleting" do
    setup do
      # Shadow the whole first exchange (seq 0..5), leaving the final assistant
      # message. The range is tool-pair balanced: it covers the assistant message
      # that made the call AND its result, so no orphan is produced.
      log =
        append!(exchange(), :system_message, %{
          content: "[summary of 0-5]",
          surface_op: {:replace, 0, 5}
        })

      {:ok, log: log}
    end

    test "the fold shows the summary and hides the shadowed range", %{log: log} do
      assert proj(Log.derive_messages(log)) == [
               {:system, "[summary of 0-5]", nil, nil, []},
               {:assistant, "final", nil, nil, []}
             ]
    end

    test "every original event is still there", %{log: log} do
      # This is the payoff: compaction stops destroying history.
      assert Log.count(log) == 9
      assert length(Log.events(log)) == 9
      assert Enum.any?(Log.events(log), &(&1.data[:content] == "u1"))
    end

    test "the summary takes the position of the range, not its append position", %{log: log} do
      # Appended last, but it replaces seq 0..5, so it belongs first. Ordering it
      # by append position would leave the transcript reading "here is the
      # conversation, and now a summary of what came before it".
      assert [%Message{role: :system, content: "[summary of 0-5]"} | _] = Log.derive_messages(log)
    end

    test "a replace cannot shadow events appended after it" do
      log =
        Log.new()
        |> append!(:user_message, %{content: "before"})
        |> append!(:system_message, %{content: "greedy", surface_op: {:replace, 0, 999}})
        |> append!(:user_message, %{content: "after"})

      contents = Enum.map(Log.derive_messages(log), & &1.content)

      assert "after" in contents
      refute "before" in contents
    end

    test "two successive replaces each land at their own range position" do
      log =
        Log.new()
        |> append!(:user_message, %{content: "a"})
        |> append!(:user_message, %{content: "b"})
        |> append!(:user_message, %{content: "c"})
        |> append!(:user_message, %{content: "d"})
        |> append!(:system_message, %{content: "sum-ab", surface_op: {:replace, 0, 1}})
        |> append!(:system_message, %{content: "sum-cd", surface_op: {:replace, 2, 3}})

      assert Enum.map(Log.derive_messages(log), & &1.content) == ["sum-ab", "sum-cd"]
    end

    test "a later replace shadows an earlier in-place replace inside its range" do
      # The gap this closes: pruning an oversized tool result in place is
      # `{:replace, s, s}` — a HIGH seq at a LOW position. A later summary names a
      # POSITION range, so if shadowing matched raw seqs the pruning event's own
      # seq would fall outside the range and its message would survive inside the
      # summarized region: an orphaned tool result whose assistant message was
      # shadowed, which every provider rejects.
      log =
        exchange()
        # Prune the tool result at seq 5 in place. Appended at seq 8, position 5.
        |> append!(:tool_result, %{
          tool_call_id: "c1",
          name: "echo",
          content: "res(pruned)",
          surface_op: {:replace, 5, 5}
        })
        # Now summarize positions 0..5, which must swallow the pruned result too.
        |> append!(:system_message, %{content: "[summary]", surface_op: {:replace, 0, 5}})

      assert proj(Log.derive_messages(log)) == [
               {:system, "[summary]", nil, nil, []},
               {:assistant, "final", nil, nil, []}
             ]

      # Nothing was deleted to achieve that.
      assert Log.count(log) == 10
    end

    test "compaction is repeatable: a second summary supersedes the first" do
      log =
        exchange()
        |> append!(:system_message, %{content: "[summary 1]", surface_op: {:replace, 0, 5}})
        |> append!(:user_message, %{content: "more"})
        |> append!(:system_message, %{content: "[summary 2]", surface_op: {:replace, 0, 6}})

      contents = Enum.map(Log.derive_messages(log), & &1.content)

      assert "[summary 2]" in contents
      refute "[summary 1]" in contents, "the first summary must not outlive its replacement"
      assert "more" in contents
    end
  end

  describe "fold memoization" do
    test "materialize/1 caches, a plain append extends the cache, a replace clears it" do
      {messages, warm} = Log.materialize(exchange())

      assert match?({_gen, _count, _messages}, warm.cache)
      assert Log.derive_messages(warm) == messages

      appended = append!(warm, :user_message, %{content: "next"})

      assert match?({_gen, _count, _messages}, appended.cache),
             "a plain append should extend the cache, not drop it"

      assert List.last(Log.derive_messages(appended)).content == "next"

      replaced = append!(warm, :system_message, %{content: "sum", surface_op: {:replace, 0, 1}})

      assert is_nil(replaced.cache), "a replace must invalidate the cache"
    end

    test "the fold is deterministic: two derivations are equal, structs and all" do
      # Every projection stamps `created_at` from the event's time rather than the
      # clock. Without that, `Message.system/1` and friends would stamp
      # `utc_now/0` on every fold, so re-materializing after each append would
      # rewrite every message's timestamp to the moment of the last append — and
      # no two folds of the same log could ever compare equal.
      log = exchange()

      assert Log.derive_messages(log) == Log.derive_messages(log)

      times = log |> Log.derive_messages() |> Enum.map(& &1.created_at)
      event_times = log |> Log.surface() |> Enum.map(& &1.time)

      # Surface events and derived messages line up 1:1 here (no empty assistant
      # turn in `exchange/0`), so the timestamps must be exactly the event times.
      assert times == event_times
    end

    test "seeding is lossless: the fold returns the input structs, timestamps included" do
      # Not just shape-equal — struct-equal. `Nous.Agent.Context.new(messages: …)`
      # seeds through here, so anything the fold drops is history the caller handed
      # us and we quietly rewrote.
      messages = [
        Message.system("sys"),
        Message.user("hi"),
        Message.assistant("", tool_calls: [%{"id" => "1", "name" => "t", "arguments" => %{}}]),
        Message.tool("1", "r", name: "t"),
        Message.assistant("done")
      ]

      # A gap between construction and seeding: if `seed/1` re-stamped the event
      # times, every timestamp would move and this would fail.
      Process.sleep(5)

      assert messages |> Log.seed() |> Log.derive_messages() == messages
    end

    test "a multimodal message keeps its content parts through the fold" do
      # `Message.user/1` given ContentParts keeps flattened text in `content` and
      # the real parts in `metadata.content_parts`, which is where all three
      # provider adapters read them from. A fold that dropped metadata would strip
      # the images from a vision run while everything still appeared to work.
      parts = [ContentPart.text("look"), ContentPart.image_url("https://example.com/y.png")]
      vision = Message.user(parts)

      assert [folded] = [vision] |> Log.seed() |> Log.derive_messages()
      assert folded == vision
      assert length(folded.metadata.content_parts) == 2
    end

    test "name survives the fold for every role that can carry one" do
      messages = [
        Message.system("s") |> Map.put(:name, "sys-name"),
        Message.user("u") |> Map.put(:name, "user-name"),
        Message.tool("1", "r", name: "tool-name")
      ]

      folded = messages |> Log.seed() |> Log.derive_messages()

      assert Enum.map(folded, & &1.name) == ["sys-name", "user-name", "tool-name"]
    end

    test "the cache never disagrees with a fresh fold" do
      # A stale cache is the failure mode that would make `ctx.messages` and the
      # log diverge, which is exactly what D2 forbids.
      log = exchange()
      {_messages, warm} = Log.materialize(log)

      warm = append!(warm, :user_message, %{content: "x"})
      {_m, warm} = Log.materialize(warm)
      warm = append!(warm, :system_message, %{content: "s", surface_op: {:replace, 1, 2}})
      {_m, warm} = Log.materialize(warm)

      assert Log.derive_messages(warm) == Log.derive_messages(%{warm | cache: nil})
    end
  end

  describe "seed/1" do
    test "a flat message list round-trips through the log" do
      messages = [
        Message.system("s"),
        Message.user("u"),
        Message.assistant("", tool_calls: [%{"id" => "1", "name" => "t", "arguments" => %{}}]),
        Message.tool("1", "r", name: "t"),
        Message.assistant("done")
      ]

      assert proj(messages |> Log.seed() |> Log.derive_messages()) == proj(messages)
    end

    test "one surface event per seeded message, in order" do
      messages = [Message.system("s"), Message.user("u"), Message.assistant("a")]
      log = Log.seed(messages)

      assert Enum.map(Log.events(log), & &1.type) == [
               :system_message,
               :user_message,
               :assistant_message
             ]

      assert Enum.map(Log.events(log), & &1.seq) == [0, 1, 2]
    end

    test "an empty list seeds an empty log" do
      assert Log.seed([]) |> Log.events() == []
    end
  end
end

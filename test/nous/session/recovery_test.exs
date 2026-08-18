defmodule Nous.Session.RecoveryTest do
  # async: true — nothing here touches application env. Every pubsub test below
  # sets `pubsub`/`pubsub_topic` on the struct explicitly rather than relying on
  # `:nous, :pubsub`, which `pubsub_test.exs` mutates.
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Session.Log
  alias Nous.Session.Recovery

  doctest Nous.Session.Recovery

  defp append!(log, type, data), do: Log.append!(log, type, data)

  defp call(id, name), do: %{"id" => id, "name" => name}

  # A crash inside step 2 of turn 1, with the log recording dispatches.
  #
  #   c1 — dispatched and answered            -> nothing owed
  #   c2 — never dispatched, and this turn DOES log dispatches for its siblings,
  #        so the silence is evidence           -> :tool_not_started
  #   c3 — dispatched, no result, step never closed -> :tool_outcome_unknown
  defp crashed_with_dispatch_log do
    Log.new()
    |> append!(:user_message, %{content: "do two things"})
    |> append!(:turn_start, %{turn: 1})
    |> append!(:step_start, %{turn: 1, step: 1})
    |> append!(:assistant_message, %{
      content: "",
      tool_calls: [call("c1", "echo"), call("c2", "echo")]
    })
    |> append!(:tool_call, %{id: "c1", name: "echo"})
    |> append!(:tool_result, %{tool_call_id: "c1", name: "echo", content: "ok"})
    |> append!(:step_end, %{turn: 1, step: 1, outcome: :ok})
    |> append!(:step_start, %{turn: 1, step: 2})
    |> append!(:assistant_message, %{content: "", tool_calls: [call("c3", "write")]})
    |> append!(:tool_call, %{id: "c3", name: "write"})
  end

  # The same crash on a log whose emitter writes no `:tool_call` events at all —
  # which is every log this codebase produces today. The step boundary is then
  # the only fact available.
  #
  #   d1 — its step closed, so nothing was in flight -> :tool_not_started
  #   d2 — its step never closed                     -> :tool_outcome_unknown
  defp crashed_without_dispatch_log do
    Log.new()
    |> append!(:turn_start, %{turn: 4})
    |> append!(:step_start, %{turn: 4, step: 1})
    |> append!(:assistant_message, %{content: "", tool_calls: [call("d1", "read")]})
    |> append!(:step_end, %{turn: 4, step: 1, outcome: :error})
    |> append!(:step_start, %{turn: 4, step: 2})
    |> append!(:assistant_message, %{content: "", tool_calls: [call("d2", "read")]})
  end

  defp clean_log do
    Log.new()
    |> append!(:user_message, %{content: "hi"})
    |> append!(:turn_start, %{turn: 1})
    |> append!(:step_start, %{turn: 1, step: 1})
    |> append!(:assistant_message, %{content: "", tool_calls: [call("c1", "echo")]})
    |> append!(:tool_call, %{id: "c1", name: "echo"})
    |> append!(:tool_result, %{tool_call_id: "c1", name: "echo", content: "ok"})
    |> append!(:step_end, %{turn: 1, step: 1, outcome: :ok})
    |> append!(:assistant_message, %{content: "done"})
    |> append!(:turn_end, %{turn: 1, steps: 1, reason: :complete})
  end

  defp synthetic(log) do
    log
    |> Log.events()
    |> Enum.filter(
      &(&1.type == :tool_result and get_in(&1.data, [:metadata, :synthetic]) == true)
    )
  end

  defp risks(log) do
    Map.new(synthetic(log), &{&1.data.tool_call_id, &1.data.metadata.risk})
  end

  describe "interrupted?/1 and open_turns/1" do
    test "an orphaned turn_start is the crash signal; a closed one is not" do
      assert Recovery.interrupted?(crashed_with_dispatch_log())
      refute Recovery.interrupted?(clean_log())
    end

    test "a log with no turn events at all is never interrupted" do
      log =
        Log.new()
        |> append!(:user_message, %{content: "hi"})
        |> append!(:assistant_message, %{content: "", tool_calls: [call("c1", "echo")]})

      refute Recovery.interrupted?(log)
      assert Recovery.plan(log) == []
    end

    test "open_turns/1 names the turn_start that never closed" do
      assert [orphan] = Recovery.open_turns(crashed_with_dispatch_log())
      assert orphan.type == :turn_start
      assert orphan.seq == 1
    end

    test "reads a context and a raw event list as well as a log" do
      log = crashed_with_dispatch_log()
      {:ok, ctx} = Context.deserialize(%{version: 1, messages: []})
      ctx = %{ctx | log: log, messages: Log.derive_messages(log)}

      assert Recovery.interrupted?(ctx)
      assert Recovery.interrupted?(Log.events(log))
      assert Recovery.plan(Log.events(log)) == Recovery.plan(log)
    end
  end

  describe "repairing an orphaned turn" do
    test "appends paired synthetic results and an :interrupted turn end" do
      recovered = Recovery.recover(crashed_with_dispatch_log())
      appended = Enum.drop(Log.events(recovered), 10)

      assert Enum.map(appended, & &1.type) == [:tool_result, :tool_result, :turn_end]

      # Exactly one synthetic result per owed call, and none for the call that
      # already had a real one.
      assert Enum.map(synthetic(recovered), & &1.data.tool_call_id) == ["c2", "c3"]
      assert Enum.count(Log.events(recovered), &(&1.type == :tool_result)) == 3
    end

    test "every owed call gets exactly one result, and no owed call is missed" do
      recovered = Recovery.recover(crashed_with_dispatch_log())

      called =
        recovered
        |> Log.events()
        |> Enum.filter(&(&1.type == :assistant_message))
        |> Enum.flat_map(&Enum.map(&1.data.tool_calls, fn c -> c["id"] end))

      answered =
        recovered
        |> Log.events()
        |> Enum.filter(&(&1.type == :tool_result))
        |> Enum.map(& &1.data.tool_call_id)

      assert Enum.sort(called) == Enum.sort(answered)
      assert Enum.uniq(answered) == answered
    end

    test "risk is :tool_not_started when the turn logs dispatches and this call has none" do
      assert risks(Recovery.recover(crashed_with_dispatch_log())) == %{
               "c2" => :tool_not_started,
               "c3" => :tool_outcome_unknown
             }
    end

    test "with no dispatch bookkeeping, a closed step means not started and an open one unknown" do
      assert risks(Recovery.recover(crashed_without_dispatch_log())) == %{
               "d1" => :tool_not_started,
               "d2" => :tool_outcome_unknown
             }
    end

    test "the two classes carry different text, because a human reads it" do
      [not_started, unknown] = synthetic(Recovery.recover(crashed_without_dispatch_log()))

      assert not_started.data.content =~ "did not run and had no side effects"
      assert unknown.data.content =~ "MAY have run"
      refute unknown.data.content =~ "no side effects"
    end

    test "the synthetic turn end carries :interrupted plus the turn's own numbers" do
      recovered = Recovery.recover(crashed_with_dispatch_log())
      turn_end = List.last(Log.events(recovered))

      assert turn_end.type == :turn_end
      assert turn_end.data == %{turn: 1, steps: 2, reason: :interrupted}
    end

    test "a turn with zero steps still closes, and reports zero steps" do
      recovered =
        Log.new()
        |> append!(:turn_start, %{turn: 7})
        |> Recovery.recover()

      assert [_start, turn_end] = Log.events(recovered)
      assert turn_end.data == %{turn: 7, steps: 0, reason: :interrupted}
    end

    test "an orphan whose turn_start carries no number omits it rather than inventing one" do
      recovered = Log.new() |> append!(:turn_start, %{}) |> Recovery.recover()

      assert [_start, turn_end] = Log.events(recovered)
      assert turn_end.data == %{steps: 0, reason: :interrupted}
    end

    test "a call recorded outside any turn is left to patch_dangling_tool_calls/1" do
      log =
        Log.new()
        |> append!(:assistant_message, %{content: "", tool_calls: [call("loose", "echo")]})
        |> append!(:turn_start, %{turn: 1})

      recovered = Recovery.recover(log)

      assert synthetic(recovered) == []

      assert Enum.map(Log.events(recovered), & &1.type) == [
               :assistant_message,
               :turn_start,
               :turn_end
             ]
    end
  end

  describe "recovery never destroys" do
    test "appends only: every original event survives, in order, with its seq" do
      log = crashed_with_dispatch_log()
      original = Log.events(log)

      recovered = Recovery.recover(log)

      assert Enum.take(Log.events(recovered), length(original)) == original
      assert Enum.map(Log.events(recovered), & &1.seq) == Enum.to_list(0..12)
    end

    # `IterationLoop.turn_cursor/1` derives the next turn number by counting
    # `:turn_start` events, so recovery must close a turn without opening one.
    # A repair that appended its own `:turn_start` would renumber every turn
    # after a crash, and the log would disagree with itself about which turn a
    # step belonged to.
    test "recovery closes a turn without opening one, so turn numbering is unshifted" do
      log = crashed_with_dispatch_log()
      starts = fn l -> Enum.count(Log.events(l), &(&1.type == :turn_start)) end

      recovered = Recovery.recover(log)

      assert starts.(recovered) == starts.(log)
      assert Enum.count(Log.events(recovered), &(&1.type == :turn_end)) == 1
    end

    test "a clean log is untouched — no synthetic events at all" do
      log = clean_log()

      assert Recovery.plan(log) == []
      assert Log.events(Recovery.recover(log)) == Log.events(log)
    end

    test "a clean log with a dangling call is still untouched: a closed turn is not a crash" do
      log =
        clean_log()
        |> append!(:turn_start, %{turn: 2})
        |> append!(:assistant_message, %{content: "", tool_calls: [call("late", "echo")]})
        |> append!(:turn_end, %{turn: 2, steps: 0, reason: :complete})

      assert Recovery.plan(log) == []
    end

    test "a turn_end closing nothing is reported, not silently absorbed" do
      log = append!(clean_log(), :turn_end, %{turn: 9, reason: :complete})

      logged = ExUnit.CaptureLog.capture_log(fn -> assert Recovery.plan(log) == [] end)

      assert logged =~ ":turn_end at seq 9 closes no open turn"
    end

    test "recovery is idempotent" do
      once = Recovery.recover(crashed_with_dispatch_log())
      twice = Recovery.recover(once)

      assert Recovery.plan(once) == []
      assert Log.events(twice) == Log.events(once)
      refute Recovery.interrupted?(once)
    end

    test "plan/1 reports without mutating" do
      log = crashed_with_dispatch_log()

      assert length(Recovery.plan(log)) == 3
      assert Log.count(log) == 10
    end

    test "a real result already in the log is never duplicated by a synthetic one" do
      log =
        append!(crashed_with_dispatch_log(), :tool_result, %{
          tool_call_id: "c3",
          content: "landed"
        })

      assert Enum.map(synthetic(Recovery.recover(log)), & &1.data.tool_call_id) == ["c2"]
    end
  end

  # The claim this block defends: recovery dispatches on the event TYPE only, so
  # a persisted blob whose atoms came back as strings cannot change the outcome.
  # Types survive through a literal whitelist; `reason` and `metadata.risk` do
  # not survive JSON as atoms, and deliberately do not need to.
  describe "surviving persistence" do
    setup do
      log = crashed_without_dispatch_log()
      {:ok, ctx} = Context.deserialize(%{version: 1, messages: []})
      %{recovered: Recovery.recover(%{ctx | log: log, messages: Log.derive_messages(log)})}
    end

    test "a term-preserving backend keeps the atoms", %{recovered: recovered} do
      {:ok, reloaded} = recovered |> Context.serialize() |> Context.deserialize()

      assert List.last(Log.events(reloaded.log)).data.reason == :interrupted
      assert Recovery.plan(reloaded) == []
    end

    test "a JSON backend stringifies them, and recovery stays a no-op anyway",
         %{recovered: recovered} do
      {:ok, reloaded} =
        recovered
        |> Context.serialize()
        |> JSON.encode!()
        |> JSON.decode!()
        |> Context.deserialize()

      turn_end = List.last(Log.events(reloaded.log))
      assert turn_end.type == :turn_end
      assert turn_end.data.reason == "interrupted"

      refute Recovery.interrupted?(reloaded)
      assert Recovery.plan(reloaded) == []
      assert Log.count(Recovery.recover(reloaded).log) == Log.count(reloaded.log)
    end

    test "the risk class reaches a reader on both sides of a JSON trip",
         %{recovered: recovered} do
      blob = Context.serialize(recovered)
      {:ok, terms} = Context.deserialize(blob)
      {:ok, json} = blob |> JSON.encode!() |> JSON.decode!() |> Context.deserialize()

      assert risk_pairs(terms, :risk) == [
               {"d1", :tool_not_started},
               {"d2", :tool_outcome_unknown}
             ]

      assert risk_pairs(json, "risk") == [
               {"d1", "tool_not_started"},
               {"d2", "tool_outcome_unknown"}
             ]
    end

    defp risk_pairs(ctx, key) do
      for message <- ctx.messages, message.role == :tool do
        {message.tool_call_id, message.metadata[key]}
      end
    end
  end

  describe "recovering a context" do
    setup do
      log = crashed_with_dispatch_log()
      {:ok, ctx} = Context.deserialize(%{version: 1, messages: []})
      %{ctx: %{ctx | log: log, messages: Log.derive_messages(log)}}
    end

    test "synthetic results reach messages and the fold stays in lockstep", %{ctx: ctx} do
      recovered = Recovery.recover(ctx)

      assert recovered.messages == Log.derive_messages(recovered.log)

      tools = Enum.filter(recovered.messages, &(&1.role == :tool))
      assert Enum.map(tools, & &1.tool_call_id) == ["c1", "c2", "c3"]

      assert Enum.map(tools, &get_in(&1.metadata, [:risk])) ==
               [nil, :tool_not_started, :tool_outcome_unknown]
    end

    test "the turn end is bookkeeping: it projects to no message", %{ctx: ctx} do
      recovered = Recovery.recover(ctx)

      assert List.last(Log.events(recovered.log)).type == :turn_end
      assert length(recovered.messages) == length(ctx.messages) + 2
    end

    test "repairing does not decide to resume: needs_response is preserved", %{ctx: ctx} do
      assert Recovery.recover(%{ctx | needs_response: false}).needs_response == false
      assert Recovery.recover(%{ctx | needs_response: true}).needs_response == true
    end

    test "a clean context comes back identical", %{ctx: ctx} do
      clean = %{ctx | log: clean_log(), messages: Log.derive_messages(clean_log())}

      assert Recovery.recover(clean) == clean
    end

    test "patch_dangling_tool_calls/1 finds nothing after recovery", %{ctx: ctx} do
      recovered = Recovery.recover(ctx)
      patched = Context.patch_dangling_tool_calls(recovered)

      assert patched.messages == recovered.messages
      assert Log.count(patched.log) == Log.count(recovered.log)
    end

    test "the fast path alone would answer the same calls, but without the classification",
         %{ctx: ctx} do
      patched = Context.patch_dangling_tool_calls(ctx)

      answered =
        patched.messages
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.map(& &1.tool_call_id)
        |> Enum.sort()

      assert answered == ["c1", "c2", "c3"]
      # Turn-blind, so it neither classifies the risk nor closes the turn.
      assert Enum.all?(Enum.filter(patched.messages, &(&1.role == :tool)), &(&1.metadata == %{}))
      assert Recovery.interrupted?(patched)
    end
  end

  # These live here rather than in a file of their own because a committed event
  # is exactly what both halves are about: recovery *commits* the synthetic
  # events, and the publish hook is the contract that every commit — surface or
  # bookkeeping — reaches a subscriber exactly once. The last test in this block
  # ties the two together directly.
  describe "publishing committed events" do
    setup do
      name = :"recovery_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: name})
      topic = "nous:agent:#{System.unique_integer([:positive])}"
      :ok = Nous.PubSub.subscribe(name, topic)
      %{pubsub: name, topic: topic}
    end

    defp wired(pubsub, topic) do
      %{Context.new() | pubsub: pubsub, pubsub_topic: topic}
    end

    test "appending N messages broadcasts N events and nothing else", %{pubsub: p, topic: t} do
      ctx =
        p
        |> wired(t)
        |> Context.add_message(Message.user("one"))
        |> Context.add_message(Message.assistant("two"))
        |> Context.add_message(Message.user("three"))

      assert_receive {:session_event, %{seq: 0, type: :user_message}}
      assert_receive {:session_event, %{seq: 1, type: :assistant_message}}
      assert_receive {:session_event, %{seq: 2, type: :user_message}}
      refute_receive {:session_event, _}, 50

      assert length(ctx.messages) == 3
    end

    test "one bookkeeping event broadcasts exactly one event", %{pubsub: p, topic: t} do
      p |> wired(t) |> Context.log_event(:turn_start, %{turn: 1})

      assert_receive {:session_event, %{seq: 0, type: :turn_start, data: %{turn: 1}}}
      refute_receive {:session_event, _}, 50
    end

    test "add_messages/2 publishes each event once", %{pubsub: p, topic: t} do
      p
      |> wired(t)
      |> Context.add_messages([Message.user("a"), Message.assistant("b")])

      assert_receive {:session_event, %{seq: 0}}
      assert_receive {:session_event, %{seq: 1}}
      refute_receive {:session_event, _}, 50
    end

    test "re-materializing without appending publishes nothing", %{pubsub: p, topic: t} do
      ctx = Context.add_message(wired(p, t), Message.user("one"))
      assert_receive {:session_event, %{seq: 0}}

      # put_system_prompt_overlay/2 re-materializes the same log. So does the
      # sync/1 path a hand-built `messages` triggers, where the re-seeded log
      # ends up no longer than the one it replaced.
      ctx = Context.put_system_prompt_overlay(ctx, "extra")
      Context.add_message(%{ctx | messages: [Message.user("one")]}, Message.user("two"))

      assert_receive {:session_event, %{seq: 1, type: :user_message}}
      refute_receive {:session_event, _}, 50
    end

    test "publishing is a no-op with no pubsub, and with no topic", %{pubsub: p, topic: t} do
      Context.add_message(%{Context.new() | pubsub: nil, pubsub_topic: t}, Message.user("one"))
      Context.add_message(%{Context.new() | pubsub: p, pubsub_topic: nil}, Message.user("one"))

      refute_receive {:session_event, _}, 50
    end

    test "a broadcast that raises does not break the append", %{topic: t} do
      # `NotAPubSub` has no Phoenix.PubSub registry, so `Phoenix.PubSub.broadcast/3`
      # raises ArgumentError from inside the publish hook. The append must still
      # land. (The hook additionally catches `exit`/`throw`, which only a custom
      # third-party adapter can produce — `Nous.PubSub.broadcast/3` already
      # swallows the whole `:error` class exercised here.)
      ctx =
        %{Context.new() | pubsub: NotAPubSub, pubsub_topic: t}
        |> Context.add_message(Message.user("one"))
        |> Context.log_event(:turn_start, %{turn: 1})

      assert Enum.map(ctx.messages, & &1.content) == ["one"]
      assert Log.count(ctx.log) == 2
    end

    test "recovery's synthetic events are published like any other commit",
         %{pubsub: p, topic: t} do
      log = crashed_without_dispatch_log()
      ctx = %{wired(p, t) | log: log, messages: Log.derive_messages(log)}

      Recovery.recover(ctx)

      assert_receive {:session_event, %{type: :tool_result, data: %{tool_call_id: "d1"}}}
      assert_receive {:session_event, %{type: :tool_result, data: %{tool_call_id: "d2"}}}
      assert_receive {:session_event, %{type: :turn_end, data: %{reason: :interrupted}}}
      refute_receive {:session_event, _}, 50
    end
  end
end

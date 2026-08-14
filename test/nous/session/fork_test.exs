defmodule Nous.Session.ForkTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Session
  alias Nous.Session.Log
  alias Nous.Session.Recovery

  doctest Nous.Session

  defp append!(log, type, data), do: Log.append!(log, type, data)

  defp call(id, name), do: %{"id" => id, "name" => name}

  # Two complete turns, then a third that opened and never closed. Turn 1 ends
  # at seq 5, turn 2 at seq 9, turn 3 opens at seq 10.
  defp two_turns_then_a_crash do
    Log.new()
    |> append!(:system_message, %{content: "sys"})
    |> append!(:turn_start, %{turn: 1})
    |> append!(:user_message, %{content: "one"})
    |> append!(:step_start, %{turn: 1, step: 1})
    |> append!(:assistant_message, %{content: "first"})
    |> append!(:step_end, %{turn: 1, step: 1, outcome: :ok})
    |> append!(:turn_end, %{turn: 1, steps: 1, reason: :complete})
    |> append!(:turn_start, %{turn: 2})
    |> append!(:user_message, %{content: "two"})
    |> append!(:assistant_message, %{content: "second"})
    |> append!(:turn_end, %{turn: 2, steps: 0, reason: :rejected})
    |> append!(:turn_start, %{turn: 3})
    |> append!(:user_message, %{content: "three"})
    |> append!(:assistant_message, %{content: "", tool_calls: [call("c9", "write")]})
  end

  defp parent_session, do: Session.new(id: "parent", log: two_turns_then_a_crash())

  describe "new/1 and from_context/2" do
    test "generates an id and starts empty" do
      session = Session.new()

      assert byte_size(session.id) == 32
      assert Log.count(session.log) == 0
      assert session.parent == nil
    end

    test "from_context/2 takes a handle on the context's own log" do
      ctx = Context.new(messages: [Message.user("hi"), Message.assistant("yo")])
      session = Session.from_context(ctx, id: "s1")

      assert session.id == "s1"
      assert session.log == ctx.log
      assert Log.derive_messages(session.log) == ctx.messages
    end
  end

  describe "fork/2 at a clean boundary" do
    test "copies the prefix and records parent and seed length" do
      {:ok, fork} = Session.fork(parent_session(), 6)

      assert fork.parent == %{session_id: "parent", seed_length: 7}
      assert Log.count(fork.log) == 7
      assert fork.id != "parent"
    end

    test "the fork's fold equals the prefix's fold" do
      parent = parent_session()
      {:ok, fork} = Session.fork(parent, 6)

      prefix_fold =
        parent.log
        |> Log.events()
        |> Enum.take(7)
        |> Enum.reduce(Log.new(), &Log.append!(&2, &1.type, &1.data, &1.time))
        |> Log.derive_messages()

      assert Log.derive_messages(fork.log) == prefix_fold
      assert Enum.map(Log.derive_messages(fork.log), & &1.content) == ["sys", "one", "first"]
    end

    test "copied events keep their seq, type, time and data" do
      parent = parent_session()
      {:ok, fork} = Session.fork(parent, 6)

      assert Log.events(fork.log) == Enum.take(Log.events(parent.log), 7)
    end

    test "the fork continues numbering where the inheritance stopped" do
      {:ok, fork} = Session.fork(parent_session(), 6)
      log = Log.append!(fork.log, :user_message, %{content: "mine"})

      assert List.last(Log.events(log)).seq == fork.parent.seed_length
    end

    test "a boundary at seq 0 inherits exactly one event" do
      {:ok, fork} = Session.fork(parent_session(), 0)

      assert fork.parent.seed_length == 1
      assert Enum.map(Log.derive_messages(fork.log), & &1.content) == ["sys"]
    end

    test "a compaction range survives the copy, so the fork folds compacted" do
      log =
        Log.new()
        |> append!(:user_message, %{content: "one"})
        |> append!(:assistant_message, %{content: "two"})
        |> append!(:system_message, %{content: "summary", surface_op: {:replace, 0, 1}})

      {:ok, fork} = Session.fork(Session.new(id: "p", log: log), :last)

      assert Enum.map(Log.derive_messages(fork.log), & &1.content) == ["summary"]
      assert Log.count(fork.log) == 3
    end

    test "forking an empty log is legal and yields an empty fork" do
      {:ok, fork} = Session.fork(Session.new(id: "p"), :last)

      assert fork.parent == %{session_id: "p", seed_length: 0}
      assert Log.count(fork.log) == 0
    end

    test "a fork can be forked, and points at its immediate parent" do
      {:ok, first} = Session.fork(parent_session(), 6)
      {:ok, second} = Session.fork(first, :last)

      assert second.parent == %{session_id: first.id, seed_length: 7}
    end
  end

  describe "fork/2 refuses a boundary inside an open turn" do
    test "a boundary between a turn_start and its turn_end is an error" do
      assert {:error, {:open_turn, 11}} = Session.fork(parent_session(), 12)
      assert {:error, {:open_turn, 11}} = Session.fork(parent_session(), 11)
    end

    test "the turn_start itself is inside its own turn" do
      log = append!(Log.new(), :turn_start, %{turn: 1})

      assert {:error, {:open_turn, 0}} = Session.fork(Session.new(log: log), 0)
    end

    test ":last on a log ending in an open turn errors rather than clipping" do
      assert {:error, {:open_turn, 11}} = Session.fork(parent_session(), :last)
    end

    test "the boundary just before a turn opens is clean" do
      assert {:ok, fork} = Session.fork(parent_session(), 10)
      assert fork.parent.seed_length == 11
      assert Recovery.open_turns(Log.events(fork.log)) == []
    end

    test "recovering first makes :last legal, and the fork inherits the repair" do
      parent = %{parent_session() | log: Recovery.recover(two_turns_then_a_crash())}

      assert {:ok, fork} = Session.fork(parent, :last)

      types = Enum.map(Log.events(fork.log), & &1.type)
      assert List.last(types) == :turn_end
      assert List.last(Log.events(fork.log)).data.reason == :interrupted
      assert Enum.count(types, &(&1 == :tool_result)) == 1
    end
  end

  describe "fork/2 rejects a boundary it cannot honour" do
    test "a seq past the end of the log is out of range, not silently the end" do
      assert {:error, {:boundary_out_of_range, 14, 14}} = Session.fork(parent_session(), 14)
      assert {:error, {:boundary_out_of_range, 0, 0}} = Session.fork(Session.new(), 0)
    end

    test "a boundary that is neither a seq nor :last is rejected" do
      assert {:error, {:invalid_boundary, :first}} = Session.fork(parent_session(), :first)
      assert {:error, {:invalid_boundary, -1}} = Session.fork(parent_session(), -1)
    end
  end

  describe "to_context/1" do
    test "rebuilds a runnable context whose messages match the fold" do
      {:ok, fork} = Session.fork(parent_session(), 6)
      {:ok, ctx} = Session.to_context(fork)

      assert ctx.messages == Log.derive_messages(fork.log)
      assert Log.events(ctx.log) == Log.events(fork.log)
    end

    test "bookkeeping events survive the trip, so the fork stays turn-aware" do
      {:ok, fork} = Session.fork(parent_session(), 6)
      {:ok, ctx} = Session.to_context(fork)

      assert Enum.count(Log.events(ctx.log), &(&1.type == :turn_start)) == 1
      refute Recovery.interrupted?(ctx)
    end

    test "an interrupted session round-trips still interrupted, and recovers after" do
      session = Session.new(id: "crashed", log: two_turns_then_a_crash())
      {:ok, ctx} = Session.to_context(session)

      assert Recovery.interrupted?(ctx)

      recovered = Recovery.recover(ctx)
      refute Recovery.interrupted?(recovered)
      assert Enum.any?(recovered.messages, &(&1.role == :tool and &1.tool_call_id == "c9"))
    end

    test "runtime-only fields come back empty, as for any restored context" do
      {:ok, ctx} = Session.to_context(Session.new(id: "s", log: two_turns_then_a_crash()))

      assert ctx.pubsub == nil
      assert ctx.pubsub_topic == nil
      assert ctx.notify_pid == nil
    end
  end
end

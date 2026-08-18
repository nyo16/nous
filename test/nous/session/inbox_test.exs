defmodule Nous.Session.InboxTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Session.{Event, Inbox}

  doctest Nous.Session.Inbox

  defp contents(messages), do: Enum.map(messages, & &1.content)

  describe "send/4" do
    test "normalizes a binary into a user message and keeps a %Message{} as it was" do
      pinned = Message.user("pinned", name: "operator")

      inbox =
        Inbox.new()
        |> Inbox.send("plain", :next_step, false)
        |> Inbox.send(pinned, :next_step, false)

      {[from_binary, from_struct], _inbox} = Inbox.claim(inbox, :next_step)

      assert %Message{role: :user, content: "plain"} = from_binary
      # Re-wrapping would silently drop name/metadata (an image-carrying message
      # would lose its content_parts), so the struct must pass through untouched.
      assert from_struct == pinned
    end

    test "is FIFO within a queue" do
      inbox =
        Enum.reduce(["a", "b", "c"], Inbox.new(), fn text, inbox ->
          Inbox.send(inbox, text, :next_step, false)
        end)

      {claimed, _inbox} = Inbox.claim(inbox, :next_step)
      assert contents(claimed) == ["a", "b", "c"]
    end

    test "is FIFO independently in each queue" do
      inbox =
        Inbox.new()
        |> Inbox.send("turn 1", :next_turn, true)
        |> Inbox.send("step 1", :next_step, true)
        |> Inbox.send("turn 2", :next_turn, true)
        |> Inbox.send("step 2", :next_step, true)

      {turn, inbox} = Inbox.claim(inbox, :next_turn)
      {step, _inbox} = Inbox.claim(inbox, :next_step)

      assert contents(turn) == ["turn 1", "turn 2"]
      assert contents(step) == ["step 1", "step 2"]
    end
  end

  describe "presets" do
    test "followup/2 is next_turn + wake" do
      inbox = Inbox.followup(Inbox.new(), "later")

      assert [%{wakeup: true}] = inbox.next_turn
      assert inbox.next_step == []
    end

    test "steer/2 is next_step + wake" do
      inbox = Inbox.steer(Inbox.new(), "now")

      assert [%{wakeup: true}] = inbox.next_step
      assert inbox.next_turn == []
    end

    test "inject/2 is next_step + NO wake" do
      inbox = Inbox.inject(Inbox.new(), "context")

      assert [%{wakeup: false}] = inbox.next_step
      assert inbox.next_turn == []
    end
  end

  describe "wake?/1" do
    test "is false when only injections are queued" do
      inbox = Inbox.new() |> Inbox.inject("one") |> Inbox.inject("two")

      assert Inbox.pending?(inbox)
      refute Inbox.wake?(inbox)
    end

    test "is true when any queued entry asked for a wake, in either queue" do
      assert Inbox.new() |> Inbox.inject("a") |> Inbox.steer("b") |> Inbox.wake?()
      assert Inbox.new() |> Inbox.inject("a") |> Inbox.followup("b") |> Inbox.wake?()
    end

    test "an empty inbox never wakes anything" do
      refute Inbox.wake?(Inbox.new())
      refute Inbox.pending?(Inbox.new())
      assert Inbox.count(Inbox.new()) == 0
    end

    test "survives its queue being drained: claiming removes the wake intent" do
      inbox = Inbox.steer(Inbox.new(), "go")
      assert Inbox.wake?(inbox)

      {_claimed, inbox} = Inbox.claim(inbox, :next_step)
      refute Inbox.wake?(inbox)
    end

    test "a steer in the OTHER queue still wakes after this one is drained" do
      # This is the case a `wakeRequested` latch exists to cover upstream: a
      # message that outlives the boundary that would have claimed it must still
      # be able to start a run.
      inbox = Inbox.new() |> Inbox.steer("step") |> Inbox.followup("turn")

      {_claimed, inbox} = Inbox.claim(inbox, :next_step)

      assert Inbox.wake?(inbox)
      assert Inbox.pending?(inbox, :next_turn)
    end
  end

  describe "claim/2" do
    test "drains only its own queue and leaves the rest" do
      inbox = Inbox.new() |> Inbox.followup("turn") |> Inbox.steer("step")

      {claimed, inbox} = Inbox.claim(inbox, :next_step)

      assert contents(claimed) == ["step"]
      refute Inbox.pending?(inbox, :next_step)
      assert Inbox.pending?(inbox, :next_turn)
      assert Inbox.count(inbox) == 1
    end

    test "a second claim of the same queue is empty" do
      inbox = Inbox.steer(Inbox.new(), "once")

      {first, inbox} = Inbox.claim(inbox, :next_step)
      {second, _inbox} = Inbox.claim(inbox, :next_step)

      assert contents(first) == ["once"]
      assert second == []
    end

    test "claiming an empty queue is a no-op" do
      inbox = Inbox.followup(Inbox.new(), "turn")

      assert {[], ^inbox} = Inbox.claim(inbox, :next_step)
    end

    test "with both queues populated, the turn claim precedes the step claim" do
      # The documented rule: the queues are never merged and never compete. A
      # run drains next_turn when the turn opens and next_step at each step
      # boundary, so turn messages reach the transcript ahead of step messages
      # regardless of the order they were sent in.
      inbox =
        Inbox.new()
        |> Inbox.steer("sent first, for the next step")
        |> Inbox.followup("sent second, for the next turn")

      {turn_batch, inbox} = Inbox.claim(inbox, :next_turn)
      {step_batch, inbox} = Inbox.claim(inbox, :next_step)

      assert contents(turn_batch) == ["sent second, for the next turn"]
      assert contents(step_batch) == ["sent first, for the next step"]
      refute Inbox.pending?(inbox)
    end
  end

  describe "serializability" do
    test "survives a term round trip unchanged" do
      inbox =
        Inbox.new()
        |> Inbox.followup("turn")
        |> Inbox.steer("step")
        |> Inbox.inject(Message.user("context", metadata: %{source: "test"}))

      round_tripped = inbox |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert round_tripped == inbox
    end

    test "is accepted as event data, i.e. holds no pids, refs, ports or funs" do
      # Event.new/4 validates serializability at append time. Asserting through
      # it — rather than eyeballing the struct — is what pins the reason the
      # inbox queues %Message{} instead of anything process-shaped: a pid in
      # here would fail exactly here if the inbox ever reached the log, and
      # would be meaningless after a restart.
      inbox = Inbox.new() |> Inbox.steer("step") |> Inbox.followup("turn")

      assert {:ok, _event} = Event.new(0, :request_header, %{inbox: inbox})

      assert {:error, {:unserializable_event_data, _}} =
               Event.new(0, :request_header, %{inbox: Inbox.steer(Inbox.new(), fake(self()))})
    end
  end

  # A message whose metadata smuggles in a pid: the failure mode the
  # %Message{}-only queue invariant is there to prevent.
  defp fake(pid), do: Message.user("hi", metadata: %{listener: pid})
end

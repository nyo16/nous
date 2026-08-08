defmodule Nous.Agent.CallbacksPubSubTest do
  # async: true — each test starts its own supervised Phoenix.PubSub under a
  # unique name and subscribes only the test process.
  use ExUnit.Case, async: true

  alias Nous.Agent.Callbacks
  alias Nous.Agent.Context

  setup do
    pubsub = :"callbacks_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub, topic: "nous:agent:callbacks_test"}
  end

  describe "the PubSub bridge and notify_pid are one delivery, not two" do
    test "notify_pid does not also receive the topic copy", %{pubsub: pubsub, topic: topic} do
      # The test process is BOTH the notify_pid and a topic subscriber — exactly
      # the shape `Nous.AgentServer` is in, since it subscribes to its own topic
      # so external publishers can reach it. Two copies of one event is a bug on
      # its own, and it is what turned the server's forwarder into an unbounded
      # re-broadcast loop.
      Phoenix.PubSub.subscribe(pubsub, topic)

      ctx = Context.new(notify_pid: self(), pubsub: pubsub, pubsub_topic: topic)

      assert :ok = Callbacks.execute(ctx, :on_llm_new_delta, "Hello")

      assert_receive {:agent_delta, "Hello"}, 500
      refute_receive {:agent_delta, "Hello"}, 100
    end

    test "control: a subscriber that is NOT the notify_pid still gets the event", %{
      pubsub: pubsub,
      topic: topic
    } do
      # Without this, "the bridge stopped broadcasting entirely" would read as a
      # pass above. The excluded pid is the notify_pid, nobody else.
      parent = self()

      spawn_link(fn ->
        Phoenix.PubSub.subscribe(pubsub, topic)
        send(parent, :subscribed)

        receive do
          {:agent_delta, text} -> send(parent, {:got, text})
        after
          1_000 -> send(parent, :timeout)
        end
      end)

      assert_receive :subscribed, 500

      ctx = Context.new(notify_pid: self(), pubsub: pubsub, pubsub_topic: topic)
      assert :ok = Callbacks.execute(ctx, :on_llm_new_delta, "Hello")

      # The other subscriber got it; the notify_pid got exactly its direct copy.
      assert_receive {:got, "Hello"}, 1_000
      assert_receive {:agent_delta, "Hello"}, 500
      refute_receive {:agent_delta, "Hello"}, 100
    end

    test "with no notify_pid the topic copy is the only delivery", %{
      pubsub: pubsub,
      topic: topic
    } do
      Phoenix.PubSub.subscribe(pubsub, topic)

      ctx = Context.new(pubsub: pubsub, pubsub_topic: topic)

      assert :ok = Callbacks.execute(ctx, :on_error, "boom")

      assert_receive {:agent_error, "boom"}, 500
    end
  end
end

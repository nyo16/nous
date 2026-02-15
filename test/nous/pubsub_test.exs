defmodule Nous.PubSubTest do
  use ExUnit.Case, async: true

  alias Nous.PubSub

  describe "topic builders" do
    test "agent_topic/1 builds correct topic" do
      assert PubSub.agent_topic("abc123") == "nous:agent:abc123"
    end

    test "research_topic/1 builds correct topic" do
      assert PubSub.research_topic("abc123") == "nous:research:abc123"
    end

    test "approval_topic/1 builds correct topic" do
      assert PubSub.approval_topic("abc123") == "nous:approval:abc123"
    end
  end

  describe "configured_pubsub/0" do
    test "returns nil when not configured" do
      original = Application.get_env(:nous, :pubsub)
      Application.delete_env(:nous, :pubsub)

      assert PubSub.configured_pubsub() == nil

      if original, do: Application.put_env(:nous, :pubsub, original)
    end

    test "returns configured module" do
      original = Application.get_env(:nous, :pubsub)
      Application.put_env(:nous, :pubsub, MyTestPubSub)

      assert PubSub.configured_pubsub() == MyTestPubSub

      if original do
        Application.put_env(:nous, :pubsub, original)
      else
        Application.delete_env(:nous, :pubsub)
      end
    end
  end

  describe "available?/1" do
    test "returns false for nil" do
      refute PubSub.available?(nil)
    end

    test "returns true when Phoenix.PubSub is loaded" do
      # Phoenix.PubSub is loaded in test env
      assert PubSub.available?(SomeModule)
    end
  end

  describe "subscribe/2 and broadcast/3 graceful degradation" do
    test "subscribe with nil pubsub returns :ok" do
      assert PubSub.subscribe(nil, "test:topic") == :ok
    end

    test "broadcast with nil pubsub returns :ok" do
      assert PubSub.broadcast(nil, "test:topic", :msg) == :ok
    end

    test "broadcast with nil topic returns :ok" do
      assert PubSub.broadcast(SomeModule, nil, :msg) == :ok
    end
  end

  describe "subscribe/2 and broadcast/3 with real PubSub" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})
      %{pubsub: pubsub_name}
    end

    test "subscribe and broadcast deliver messages", %{pubsub: pubsub} do
      topic = "test:#{System.unique_integer([:positive])}"

      assert :ok = PubSub.subscribe(pubsub, topic)
      assert :ok = PubSub.broadcast(pubsub, topic, {:hello, "world"})

      assert_receive {:hello, "world"}
    end

    test "broadcast without subscribe does not deliver", %{pubsub: pubsub} do
      topic = "test:no_sub_#{System.unique_integer([:positive])}"

      assert :ok = PubSub.broadcast(pubsub, topic, {:nope, "nope"})

      refute_receive {:nope, "nope"}, 50
    end
  end
end

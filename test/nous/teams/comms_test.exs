defmodule Nous.Teams.CommsTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.Comms

  describe "topic builders" do
    test "team_topic/1 builds correct string" do
      assert Comms.team_topic("team_1") == "nous:team:team_1"
    end

    test "context_topic/1 builds correct string" do
      assert Comms.context_topic("team_1") == "nous:team:team_1:context"
    end

    test "agent_topic/2 builds correct string" do
      assert Comms.agent_topic("team_1", "alice") == "nous:team:team_1:agent:alice"
    end
  end

  describe "subscribe and broadcast with nil pubsub" do
    test "subscribe_team with nil returns :ok" do
      assert :ok = Comms.subscribe_team(nil, "team_1")
    end

    test "subscribe_agent with nil returns :ok" do
      assert :ok = Comms.subscribe_agent(nil, "team_1", "alice")
    end

    test "broadcast_team with nil returns :ok" do
      assert :ok = Comms.broadcast_team(nil, "team_1", :msg)
    end

    test "send_to_agent with nil returns :ok" do
      assert :ok = Comms.send_to_agent(nil, "team_1", "alice", :msg)
    end
  end

  describe "subscribe and broadcast with real PubSub" do
    setup do
      pubsub_name = :"test_comms_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})
      %{pubsub: pubsub_name}
    end

    test "subscribe_team and broadcast_team deliver messages", %{pubsub: pubsub} do
      team_id = "test_team_#{System.unique_integer([:positive])}"

      :ok = Comms.subscribe_team(pubsub, team_id)
      :ok = Comms.broadcast_team(pubsub, team_id, {:hello, "world"})

      assert_receive {:hello, "world"}
    end

    test "subscribe_agent and send_to_agent deliver messages", %{pubsub: pubsub} do
      team_id = "test_team_#{System.unique_integer([:positive])}"

      :ok = Comms.subscribe_agent(pubsub, team_id, "alice")
      :ok = Comms.send_to_agent(pubsub, team_id, "alice", {:dm, "hi"})

      assert_receive {:dm, "hi"}
    end

    test "agent topic messages are isolated from team topic", %{pubsub: pubsub} do
      team_id = "test_team_#{System.unique_integer([:positive])}"

      :ok = Comms.subscribe_team(pubsub, team_id)
      :ok = Comms.send_to_agent(pubsub, team_id, "alice", {:dm, "hi"})

      refute_receive {:dm, "hi"}, 50
    end
  end
end

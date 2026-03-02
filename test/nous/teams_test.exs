defmodule Nous.TeamsTest do
  use ExUnit.Case, async: false

  alias Nous.Teams

  setup do
    pubsub_name = :"test_teams_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name})

    # Configure PubSub for Nous
    original = Application.get_env(:nous, :pubsub)
    Application.put_env(:nous, :pubsub, pubsub_name)

    on_exit(fn ->
      if original do
        Application.put_env(:nous, :pubsub, original)
      else
        Application.delete_env(:nous, :pubsub)
      end
    end)

    %{pubsub: pubsub_name}
  end

  describe "create/1 and dissolve/1" do
    test "creates a team and returns team_id", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(name: "Test Team", pubsub: pubsub)
      assert is_binary(team_id)

      # Clean up
      Teams.dissolve(team_id)
    end

    test "creates a team with explicit team_id", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(team_id: "explicit_id", name: "Test", pubsub: pubsub)
      assert team_id == "explicit_id"

      Teams.dissolve(team_id)
    end

    test "dissolve cleans up team processes", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(name: "Dissolve Test", pubsub: pubsub)

      config = %{model: "openai:test-model", instructions: "Test"}
      {:ok, pid} = Teams.spawn_agent(team_id, "alice", config)
      assert Process.alive?(pid)

      :ok = Teams.dissolve(team_id)

      # Agent should be stopped
      refute Process.alive?(pid)

      # Team should not be found
      assert {:error, :team_not_found} = Teams.list_agents(team_id)
    end
  end

  describe "spawn_agent/4" do
    test "spawns agents in a team", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(name: "Agent Test", pubsub: pubsub)

      config = %{model: "openai:test-model", instructions: "Test"}
      {:ok, pid} = Teams.spawn_agent(team_id, "alice", config)

      assert is_pid(pid)
      assert Process.alive?(pid)

      Teams.dissolve(team_id)
    end

    test "returns error for non-existent team" do
      assert {:error, :team_not_found} = Teams.spawn_agent("no_such_team", "alice", %{})
    end
  end

  describe "team_status/1" do
    test "returns team status with agents", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(name: "Status Test", pubsub: pubsub)

      config = %{model: "openai:test-model", instructions: "Test"}
      {:ok, _} = Teams.spawn_agent(team_id, "alice", config)
      {:ok, _} = Teams.spawn_agent(team_id, "bob", config)

      status = Teams.team_status(team_id)

      assert status.team_name == "Status Test"
      assert status.agent_count == 2
      assert length(status.agents) == 2

      Teams.dissolve(team_id)
    end
  end

  describe "communication" do
    test "send_message delivers to agent via PubSub", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(name: "Comm Test", pubsub: pubsub)

      # Subscribe to agent topic
      agent_topic = Nous.Teams.Comms.agent_topic(team_id, "alice")
      Phoenix.PubSub.subscribe(pubsub, agent_topic)

      Teams.send_message(team_id, "alice", {:hello, "world"})

      assert_receive {:hello, "world"}

      Teams.dissolve(team_id)
    end

    test "broadcast delivers to team topic", %{pubsub: pubsub} do
      {:ok, team_id} = Teams.create(name: "Broadcast Test", pubsub: pubsub)

      # Subscribe to team topic
      team_topic = Nous.Teams.Comms.team_topic(team_id)
      Phoenix.PubSub.subscribe(pubsub, team_topic)

      Teams.broadcast(team_id, {:announcement, "hello"})

      assert_receive {:announcement, "hello"}

      Teams.dissolve(team_id)
    end
  end
end

defmodule Nous.Teams.CoordinatorTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.Coordinator

  setup do
    team_id = "coord_test_#{System.unique_integer([:positive])}"

    # Start a DynamicSupervisor for agents
    agent_sup_name = :"test_agent_sup_#{team_id}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_sup_name})

    # Start SharedState
    shared_state_name = :"test_shared_state_#{team_id}"

    start_supervised!(
      {Nous.Teams.SharedState, team_id: team_id, name: shared_state_name},
      id: :"shared_state_#{team_id}"
    )

    # Start PubSub
    pubsub_name = :"test_pubsub_#{team_id}"
    start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: :"pubsub_#{team_id}")

    {:ok, coordinator} =
      start_supervised(
        {Coordinator,
         team_id: team_id,
         team_name: "Test Team",
         pubsub: pubsub_name,
         agent_supervisor: agent_sup_name,
         shared_state: shared_state_name},
        id: :"coordinator_#{team_id}"
      )

    %{
      coordinator: coordinator,
      team_id: team_id,
      agent_sup: agent_sup_name,
      pubsub: pubsub_name
    }
  end

  describe "spawn_agent/4" do
    test "spawns an agent and returns pid", %{coordinator: coordinator} do
      config = %{
        model: "openai:test-model",
        instructions: "Test agent"
      }

      assert {:ok, pid} = Coordinator.spawn_agent(coordinator, "alice", config)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "spawned agent appears in list_agents", %{coordinator: coordinator} do
      config = %{model: "openai:test-model", instructions: "Test"}

      {:ok, _pid} = Coordinator.spawn_agent(coordinator, "alice", config)

      agents = Coordinator.list_agents(coordinator)
      assert length(agents) == 1
      assert hd(agents).name == "alice"
      assert hd(agents).status == :running
    end

    test "rejects duplicate agent names", %{coordinator: coordinator} do
      config = %{model: "openai:test-model", instructions: "Test"}

      {:ok, _pid} = Coordinator.spawn_agent(coordinator, "alice", config)
      assert {:error, :already_exists} = Coordinator.spawn_agent(coordinator, "alice", config)
    end

    test "can spawn multiple agents", %{coordinator: coordinator} do
      config = %{model: "openai:test-model", instructions: "Test"}

      {:ok, _} = Coordinator.spawn_agent(coordinator, "alice", config)
      {:ok, _} = Coordinator.spawn_agent(coordinator, "bob", config)

      agents = Coordinator.list_agents(coordinator)
      assert length(agents) == 2
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["alice", "bob"]
    end
  end

  describe "stop_agent/2" do
    test "stops agent and removes from list", %{coordinator: coordinator} do
      config = %{model: "openai:test-model", instructions: "Test"}

      {:ok, pid} = Coordinator.spawn_agent(coordinator, "alice", config)
      assert Process.alive?(pid)

      assert :ok = Coordinator.stop_agent(coordinator, "alice")
      refute Process.alive?(pid)

      agents = Coordinator.list_agents(coordinator)
      assert agents == []
    end

    test "returns error for unknown agent", %{coordinator: coordinator} do
      assert {:error, :not_found} = Coordinator.stop_agent(coordinator, "nonexistent")
    end
  end

  describe "team_status/1" do
    test "returns team info", %{coordinator: coordinator, team_id: team_id} do
      config = %{model: "openai:test-model", instructions: "Test"}
      {:ok, _} = Coordinator.spawn_agent(coordinator, "alice", config)

      status = Coordinator.team_status(coordinator)

      assert status.team_id == team_id
      assert status.team_name == "Test Team"
      assert status.agent_count == 1
      assert length(status.agents) == 1
    end
  end

  describe "dissolve/1" do
    test "stops all agents and clears state", %{coordinator: coordinator} do
      config = %{model: "openai:test-model", instructions: "Test"}

      {:ok, pid1} = Coordinator.spawn_agent(coordinator, "alice", config)
      {:ok, pid2} = Coordinator.spawn_agent(coordinator, "bob", config)

      assert :ok = Coordinator.dissolve(coordinator)

      refute Process.alive?(pid1)
      refute Process.alive?(pid2)

      agents = Coordinator.list_agents(coordinator)
      assert agents == []
    end
  end

  describe "agent monitoring" do
    test "detects agent crash and removes from list", %{coordinator: coordinator} do
      config = %{model: "openai:test-model", instructions: "Test"}

      {:ok, pid} = Coordinator.spawn_agent(coordinator, "alice", config)

      # Kill the agent process
      Process.exit(pid, :kill)

      # Give the monitor time to trigger
      Process.sleep(50)

      agents = Coordinator.list_agents(coordinator)
      assert agents == []
    end
  end
end

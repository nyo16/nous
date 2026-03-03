defmodule Nous.DecisionsTest do
  use ExUnit.Case, async: true

  alias Nous.Decisions
  alias Nous.Decisions.{Node, Edge}
  alias Nous.Decisions.Store.ETS

  setup do
    {:ok, state} = ETS.init([])
    %{state: state}
  end

  describe "add_node/3" do
    test "adds a node to the store", %{state: state} do
      node = Node.new(%{type: :goal, label: "Ship v1.0"})
      assert {:ok, state} = Decisions.add_node(ETS, state, node)
      assert {:ok, fetched} = Decisions.get_node(ETS, state, node.id)
      assert fetched.label == "Ship v1.0"
    end
  end

  describe "add_edge/3" do
    test "adds an edge between nodes", %{state: state} do
      goal = Node.new(%{type: :goal, label: "Goal"})
      decision = Node.new(%{type: :decision, label: "Decision"})
      {:ok, state} = Decisions.add_node(ETS, state, goal)
      {:ok, state} = Decisions.add_node(ETS, state, decision)

      edge = Edge.new(%{from_id: goal.id, to_id: decision.id, edge_type: :leads_to})
      assert {:ok, _state} = Decisions.add_edge(ETS, state, edge)
    end
  end

  describe "update_node/4" do
    test "updates fields on a node", %{state: state} do
      node = Node.new(%{type: :goal, label: "Goal", confidence: 0.5})
      {:ok, state} = Decisions.add_node(ETS, state, node)

      assert {:ok, state} = Decisions.update_node(ETS, state, node.id, %{confidence: 0.9})
      {:ok, updated} = Decisions.get_node(ETS, state, node.id)
      assert updated.confidence == 0.9
    end

    test "returns error for non-existent node", %{state: state} do
      assert {:error, :not_found} =
               Decisions.update_node(ETS, state, "nonexistent", %{confidence: 0.5})
    end
  end

  describe "supersede/5" do
    test "marks old node as superseded and adds edge", %{state: state} do
      old = Node.new(%{type: :decision, label: "Old approach"})
      new = Node.new(%{type: :decision, label: "New approach"})
      {:ok, state} = Decisions.add_node(ETS, state, old)
      {:ok, state} = Decisions.add_node(ETS, state, new)

      assert {:ok, state} =
               Decisions.supersede(ETS, state, old.id, new.id, "Better approach found")

      {:ok, old_updated} = Decisions.get_node(ETS, state, old.id)
      assert old_updated.status == :superseded
      assert old_updated.rationale == "Better approach found"

      # Check that a supersedes edge exists
      {:ok, edges} = ETS.get_edges(state, new.id, :outgoing)
      assert Enum.any?(edges, fn e -> e.to_id == old.id && e.edge_type == :supersedes end)
    end

    test "returns error when old node not found", %{state: state} do
      new = Node.new(%{type: :decision, label: "New"})
      {:ok, state} = Decisions.add_node(ETS, state, new)

      assert {:error, :not_found} =
               Decisions.supersede(ETS, state, "nonexistent", new.id, "reason")
    end
  end

  describe "active_goals/2" do
    test "returns only active goal nodes", %{state: state} do
      goal1 = Node.new(%{type: :goal, label: "Active goal", status: :active})
      goal2 = Node.new(%{type: :goal, label: "Completed goal", status: :completed})
      decision = Node.new(%{type: :decision, label: "A decision"})

      {:ok, state} = Decisions.add_node(ETS, state, goal1)
      {:ok, state} = Decisions.add_node(ETS, state, goal2)
      {:ok, state} = Decisions.add_node(ETS, state, decision)

      {:ok, goals} = Decisions.active_goals(ETS, state)
      assert length(goals) == 1
      assert hd(goals).label == "Active goal"
    end
  end

  describe "recent_decisions/3" do
    test "returns decision nodes sorted by recency", %{state: state} do
      d1 = Node.new(%{type: :decision, label: "First", created_at: ~U[2024-01-01 00:00:00Z]})
      d2 = Node.new(%{type: :decision, label: "Second", created_at: ~U[2024-06-01 00:00:00Z]})
      d3 = Node.new(%{type: :decision, label: "Third", created_at: ~U[2024-12-01 00:00:00Z]})

      {:ok, state} = Decisions.add_node(ETS, state, d1)
      {:ok, state} = Decisions.add_node(ETS, state, d2)
      {:ok, state} = Decisions.add_node(ETS, state, d3)

      {:ok, decisions} = Decisions.recent_decisions(ETS, state, limit: 2)
      assert length(decisions) == 2
      assert hd(decisions).label == "Third"
    end
  end

  describe "validate_config/1" do
    test "returns ok with defaults for valid config" do
      assert {:ok, config} = Decisions.validate_config(%{store: ETS})
      assert config[:store] == ETS
      assert config[:auto_inject] == true
      assert config[:inject_strategy] == :first_only
      assert config[:decision_limit] == 5
    end

    test "returns error when store is missing" do
      assert {:error, message} = Decisions.validate_config(%{})
      assert message =~ ":store is required"
    end
  end
end

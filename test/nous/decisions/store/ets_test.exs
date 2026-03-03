defmodule Nous.Decisions.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Nous.Decisions.{Node, Edge}
  alias Nous.Decisions.Store.ETS

  setup do
    {:ok, state} = ETS.init([])
    %{state: state}
  end

  describe "init/1" do
    test "creates node and edge tables" do
      {:ok, state} = ETS.init([])
      assert is_reference(state.nodes)
      assert is_reference(state.edges)
    end
  end

  describe "add_node/2 and get_node/2" do
    test "roundtrip stores and fetches a node", %{state: state} do
      node = Node.new(%{type: :goal, label: "Ship v1.0"})
      {:ok, _state} = ETS.add_node(state, node)

      assert {:ok, fetched} = ETS.get_node(state, node.id)
      assert fetched.id == node.id
      assert fetched.label == "Ship v1.0"
      assert fetched.type == :goal
      assert fetched.status == :active
    end

    test "get_node returns error for non-existent node", %{state: state} do
      assert {:error, :not_found} = ETS.get_node(state, "nonexistent")
    end
  end

  describe "update_node/3" do
    test "updates specific fields", %{state: state} do
      node = Node.new(%{type: :goal, label: "Original", confidence: 0.5})
      {:ok, state} = ETS.add_node(state, node)

      {:ok, _state} = ETS.update_node(state, node.id, %{confidence: 0.9, label: "Updated"})

      {:ok, updated} = ETS.get_node(state, node.id)
      assert updated.confidence == 0.9
      assert updated.label == "Updated"
      assert DateTime.compare(updated.updated_at, node.updated_at) in [:gt, :eq]
    end

    test "returns error when node not found", %{state: state} do
      assert {:error, :not_found} = ETS.update_node(state, "nonexistent", %{confidence: 1.0})
    end
  end

  describe "delete_node/2" do
    test "removes a node and its edges", %{state: state} do
      n1 = Node.new(%{type: :goal, label: "Goal"})
      n2 = Node.new(%{type: :decision, label: "Decision"})
      {:ok, state} = ETS.add_node(state, n1)
      {:ok, state} = ETS.add_node(state, n2)

      edge = Edge.new(%{from_id: n1.id, to_id: n2.id, edge_type: :leads_to})
      {:ok, state} = ETS.add_edge(state, edge)

      {:ok, state} = ETS.delete_node(state, n1.id)

      assert {:error, :not_found} = ETS.get_node(state, n1.id)
      # Edge should also be removed
      {:ok, edges} = ETS.get_edges(state, n2.id, :incoming)
      assert edges == []
    end
  end

  describe "add_edge/2 and get_edges/3" do
    test "stores and retrieves outgoing edges", %{state: state} do
      n1 = Node.new(%{type: :goal, label: "Goal"})
      n2 = Node.new(%{type: :decision, label: "Decision"})
      {:ok, state} = ETS.add_node(state, n1)
      {:ok, state} = ETS.add_node(state, n2)

      edge = Edge.new(%{from_id: n1.id, to_id: n2.id, edge_type: :leads_to})
      {:ok, state} = ETS.add_edge(state, edge)

      {:ok, outgoing} = ETS.get_edges(state, n1.id, :outgoing)
      assert length(outgoing) == 1
      assert hd(outgoing).to_id == n2.id
      assert hd(outgoing).edge_type == :leads_to
    end

    test "stores and retrieves incoming edges", %{state: state} do
      n1 = Node.new(%{type: :goal, label: "Goal"})
      n2 = Node.new(%{type: :decision, label: "Decision"})
      {:ok, state} = ETS.add_node(state, n1)
      {:ok, state} = ETS.add_node(state, n2)

      edge = Edge.new(%{from_id: n1.id, to_id: n2.id, edge_type: :chosen})
      {:ok, state} = ETS.add_edge(state, edge)

      {:ok, incoming} = ETS.get_edges(state, n2.id, :incoming)
      assert length(incoming) == 1
      assert hd(incoming).from_id == n1.id
    end

    test "returns empty list when no edges", %{state: state} do
      n1 = Node.new(%{type: :goal, label: "Lonely"})
      {:ok, _state} = ETS.add_node(state, n1)

      {:ok, edges} = ETS.get_edges(state, n1.id, :outgoing)
      assert edges == []
    end
  end

  describe "query/3 :active_goals" do
    test "returns only active goal nodes", %{state: state} do
      g1 = Node.new(%{type: :goal, label: "Active", status: :active})
      g2 = Node.new(%{type: :goal, label: "Done", status: :completed})
      d = Node.new(%{type: :decision, label: "Not a goal", status: :active})

      {:ok, state} = ETS.add_node(state, g1)
      {:ok, state} = ETS.add_node(state, g2)
      {:ok, state} = ETS.add_node(state, d)

      {:ok, goals} = ETS.query(state, :active_goals, [])
      assert length(goals) == 1
      assert hd(goals).label == "Active"
    end
  end

  describe "query/3 :recent_decisions" do
    test "returns decisions sorted by created_at desc with limit", %{state: state} do
      d1 = Node.new(%{type: :decision, label: "First", created_at: ~U[2024-01-01 00:00:00Z]})
      d2 = Node.new(%{type: :decision, label: "Second", created_at: ~U[2024-06-01 00:00:00Z]})
      d3 = Node.new(%{type: :decision, label: "Third", created_at: ~U[2024-12-01 00:00:00Z]})

      {:ok, state} = ETS.add_node(state, d1)
      {:ok, state} = ETS.add_node(state, d2)
      {:ok, state} = ETS.add_node(state, d3)

      {:ok, decisions} = ETS.query(state, :recent_decisions, limit: 2)
      assert length(decisions) == 2
      labels = Enum.map(decisions, & &1.label)
      assert labels == ["Third", "Second"]
    end
  end

  describe "query/3 :descendants" do
    test "returns all reachable nodes from a start node", %{state: state} do
      #  A -> B -> C
      #       └-> D
      a = Node.new(%{type: :goal, label: "A"})
      b = Node.new(%{type: :decision, label: "B"})
      c = Node.new(%{type: :action, label: "C"})
      d = Node.new(%{type: :outcome, label: "D"})

      {:ok, state} = ETS.add_node(state, a)
      {:ok, state} = ETS.add_node(state, b)
      {:ok, state} = ETS.add_node(state, c)
      {:ok, state} = ETS.add_node(state, d)

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to}))

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: b.id, to_id: c.id, edge_type: :leads_to}))

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: b.id, to_id: d.id, edge_type: :leads_to}))

      {:ok, desc} = ETS.query(state, :descendants, node_id: a.id)
      desc_labels = Enum.map(desc, & &1.label) |> Enum.sort()
      assert desc_labels == ["B", "C", "D"]
    end
  end

  describe "query/3 :ancestors" do
    test "returns all nodes that can reach the target", %{state: state} do
      # A -> B -> C
      a = Node.new(%{type: :goal, label: "A"})
      b = Node.new(%{type: :decision, label: "B"})
      c = Node.new(%{type: :outcome, label: "C"})

      {:ok, state} = ETS.add_node(state, a)
      {:ok, state} = ETS.add_node(state, b)
      {:ok, state} = ETS.add_node(state, c)

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to}))

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: b.id, to_id: c.id, edge_type: :leads_to}))

      {:ok, anc} = ETS.query(state, :ancestors, node_id: c.id)
      anc_labels = Enum.map(anc, & &1.label) |> Enum.sort()
      assert anc_labels == ["A", "B"]
    end
  end

  describe "query/3 :path_between" do
    test "finds a path between two nodes", %{state: state} do
      # A -> B -> C -> D
      a = Node.new(%{type: :goal, label: "A"})
      b = Node.new(%{type: :decision, label: "B"})
      c = Node.new(%{type: :action, label: "C"})
      d = Node.new(%{type: :outcome, label: "D"})

      {:ok, state} = ETS.add_node(state, a)
      {:ok, state} = ETS.add_node(state, b)
      {:ok, state} = ETS.add_node(state, c)
      {:ok, state} = ETS.add_node(state, d)

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to}))

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: b.id, to_id: c.id, edge_type: :leads_to}))

      {:ok, state} =
        ETS.add_edge(state, Edge.new(%{from_id: c.id, to_id: d.id, edge_type: :leads_to}))

      {:ok, path} = ETS.query(state, :path_between, from_id: a.id, to_id: d.id)
      path_labels = Enum.map(path, & &1.label)
      assert path_labels == ["A", "B", "C", "D"]
    end

    test "returns empty list when no path exists", %{state: state} do
      a = Node.new(%{type: :goal, label: "A"})
      b = Node.new(%{type: :goal, label: "B"})

      {:ok, state} = ETS.add_node(state, a)
      {:ok, state} = ETS.add_node(state, b)

      {:ok, path} = ETS.query(state, :path_between, from_id: a.id, to_id: b.id)
      assert path == []
    end
  end

  describe "full workflow" do
    test "goal -> decision -> action -> outcome", %{state: state} do
      # Create goal
      goal = Node.new(%{type: :goal, label: "Implement authentication"})
      {:ok, state} = ETS.add_node(state, goal)

      # Create decision
      decision =
        Node.new(%{type: :decision, label: "Use JWT tokens", rationale: "Simpler for API auth"})

      {:ok, state} = ETS.add_node(state, decision)

      {:ok, state} =
        ETS.add_edge(
          state,
          Edge.new(%{from_id: goal.id, to_id: decision.id, edge_type: :leads_to})
        )

      # Create action
      action = Node.new(%{type: :action, label: "Integrate Guardian library"})
      {:ok, state} = ETS.add_node(state, action)

      {:ok, state} =
        ETS.add_edge(
          state,
          Edge.new(%{from_id: decision.id, to_id: action.id, edge_type: :chosen})
        )

      # Record outcome
      outcome =
        Node.new(%{type: :outcome, label: "Auth working, all tests pass", status: :completed})

      {:ok, state} = ETS.add_node(state, outcome)

      {:ok, state} =
        ETS.add_edge(
          state,
          Edge.new(%{from_id: action.id, to_id: outcome.id, edge_type: :leads_to})
        )

      # Verify the full path
      {:ok, path} = ETS.query(state, :path_between, from_id: goal.id, to_id: outcome.id)
      assert length(path) == 4
      assert Enum.map(path, & &1.type) == [:goal, :decision, :action, :outcome]

      # Verify descendants of goal
      {:ok, desc} = ETS.query(state, :descendants, node_id: goal.id)
      assert length(desc) == 3

      # Verify ancestors of outcome
      {:ok, anc} = ETS.query(state, :ancestors, node_id: outcome.id)
      assert length(anc) == 3

      # Mark goal as completed
      {:ok, state} = ETS.update_node(state, goal.id, %{status: :completed})
      {:ok, goals} = ETS.query(state, :active_goals, [])
      assert goals == []
    end
  end
end

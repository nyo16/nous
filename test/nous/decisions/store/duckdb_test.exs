if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Decisions.Store.DuckDBTest do
    use ExUnit.Case, async: true

    @moduletag :duckdb

    alias Nous.Decisions.{Node, Edge}
    alias Nous.Decisions.Store.DuckDB

    setup do
      {:ok, state} = DuckDB.init([])
      %{state: state}
    end

    describe "init/1" do
      test "creates an in-memory database" do
        {:ok, state} = DuckDB.init([])
        assert is_map(state)
        assert Map.has_key?(state, :db)
        assert Map.has_key?(state, :conn)
      end
    end

    describe "add_node/2 and get_node/2" do
      test "roundtrip stores and fetches a node", %{state: state} do
        node = Node.new(%{type: :goal, label: "Ship v1.0", confidence: 0.8})
        {:ok, _state} = DuckDB.add_node(state, node)

        assert {:ok, fetched} = DuckDB.get_node(state, node.id)
        assert fetched.id == node.id
        assert fetched.label == "Ship v1.0"
        assert fetched.type == :goal
        assert fetched.status == :active
        assert fetched.confidence == 0.8
      end

      test "get_node returns error for non-existent node", %{state: state} do
        assert {:error, :not_found} = DuckDB.get_node(state, "nonexistent")
      end
    end

    describe "update_node/3" do
      test "updates specific fields", %{state: state} do
        node = Node.new(%{type: :goal, label: "Original", confidence: 0.5})
        {:ok, state} = DuckDB.add_node(state, node)

        {:ok, _state} = DuckDB.update_node(state, node.id, %{confidence: 0.9, label: "Updated"})

        {:ok, updated} = DuckDB.get_node(state, node.id)
        assert updated.confidence == 0.9
        assert updated.label == "Updated"
      end

      test "returns error when node not found", %{state: state} do
        assert {:error, :not_found} = DuckDB.update_node(state, "nonexistent", %{confidence: 1.0})
      end
    end

    describe "delete_node/2" do
      test "removes a node and its edges", %{state: state} do
        n1 = Node.new(%{type: :goal, label: "Goal"})
        n2 = Node.new(%{type: :decision, label: "Decision"})
        {:ok, state} = DuckDB.add_node(state, n1)
        {:ok, state} = DuckDB.add_node(state, n2)

        edge = Edge.new(%{from_id: n1.id, to_id: n2.id, edge_type: :leads_to})
        {:ok, state} = DuckDB.add_edge(state, edge)

        {:ok, state} = DuckDB.delete_node(state, n1.id)

        assert {:error, :not_found} = DuckDB.get_node(state, n1.id)
        {:ok, edges} = DuckDB.get_edges(state, n2.id, :incoming)
        assert edges == []
      end
    end

    describe "add_edge/2 and get_edges/3" do
      test "stores and retrieves outgoing edges", %{state: state} do
        n1 = Node.new(%{type: :goal, label: "Goal"})
        n2 = Node.new(%{type: :decision, label: "Decision"})
        {:ok, state} = DuckDB.add_node(state, n1)
        {:ok, state} = DuckDB.add_node(state, n2)

        edge = Edge.new(%{from_id: n1.id, to_id: n2.id, edge_type: :leads_to})
        {:ok, state} = DuckDB.add_edge(state, edge)

        {:ok, outgoing} = DuckDB.get_edges(state, n1.id, :outgoing)
        assert length(outgoing) == 1
        assert hd(outgoing).to_id == n2.id
      end

      test "stores and retrieves incoming edges", %{state: state} do
        n1 = Node.new(%{type: :goal, label: "Goal"})
        n2 = Node.new(%{type: :decision, label: "Decision"})
        {:ok, state} = DuckDB.add_node(state, n1)
        {:ok, state} = DuckDB.add_node(state, n2)

        edge = Edge.new(%{from_id: n1.id, to_id: n2.id, edge_type: :chosen})
        {:ok, state} = DuckDB.add_edge(state, edge)

        {:ok, incoming} = DuckDB.get_edges(state, n2.id, :incoming)
        assert length(incoming) == 1
        assert hd(incoming).from_id == n1.id
      end
    end

    describe "query/3 :active_goals" do
      test "returns only active goal nodes", %{state: state} do
        g1 = Node.new(%{type: :goal, label: "Active", status: :active})
        g2 = Node.new(%{type: :goal, label: "Done", status: :completed})
        d = Node.new(%{type: :decision, label: "Not a goal", status: :active})

        {:ok, state} = DuckDB.add_node(state, g1)
        {:ok, state} = DuckDB.add_node(state, g2)
        {:ok, state} = DuckDB.add_node(state, d)

        {:ok, goals} = DuckDB.query(state, :active_goals, [])
        assert length(goals) == 1
        assert hd(goals).label == "Active"
      end
    end

    describe "query/3 :recent_decisions" do
      test "returns decisions sorted by created_at desc with limit", %{state: state} do
        d1 = Node.new(%{type: :decision, label: "First", created_at: ~U[2024-01-01 00:00:00Z]})
        d2 = Node.new(%{type: :decision, label: "Second", created_at: ~U[2024-06-01 00:00:00Z]})
        d3 = Node.new(%{type: :decision, label: "Third", created_at: ~U[2024-12-01 00:00:00Z]})

        {:ok, state} = DuckDB.add_node(state, d1)
        {:ok, state} = DuckDB.add_node(state, d2)
        {:ok, state} = DuckDB.add_node(state, d3)

        {:ok, decisions} = DuckDB.query(state, :recent_decisions, limit: 2)
        assert length(decisions) == 2
        labels = Enum.map(decisions, & &1.label)
        assert labels == ["Third", "Second"]
      end
    end

    describe "query/3 :descendants" do
      test "returns all reachable nodes", %{state: state} do
        a = Node.new(%{type: :goal, label: "A"})
        b = Node.new(%{type: :decision, label: "B"})
        c = Node.new(%{type: :action, label: "C"})

        {:ok, state} = DuckDB.add_node(state, a)
        {:ok, state} = DuckDB.add_node(state, b)
        {:ok, state} = DuckDB.add_node(state, c)

        {:ok, state} =
          DuckDB.add_edge(state, Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to}))

        {:ok, state} =
          DuckDB.add_edge(state, Edge.new(%{from_id: b.id, to_id: c.id, edge_type: :leads_to}))

        {:ok, desc} = DuckDB.query(state, :descendants, node_id: a.id)
        desc_labels = Enum.map(desc, & &1.label) |> Enum.sort()
        assert desc_labels == ["B", "C"]
      end
    end

    describe "query/3 :ancestors" do
      test "returns all nodes that can reach the target", %{state: state} do
        a = Node.new(%{type: :goal, label: "A"})
        b = Node.new(%{type: :decision, label: "B"})
        c = Node.new(%{type: :outcome, label: "C"})

        {:ok, state} = DuckDB.add_node(state, a)
        {:ok, state} = DuckDB.add_node(state, b)
        {:ok, state} = DuckDB.add_node(state, c)

        {:ok, state} =
          DuckDB.add_edge(state, Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to}))

        {:ok, state} =
          DuckDB.add_edge(state, Edge.new(%{from_id: b.id, to_id: c.id, edge_type: :leads_to}))

        {:ok, anc} = DuckDB.query(state, :ancestors, node_id: c.id)
        anc_labels = Enum.map(anc, & &1.label) |> Enum.sort()
        assert anc_labels == ["A", "B"]
      end
    end

    describe "query/3 :path_between" do
      test "finds a path between two nodes", %{state: state} do
        a = Node.new(%{type: :goal, label: "A"})
        b = Node.new(%{type: :decision, label: "B"})
        c = Node.new(%{type: :outcome, label: "C"})

        {:ok, state} = DuckDB.add_node(state, a)
        {:ok, state} = DuckDB.add_node(state, b)
        {:ok, state} = DuckDB.add_node(state, c)

        {:ok, state} =
          DuckDB.add_edge(state, Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to}))

        {:ok, state} =
          DuckDB.add_edge(state, Edge.new(%{from_id: b.id, to_id: c.id, edge_type: :leads_to}))

        {:ok, path} = DuckDB.query(state, :path_between, from_id: a.id, to_id: c.id)
        path_labels = Enum.map(path, & &1.label)
        assert "A" in path_labels
        assert "C" in path_labels
      end
    end

    describe "full workflow" do
      test "goal -> decision -> action -> outcome", %{state: state} do
        goal = Node.new(%{type: :goal, label: "Implement auth"})
        {:ok, state} = DuckDB.add_node(state, goal)

        decision = Node.new(%{type: :decision, label: "Use JWT", rationale: "Simpler"})
        {:ok, state} = DuckDB.add_node(state, decision)

        {:ok, state} =
          DuckDB.add_edge(
            state,
            Edge.new(%{from_id: goal.id, to_id: decision.id, edge_type: :leads_to})
          )

        action = Node.new(%{type: :action, label: "Add Guardian"})
        {:ok, state} = DuckDB.add_node(state, action)

        {:ok, state} =
          DuckDB.add_edge(
            state,
            Edge.new(%{from_id: decision.id, to_id: action.id, edge_type: :chosen})
          )

        outcome = Node.new(%{type: :outcome, label: "Tests pass", status: :completed})
        {:ok, state} = DuckDB.add_node(state, outcome)

        {:ok, state} =
          DuckDB.add_edge(
            state,
            Edge.new(%{from_id: action.id, to_id: outcome.id, edge_type: :leads_to})
          )

        # Verify goals
        {:ok, goals} = DuckDB.query(state, :active_goals, [])
        assert length(goals) == 1

        # Verify descendants
        {:ok, desc} = DuckDB.query(state, :descendants, node_id: goal.id)
        assert length(desc) == 3

        # Mark goal as completed
        {:ok, _state} = DuckDB.update_node(state, goal.id, %{status: :completed})
        {:ok, goals} = DuckDB.query(state, :active_goals, [])
        assert goals == []
      end
    end
  end
end

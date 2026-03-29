defmodule Nous.Workflow.GraphTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow.Graph

  describe "new/1,2" do
    test "creates empty graph with id" do
      graph = Graph.new("pipeline")
      assert graph.id == "pipeline"
      assert graph.name == "pipeline"
      assert graph.nodes == %{}
      assert graph.allows_cycles == false
    end

    test "accepts name and allows_cycles options" do
      graph = Graph.new("g1", name: "My Pipeline", allows_cycles: true)
      assert graph.name == "My Pipeline"
      assert graph.allows_cycles == true
    end
  end

  describe "add_node/4,5" do
    test "adds a node to the graph" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:fetch, :transform, %{transform_fn: &Function.identity/1})

      assert Map.has_key?(graph.nodes, "fetch")
      assert graph.nodes["fetch"].type == :transform
    end

    test "first node becomes entry node" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:first, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:second, :transform, %{transform_fn: &Function.identity/1})

      assert graph.entry_node == "first"
    end

    test "initializes empty edge lists" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})

      assert graph.out_edges["a"] == []
      assert graph.in_edges["a"] == []
    end

    test "raises on duplicate node" do
      assert_raise ArgumentError, ~r/already exists/, fn ->
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
      end
    end

    test "accepts optional label, error_strategy, timeout" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1},
          label: "My Step",
          error_strategy: :skip,
          timeout: 5000
        )

      node = graph.nodes["a"]
      assert node.label == "My Step"
      assert node.error_strategy == :skip
      assert node.timeout == 5000
    end
  end

  describe "connect/3,4" do
    test "creates sequential edge by default" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:b, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.connect(:a, :b)

      assert [edge] = graph.out_edges["a"]
      assert edge.from_id == "a"
      assert edge.to_id == "b"
      assert edge.type == :sequential

      assert [edge] = graph.in_edges["b"]
      assert edge.from_id == "a"
    end

    test "creates conditional edge with condition" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:b, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.connect(:a, :b, condition: fn _s -> true end)

      assert [edge] = graph.out_edges["a"]
      assert edge.type == :conditional
      assert is_function(edge.condition, 1)
    end

    test "raises on non-existent source node" do
      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Graph.new("g")
        |> Graph.add_node(:b, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.connect(:a, :b)
      end
    end

    test "raises on non-existent target node" do
      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.connect(:a, :b)
      end
    end
  end

  describe "chain/2" do
    test "connects nodes in sequence" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:b, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:c, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.chain([:a, :b, :c])

      assert ["b"] = Graph.successors(graph, "a")
      assert ["c"] = Graph.successors(graph, "b")
      assert [] = Graph.successors(graph, "c")
    end
  end

  describe "successors/2 and predecessors/2" do
    test "returns correct neighbors" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:b, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:c, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.connect(:a, :b)
        |> Graph.connect(:a, :c)

      assert Enum.sort(Graph.successors(graph, "a")) == ["b", "c"]
      assert Graph.predecessors(graph, "b") == ["a"]
    end
  end

  describe "terminal_nodes/1" do
    test "finds nodes with no outgoing edges" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:b, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.add_node(:c, :transform, %{transform_fn: &Function.identity/1})
        |> Graph.chain([:a, :b])

      terminals = Graph.terminal_nodes(graph)
      assert "b" in terminals
      assert "c" in terminals
      refute "a" in terminals
    end
  end
end

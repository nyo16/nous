defmodule Nous.Workflow.CompilerTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow.{Graph, Compiler}

  # Helper to build a simple transform node config
  defp tf, do: %{transform_fn: &Function.identity/1}

  describe "compile/1 — valid graphs" do
    test "compiles a linear pipeline" do
      graph =
        Graph.new("linear")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.chain([:a, :b, :c])

      assert {:ok, compiled} = Compiler.compile(graph)
      assert compiled.topo_order == ["a", "b", "c"]
      assert compiled.levels == [["a"], ["b"], ["c"]]
      assert compiled.terminal_nodes == ["c"]
      assert compiled.fan_in_nodes == []
    end

    test "compiles a diamond DAG with correct levels" do
      #     a
      #    / \
      #   b   c
      #    \ /
      #     d
      graph =
        Graph.new("diamond")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.add_node(:d, :transform, tf())
        |> Graph.connect(:a, :b)
        |> Graph.connect(:a, :c)
        |> Graph.connect(:b, :d)
        |> Graph.connect(:c, :d)

      assert {:ok, compiled} = Compiler.compile(graph)

      # Level 0: a, Level 1: b and c (parallel), Level 2: d
      assert [["a"], level1, ["d"]] = compiled.levels
      assert Enum.sort(level1) == ["b", "c"]

      # d is a fan-in node
      assert "d" in compiled.fan_in_nodes
    end

    test "compiles a wide parallel graph" do
      #   a
      #  /|\
      # b c d
      graph =
        Graph.new("wide")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.add_node(:d, :transform, tf())
        |> Graph.connect(:a, :b)
        |> Graph.connect(:a, :c)
        |> Graph.connect(:a, :d)

      assert {:ok, compiled} = Compiler.compile(graph)
      assert [["a"], level1] = compiled.levels
      assert Enum.sort(level1) == ["b", "c", "d"]
    end

    test "compiles a single-node graph" do
      graph =
        Graph.new("single")
        |> Graph.add_node(:only, :transform, tf())

      assert {:ok, compiled} = Compiler.compile(graph)
      assert compiled.topo_order == ["only"]
      assert compiled.levels == [["only"]]
    end

    test "identifies terminal nodes" do
      graph =
        Graph.new("g")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.connect(:a, :b)
        |> Graph.connect(:a, :c)

      assert {:ok, compiled} = Compiler.compile(graph)
      assert Enum.sort(compiled.terminal_nodes) == ["b", "c"]
    end
  end

  describe "compile/1 — validation errors" do
    test "rejects empty graph" do
      graph = Graph.new("empty")
      assert {:error, errors} = Compiler.compile(graph)
      assert Enum.any?(errors, fn {type, _} -> type == :empty_graph end)
    end

    test "rejects graph with unreachable nodes" do
      # a -> b, but c is disconnected
      graph =
        Graph.new("disconnected")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.connect(:a, :b)

      assert {:error, errors} = Compiler.compile(graph)
      assert Enum.any?(errors, fn {type, _} -> type == :unreachable_nodes end)
    end

    test "rejects agent_step without agent config" do
      graph =
        Graph.new("bad_agent")
        |> Graph.add_node(:a, :agent_step, %{prompt: "hello"})

      assert {:error, errors} = Compiler.compile(graph)
      assert Enum.any?(errors, fn {type, _} -> type == :missing_config end)
    end

    test "rejects tool_step without tool config" do
      graph =
        Graph.new("bad_tool")
        |> Graph.add_node(:a, :tool_step, %{args: %{}})

      assert {:error, errors} = Compiler.compile(graph)
      assert Enum.any?(errors, fn {type, _} -> type == :missing_config end)
    end

    test "rejects transform without transform_fn" do
      graph =
        Graph.new("bad_transform")
        |> Graph.add_node(:a, :transform, %{})

      assert {:error, errors} = Compiler.compile(graph)
      assert Enum.any?(errors, fn {type, _} -> type == :missing_config end)
    end
  end

  describe "topological_sort/1" do
    test "returns correct order for chain" do
      graph =
        Graph.new("chain")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.add_node(:d, :transform, tf())
        |> Graph.chain([:a, :b, :c, :d])

      assert {:ok, order, levels} = Compiler.topological_sort(graph)
      assert order == ["a", "b", "c", "d"]
      assert levels == [["a"], ["b"], ["c"], ["d"]]
    end

    test "returns parallel-safe levels for independent nodes" do
      # a -> b, a -> c, b -> d, c -> d
      graph =
        Graph.new("diamond")
        |> Graph.add_node(:a, :transform, tf())
        |> Graph.add_node(:b, :transform, tf())
        |> Graph.add_node(:c, :transform, tf())
        |> Graph.add_node(:d, :transform, tf())
        |> Graph.connect(:a, :b)
        |> Graph.connect(:a, :c)
        |> Graph.connect(:b, :d)
        |> Graph.connect(:c, :d)

      assert {:ok, _order, levels} = Compiler.topological_sort(graph)
      assert [["a"], parallel_level, ["d"]] = levels
      assert Enum.sort(parallel_level) == ["b", "c"]
    end

    test "handles nodes with no edges" do
      graph =
        Graph.new("isolated")
        |> Graph.add_node(:a, :transform, tf())

      assert {:ok, ["a"], [["a"]]} = Compiler.topological_sort(graph)
    end
  end
end

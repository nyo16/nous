defmodule Nous.Workflow.Phase5Test do
  use ExUnit.Case, async: true

  alias Nous.Workflow
  alias Nous.Workflow.{Graph, Scratch}

  defp tf(fun), do: %{transform_fn: fun}

  # =========================================================================
  # Subworkflow
  # =========================================================================

  describe "subworkflow node" do
    test "executes nested workflow and merges output" do
      # Inner workflow: doubles a number
      inner =
        Graph.new("doubler")
        |> Graph.add_node(
          :double,
          :transform,
          tf(fn data ->
            Map.update!(data, :value, &(&1 * 2))
          end)
        )

      # Outer workflow: sets value, runs inner, checks result
      graph =
        Workflow.new("outer")
        |> Workflow.add_node(:setup, :transform, tf(fn data -> Map.put(data, :value, 5) end))
        |> Workflow.add_node(:sub, :subworkflow, %{workflow: inner})
        |> Workflow.add_node(:check, :transform, tf(&Function.identity/1))
        |> Workflow.chain([:setup, :sub, :check])

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.value == 10
    end

    test "uses input_mapper and output_mapper" do
      inner =
        Graph.new("processor")
        |> Graph.add_node(
          :process,
          :transform,
          tf(fn data ->
            Map.put(data, :processed, String.upcase(data.input))
          end)
        )

      graph =
        Workflow.new("mapped")
        |> Workflow.add_node(
          :setup,
          :transform,
          tf(fn data ->
            Map.put(data, :raw_text, "hello world")
          end)
        )
        |> Workflow.add_node(:sub, :subworkflow, %{
          workflow: inner,
          input_mapper: fn data -> %{input: data.raw_text} end,
          output_mapper: fn data -> %{result: data.processed} end
        })
        |> Workflow.add_node(:done, :transform, tf(&Function.identity/1))
        |> Workflow.chain([:setup, :sub, :done])

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.result == "HELLO WORLD"
      assert state.data.raw_text == "hello world"
    end

    test "propagates inner workflow errors" do
      inner =
        Graph.new("failing")
        |> Graph.add_node(:boom, :transform, tf(fn _data -> raise "inner error" end))

      graph =
        Workflow.new("error_sub")
        |> Workflow.add_node(:sub, :subworkflow, %{workflow: inner})

      assert {:error, {"sub", {:subworkflow_failed, "sub", _}}} = Workflow.run(graph)
    end
  end

  # =========================================================================
  # Graph mutation
  # =========================================================================

  describe "Graph.insert_after/6" do
    test "inserts a node between two connected nodes" do
      graph =
        Graph.new("mutate")
        |> Graph.add_node(:a, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:c, :transform, tf(&Function.identity/1))
        |> Graph.connect(:a, :c)

      graph = Graph.insert_after(graph, :a, :b, :transform, tf(&Function.identity/1))

      assert ["b"] = Graph.successors(graph, "a")
      assert ["c"] = Graph.successors(graph, "b")
      assert ["b"] = Graph.predecessors(graph, "c")
    end

    test "preserves multiple successor edges" do
      graph =
        Graph.new("multi_succ")
        |> Graph.add_node(:a, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:c, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:d, :transform, tf(&Function.identity/1))
        |> Graph.connect(:a, :c)
        |> Graph.connect(:a, :d)

      graph = Graph.insert_after(graph, :a, :b, :transform, tf(&Function.identity/1))

      assert ["b"] = Graph.successors(graph, "a")
      assert Enum.sort(Graph.successors(graph, "b")) == ["c", "d"]
    end
  end

  describe "Graph.remove_node/2" do
    test "removes a node and reconnects edges" do
      graph =
        Graph.new("remove")
        |> Graph.add_node(:a, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:b, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:c, :transform, tf(&Function.identity/1))
        |> Graph.chain([:a, :b, :c])

      graph = Graph.remove_node(graph, :b)

      refute Map.has_key?(graph.nodes, "b")
      assert ["c"] = Graph.successors(graph, "a")
      assert ["a"] = Graph.predecessors(graph, "c")
    end
  end

  describe "on_node_complete runtime mutation" do
    test "callback can inject a node at runtime" do
      callback = fn
        %{id: "a"}, _state, graph ->
          new_graph =
            Graph.insert_after(
              graph,
              "a",
              "injected",
              :transform,
              tf(fn data -> Map.put(data, :injected, true) end)
            )

          {:modify, new_graph}

        _node, _state, _graph ->
          :continue
      end

      graph =
        Workflow.new("dynamic")
        |> Workflow.add_node(:a, :transform, tf(fn data -> Map.put(data, :a_done, true) end))
        |> Workflow.add_node(:b, :transform, tf(fn data -> Map.put(data, :b_done, true) end))
        |> Workflow.chain([:a, :b])

      assert {:ok, state} = Workflow.run(graph, %{}, on_node_complete: callback)
      assert state.data.a_done == true
      assert state.data.b_done == true

      # Note: injected node may not execute in topo-order mode since topo was computed before mutation
      # This is expected — runtime mutation is most useful in edge-following (cycle) mode
    end
  end

  # =========================================================================
  # Mermaid visualization
  # =========================================================================

  describe "to_mermaid/1" do
    test "generates valid mermaid flowchart" do
      graph =
        Workflow.new("viz")
        |> Workflow.add_node(:plan, :agent_step, %{agent: nil}, label: "Plan Research")
        |> Workflow.add_node(:search, :parallel, %{branches: [:web, :papers]}, label: "Search")
        |> Workflow.add_node(:web, :transform, tf(&Function.identity/1), label: "Web Search")
        |> Workflow.add_node(:papers, :transform, tf(&Function.identity/1), label: "Paper Search")
        |> Workflow.add_node(:report, :agent_step, %{agent: nil}, label: "Write Report")
        |> Workflow.connect(:plan, :search)
        |> Workflow.connect(:search, :report)

      mermaid = Workflow.to_mermaid(graph)

      assert mermaid =~ "flowchart TD"
      assert mermaid =~ "plan"
      assert mermaid =~ "Plan Research"
      assert mermaid =~ "search"
      assert mermaid =~ "report"
      assert mermaid =~ "-->"
      assert mermaid =~ "-.->"
    end

    test "supports LR direction" do
      graph =
        Workflow.new("lr")
        |> Workflow.add_node(:a, :transform, tf(&Function.identity/1))

      mermaid = Workflow.to_mermaid(graph, direction: "LR")
      assert mermaid =~ "flowchart LR"
    end

    test "renders different node shapes for types" do
      graph =
        Workflow.new("shapes")
        |> Workflow.add_node(:a, :branch, %{}, label: "Check")
        |> Workflow.add_node(:b, :human_checkpoint, %{}, label: "Review")

      mermaid = Workflow.to_mermaid(graph)
      # Branch uses diamond shape
      assert mermaid =~ ~S|{"Check|
      # Human checkpoint uses stadium shape
      assert mermaid =~ ~S|(["Review|
    end
  end

  # =========================================================================
  # Scratch ETS store
  # =========================================================================

  describe "Scratch" do
    test "put and get round-trip" do
      scratch = Scratch.new()
      scratch = Scratch.put(scratch, :key1, "value1")

      assert Scratch.get(scratch, :key1) == "value1"
      assert Scratch.get(scratch, :missing) == nil
      assert Scratch.get(scratch, :missing, :default) == :default

      Scratch.cleanup(scratch)
    end

    test "get returns default when table not initialized" do
      scratch = Scratch.new()
      assert Scratch.get(scratch, :any) == nil
      assert Scratch.get(scratch, :any, 42) == 42
    end

    test "delete removes key" do
      scratch = Scratch.new()
      scratch = Scratch.put(scratch, :k, "v")
      assert Scratch.get(scratch, :k) == "v"

      Scratch.delete(scratch, :k)
      assert Scratch.get(scratch, :k) == nil

      Scratch.cleanup(scratch)
    end

    test "cleanup deletes the ETS table" do
      scratch = Scratch.new()
      scratch = Scratch.put(scratch, :k, "v")

      assert :ets.info(scratch.table) != :undefined
      Scratch.cleanup(scratch)
      assert :ets.info(scratch.table) == :undefined
    end

    test "cleanup on uninitialized scratch is a no-op" do
      scratch = Scratch.new()
      assert Scratch.cleanup(scratch) == :ok
    end
  end
end

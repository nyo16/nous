defmodule Nous.Workflow.Phase2Test do
  use ExUnit.Case, async: true

  alias Nous.Workflow
  alias Nous.Workflow.{Graph, Compiler, Engine}

  defp tf(fun), do: %{transform_fn: fun}

  # =========================================================================
  # Cycle support
  # =========================================================================

  describe "cycle detection" do
    test "rejects cycles in DAGs (allows_cycles: false)" do
      # a -> b -> c -> a (cycle)
      graph =
        Graph.new("cycle")
        |> Graph.add_node(:a, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:b, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:c, :transform, tf(&Function.identity/1))
        |> Graph.connect(:a, :b)
        |> Graph.connect(:b, :c)
        |> Graph.connect(:c, :a)

      assert {:error, errors} = Compiler.compile(graph)
      assert Enum.any?(errors, fn {type, _} -> type == :cycle_detected end)
    end

    test "allows cycles when allows_cycles: true" do
      graph =
        Graph.new("cycle", allows_cycles: true)
        |> Graph.add_node(:a, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:b, :transform, tf(&Function.identity/1))
        |> Graph.connect(:a, :b)
        |> Graph.connect(:b, :a)

      assert {:ok, compiled} = Compiler.compile(graph)
      assert MapSet.size(compiled.cycle_nodes) > 0
    end
  end

  describe "cycle execution with max-iteration guards" do
    test "quality gate loop — exits when condition is met" do
      # start -> evaluate -> branch
      #   branch -> done (if quality >= 3)
      #   branch -> improve -> evaluate (loop back)
      graph =
        Graph.new("quality_gate", allows_cycles: true)
        |> Graph.add_node(:start, :transform, tf(fn data -> Map.put(data, :quality, 0) end))
        |> Graph.add_node(
          :improve,
          :transform,
          tf(fn data ->
            Map.update!(data, :quality, &(&1 + 1))
          end)
        )
        |> Graph.add_node(:check, :branch, %{})
        |> Graph.add_node(:done, :transform, tf(fn data -> Map.put(data, :finished, true) end))
        |> Graph.connect(:start, :improve)
        |> Graph.connect(:improve, :check)
        |> Graph.connect(:check, :done, condition: fn s -> s.data.quality >= 3 end)
        |> Graph.connect(:check, :improve, condition: fn s -> s.data.quality < 3 end)

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      assert state.data.quality == 3
      assert state.data.finished == true
    end

    test "cycle terminates at max_iterations" do
      # Infinite loop: a -> b -> a
      graph =
        Graph.new("infinite", allows_cycles: true)
        |> Graph.add_node(
          :a,
          :transform,
          tf(fn data ->
            Map.update(data, :count, 1, &(&1 + 1))
          end)
        )
        |> Graph.add_node(:b, :branch, %{})
        |> Graph.connect(:a, :b)
        |> Graph.connect(:b, :a)

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled, %{}, max_iterations: 5)

      # Should have run node :a at most 5 times
      assert state.data.count <= 5
    end
  end

  # =========================================================================
  # Hooks
  # =========================================================================

  describe "workflow hooks" do
    test "workflow_start and workflow_end hooks fire" do
      log = :ets.new(:hook_log, [:set, :public])

      start_hook = %Nous.Hook{
        event: :workflow_start,
        type: :function,
        handler: fn _event, payload ->
          :ets.insert(log, {:started, payload.workflow_id})
          :allow
        end
      }

      end_hook = %Nous.Hook{
        event: :workflow_end,
        type: :function,
        handler: fn _event, payload ->
          :ets.insert(log, {:ended, payload.status})
          :allow
        end
      }

      graph =
        Workflow.new("hooked")
        |> Workflow.add_node(:step, :transform, tf(&Function.identity/1))

      {:ok, _state} = Workflow.run(graph, %{}, hooks: [start_hook, end_hook])

      assert [{:started, "hooked"}] = :ets.lookup(log, :started)
      assert [{:ended, :completed}] = :ets.lookup(log, :ended)

      :ets.delete(log)
    end

    test "pre_node hook can inspect each node" do
      visited = :ets.new(:visited, [:bag, :public])

      hook = %Nous.Hook{
        event: :pre_node,
        type: :function,
        handler: fn _event, %{node_id: id} ->
          :ets.insert(visited, {:visited, id})
          :allow
        end
      }

      graph =
        Workflow.new("traced")
        |> Workflow.add_node(:a, :transform, tf(&Function.identity/1))
        |> Workflow.add_node(:b, :transform, tf(&Function.identity/1))
        |> Workflow.chain([:a, :b])

      {:ok, _state} = Workflow.run(graph, %{}, hooks: [hook])

      visited_ids = :ets.lookup(visited, :visited) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert visited_ids == ["a", "b"]

      :ets.delete(visited)
    end

    test "post_node hook can modify state" do
      hook = %Nous.Hook{
        event: :post_node,
        type: :function,
        handler: fn
          _event, %{node_id: "a", state: state} ->
            {:modify, Nous.Workflow.State.update_data(state, &Map.put(&1, :injected, true))}

          _event, _payload ->
            :allow
        end
      }

      graph =
        Workflow.new("modify")
        |> Workflow.add_node(:a, :transform, tf(&Function.identity/1))
        |> Workflow.add_node(:b, :transform, tf(&Function.identity/1))
        |> Workflow.chain([:a, :b])

      {:ok, state} = Workflow.run(graph, %{}, hooks: [hook])
      assert state.data.injected == true
    end
  end

  # =========================================================================
  # Pause / Resume
  # =========================================================================

  describe "pause via pre_node hook" do
    test "pauses workflow when hook returns {:pause, reason}" do
      hook = %Nous.Hook{
        event: :pre_node,
        type: :function,
        handler: fn
          _event, %{node_id: "b"} -> {:pause, "review needed"}
          _event, _payload -> :allow
        end
      }

      graph =
        Workflow.new("pausable")
        |> Workflow.add_node(:a, :transform, tf(fn data -> Map.put(data, :a_done, true) end))
        |> Workflow.add_node(:b, :transform, tf(fn data -> Map.put(data, :b_done, true) end))
        |> Workflow.chain([:a, :b])

      {:ok, compiled} = Compiler.compile(graph)
      result = Engine.execute(compiled, %{}, hooks: [hook])

      assert {:suspended, state, checkpoint} = result
      assert state.data.a_done == true
      refute Map.has_key?(state.data, :b_done)
      assert checkpoint.node_id == "b"
      assert checkpoint.reason == "review needed"
    end
  end

  describe "on-demand pause via atomics" do
    test "pauses at next node when pause_ref is signaled" do
      pause_ref = :atomics.new(1, [])

      # Pause after first node executes
      hook = %Nous.Hook{
        event: :post_node,
        type: :function,
        handler: fn _event, %{node_id: "a"} ->
          :atomics.put(pause_ref, 1, 1)
          :allow
        end
      }

      graph =
        Workflow.new("atomic_pause")
        |> Workflow.add_node(:a, :transform, tf(fn data -> Map.put(data, :a_done, true) end))
        |> Workflow.add_node(:b, :transform, tf(fn data -> Map.put(data, :b_done, true) end))
        |> Workflow.chain([:a, :b])

      {:ok, compiled} = Compiler.compile(graph)
      result = Engine.execute(compiled, %{}, hooks: [hook], pause_ref: pause_ref)

      assert {:suspended, state, _checkpoint} = result
      assert state.data.a_done == true
      refute Map.has_key?(state.data, :b_done)
    end
  end

  # =========================================================================
  # Human checkpoint
  # =========================================================================

  describe "human_checkpoint node" do
    test "approves and continues when handler returns :approve" do
      graph =
        Workflow.new("approval")
        |> Workflow.add_node(
          :generate,
          :transform,
          tf(fn data -> Map.put(data, :content, "draft") end)
        )
        |> Workflow.add_node(:review, :human_checkpoint, %{
          handler: fn _state, _prompt -> :approve end
        })
        |> Workflow.add_node(
          :publish,
          :transform,
          tf(fn data -> Map.put(data, :published, true) end)
        )
        |> Workflow.chain([:generate, :review, :publish])

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.content == "draft"
      assert state.data.published == true
      assert state.node_results["review"] == :approved
    end

    test "edits state when handler returns {:edit, state}" do
      graph =
        Workflow.new("edit_flow")
        |> Workflow.add_node(
          :generate,
          :transform,
          tf(fn data -> Map.put(data, :text, "bad") end)
        )
        |> Workflow.add_node(:review, :human_checkpoint, %{
          handler: fn state, _prompt ->
            {:edit, Nous.Workflow.State.update_data(state, &Map.put(&1, :text, "good"))}
          end
        })
        |> Workflow.add_node(:finish, :transform, tf(&Function.identity/1))
        |> Workflow.chain([:generate, :review, :finish])

      assert {:ok, state} = Workflow.run(graph)
      assert state.data.text == "good"
    end

    test "rejects and fails workflow" do
      graph =
        Workflow.new("reject_flow")
        |> Workflow.add_node(:generate, :transform, tf(&Function.identity/1))
        |> Workflow.add_node(:review, :human_checkpoint, %{
          handler: fn _state, _prompt -> :reject end
        })
        |> Workflow.chain([:generate, :review])

      assert {:error, {"review", {:rejected, _}}} = Workflow.run(graph)
    end

    test "suspends when no handler is provided" do
      graph =
        Workflow.new("no_handler")
        |> Workflow.add_node(:step, :transform, tf(fn data -> Map.put(data, :done, true) end))
        |> Workflow.add_node(:review, :human_checkpoint, %{prompt: "Please review"})
        |> Workflow.chain([:step, :review])

      {:ok, compiled} = Compiler.compile(graph)
      result = Engine.execute(compiled)

      assert {:suspended, state, checkpoint} = result
      assert state.data.done == true
      assert checkpoint.node_id == "review"
    end
  end
end

defmodule Nous.Workflow.EngineTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow
  alias Nous.Workflow.{Graph, Compiler, Engine, State}

  # Helper to build transform config
  defp tf(fun), do: %{transform_fn: fun}

  describe "linear execution with transform nodes" do
    test "executes nodes in topological order, threading state" do
      graph =
        Graph.new("counter")
        |> Graph.add_node(:init, :transform, tf(fn data -> Map.put(data, :count, 0) end))
        |> Graph.add_node(
          :inc1,
          :transform,
          tf(fn data -> Map.update!(data, :count, &(&1 + 1)) end)
        )
        |> Graph.add_node(
          :inc2,
          :transform,
          tf(fn data -> Map.update!(data, :count, &(&1 + 1)) end)
        )
        |> Graph.add_node(
          :double,
          :transform,
          tf(fn data -> Map.update!(data, :count, &(&1 * 2)) end)
        )
        |> Graph.chain([:init, :inc1, :inc2, :double])

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      # 0 -> +1 -> +1 -> *2 = 4
      assert state.data.count == 4
    end

    test "records results for each node" do
      graph =
        Graph.new("results")
        |> Graph.add_node(:a, :transform, tf(fn data -> Map.put(data, :a_ran, true) end))
        |> Graph.add_node(:b, :transform, tf(fn data -> Map.put(data, :b_ran, true) end))
        |> Graph.chain([:a, :b])

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      assert state.node_results["a"] == :ok
      assert state.node_results["b"] == :ok
      assert state.data.a_ran == true
      assert state.data.b_ran == true
    end

    test "passes initial data through workflow" do
      graph =
        Graph.new("with_data")
        |> Graph.add_node(
          :greet,
          :transform,
          tf(fn data ->
            Map.put(data, :greeting, "Hello, #{data.name}!")
          end)
        )

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled, %{name: "World"})

      assert state.data.greeting == "Hello, World!"
      assert state.data.name == "World"
    end
  end

  describe "branch execution" do
    test "follows conditional edge when predicate matches" do
      graph =
        Graph.new("branch_test")
        |> Graph.add_node(:start, :transform, tf(fn data -> Map.put(data, :value, 10) end))
        |> Graph.add_node(:check, :branch, %{})
        |> Graph.add_node(:high, :transform, tf(fn data -> Map.put(data, :path, :high) end))
        |> Graph.add_node(:low, :transform, tf(fn data -> Map.put(data, :path, :low) end))
        |> Graph.connect(:start, :check)
        |> Graph.connect(:check, :high, condition: fn s -> s.data.value >= 5 end)
        |> Graph.connect(:check, :low, condition: fn s -> s.data.value < 5 end)

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      assert state.data.path == :high
    end

    test "follows default edge when no condition matches" do
      graph =
        Graph.new("branch_default")
        |> Graph.add_node(:start, :transform, tf(fn data -> Map.put(data, :value, 3) end))
        |> Graph.add_node(:check, :branch, %{})
        |> Graph.add_node(:special, :transform, tf(fn data -> Map.put(data, :path, :special) end))
        |> Graph.add_node(
          :default_path,
          :transform,
          tf(fn data -> Map.put(data, :path, :default) end)
        )
        |> Graph.connect(:start, :check)
        |> Graph.connect(:check, :special, condition: fn s -> s.data.value > 100 end)
        |> Graph.connect(:check, :default_path, default: true)

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      assert state.data.path == :default
    end
  end

  describe "error strategies" do
    test "fail_fast halts workflow on error" do
      graph =
        Graph.new("fail_fast")
        |> Graph.add_node(:ok_step, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:bad_step, :transform, tf(fn _data -> raise "boom" end))
        |> Graph.add_node(:never, :transform, tf(fn data -> Map.put(data, :reached, true) end))
        |> Graph.chain([:ok_step, :bad_step, :never])

      {:ok, compiled} = Compiler.compile(graph)
      assert {:error, {"bad_step", _reason}} = Engine.execute(compiled)
    end

    test "skip strategy records error and continues" do
      graph =
        Graph.new("skip_test")
        |> Graph.add_node(:ok_step, :transform, tf(&Function.identity/1))
        |> Graph.add_node(:bad_step, :transform, tf(fn _data -> raise "boom" end),
          error_strategy: :skip
        )
        |> Graph.add_node(:after, :transform, tf(fn data -> Map.put(data, :reached, true) end))
        |> Graph.chain([:ok_step, :bad_step, :after])

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      assert state.data.reached == true
      assert [{"bad_step", _}] = state.errors
    end

    test "retry strategy retries on failure" do
      # Use a counter in process dictionary to track attempts
      counter = :counters.new(1, [:atomics])

      graph =
        Graph.new("retry_test")
        |> Graph.add_node(
          :flaky,
          :transform,
          tf(fn data ->
            attempt = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, attempt)

            if attempt < 3 do
              raise "not yet (attempt #{attempt})"
            else
              Map.put(data, :attempts, attempt)
            end
          end),
          error_strategy: {:retry, 3, 0}
        )

      {:ok, compiled} = Compiler.compile(graph)
      assert {:ok, state} = Engine.execute(compiled)

      assert state.data.attempts == 3
    end
  end

  describe "top-level Workflow.run/2,3" do
    test "compiles and executes in one step" do
      graph =
        Workflow.new("simple")
        |> Workflow.add_node(
          :greet,
          :transform,
          tf(fn data ->
            Map.put(data, :message, "Hello!")
          end)
        )

      assert {:ok, state} = Workflow.run(graph, %{})
      assert state.data.message == "Hello!"
    end

    test "returns compile errors for invalid graph" do
      graph = Workflow.new("empty")
      assert {:error, _errors} = Workflow.run(graph)
    end

    test "passes options through to engine" do
      graph =
        Workflow.new("with_deps")
        |> Workflow.add_node(:check_deps, :transform, tf(&Function.identity/1))

      assert {:ok, state} = Workflow.run(graph, %{}, deps: %{db: :mock})
      assert state.metadata.deps == %{db: :mock}
    end
  end
end

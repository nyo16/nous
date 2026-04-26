defmodule Nous.Workflow.Phase4Test do
  use ExUnit.Case, async: true

  alias Nous.Workflow
  alias Nous.Workflow.{Trace, Checkpoint}

  defp tf(fun), do: %{transform_fn: fun}

  # =========================================================================
  # Trace
  # =========================================================================

  describe "execution trace" do
    test "records trace entries when trace: true" do
      graph =
        Workflow.new("traced")
        |> Workflow.add_node(:a, :transform, tf(fn data -> Map.put(data, :a, 1) end))
        |> Workflow.add_node(:b, :transform, tf(fn data -> Map.put(data, :b, 2) end))
        |> Workflow.add_node(:c, :transform, tf(fn data -> Map.put(data, :c, 3) end))
        |> Workflow.chain([:a, :b, :c])

      assert {:ok, state} = Workflow.run(graph, %{}, trace: true)

      trace = state.metadata.trace
      assert %Trace{} = trace
      assert Trace.node_count(trace) == 3

      [entry_a, entry_b, entry_c] = trace.entries
      assert entry_a.node_id == "a"
      assert entry_a.node_type == :transform
      assert entry_a.status == :completed
      assert entry_a.duration_ms >= 0

      assert entry_b.node_id == "b"
      assert entry_c.node_id == "c"
    end

    test "no trace attached when trace: false (default)" do
      graph =
        Workflow.new("no_trace")
        |> Workflow.add_node(:a, :transform, tf(&Function.identity/1))

      assert {:ok, state} = Workflow.run(graph)
      refute Map.has_key?(state.metadata, :trace)
    end

    test "trace records failed nodes" do
      graph =
        Workflow.new("fail_trace")
        |> Workflow.add_node(:good, :transform, tf(&Function.identity/1))
        |> Workflow.add_node(:bad, :transform, tf(fn _data -> raise "boom" end))
        |> Workflow.chain([:good, :bad])

      assert {:error, {"bad", _}} = Workflow.run(graph, %{}, trace: true)
    end
  end

  describe "Trace struct" do
    test "new creates empty trace" do
      trace = Trace.new()
      assert trace.entries == []
      assert is_binary(trace.run_id)
      assert %DateTime{} = trace.started_at
    end

    test "record adds entry and total_duration_ms works" do
      trace =
        Trace.new()
        |> Trace.record("a", :transform, 1_000_000, :completed)
        |> Trace.record("b", :transform, 2_000_000, :completed)

      assert Trace.node_count(trace) == 2
      assert Trace.total_duration_ms(trace) >= 0
    end
  end

  # =========================================================================
  # Telemetry
  # =========================================================================

  describe "telemetry events" do
    test "emits workflow start and stop events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-wf-start-#{inspect(ref)}",
        [:nous, :workflow, :run, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:wf_start, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-wf-stop-#{inspect(ref)}",
        [:nous, :workflow, :run, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:wf_stop, measurements, metadata})
        end,
        nil
      )

      graph =
        Workflow.new("telemetry_test")
        |> Workflow.add_node(:step, :transform, tf(&Function.identity/1))

      {:ok, _state} = Workflow.run(graph)

      assert_receive {:wf_start, %{system_time: _},
                      %{workflow_id: "telemetry_test", node_count: 1}}

      assert_receive {:wf_stop, %{duration: _},
                      %{workflow_id: "telemetry_test", status: :completed}}

      :telemetry.detach("test-wf-start-#{inspect(ref)}")
      :telemetry.detach("test-wf-stop-#{inspect(ref)}")
    end

    test "emits node start and stop events" do
      ref = make_ref()
      _test_pid = self()
      events = :ets.new(:node_events, [:bag, :public])

      :telemetry.attach(
        "test-node-start-#{inspect(ref)}",
        [:nous, :workflow, :node, :start],
        fn _event, _measurements, metadata, _config ->
          :ets.insert(events, {:start, metadata.node_id})
        end,
        nil
      )

      :telemetry.attach(
        "test-node-stop-#{inspect(ref)}",
        [:nous, :workflow, :node, :stop],
        fn _event, _measurements, metadata, _config ->
          :ets.insert(events, {:stop, metadata.node_id, metadata.success})
        end,
        nil
      )

      graph =
        Workflow.new("node_telemetry")
        |> Workflow.add_node(:a, :transform, tf(&Function.identity/1))
        |> Workflow.add_node(:b, :transform, tf(&Function.identity/1))
        |> Workflow.chain([:a, :b])

      {:ok, _state} = Workflow.run(graph)

      starts = :ets.lookup(events, :start) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert starts == ["a", "b"]

      stops = :ets.lookup(events, :stop) |> Enum.map(&{elem(&1, 1), elem(&1, 2)})
      assert {"a", true} in stops
      assert {"b", true} in stops

      :telemetry.detach("test-node-start-#{inspect(ref)}")
      :telemetry.detach("test-node-stop-#{inspect(ref)}")
      :ets.delete(events)
    end
  end

  # =========================================================================
  # Checkpoint
  # =========================================================================

  describe "Checkpoint" do
    test "creates checkpoint from attrs" do
      state = Nous.Workflow.State.new(%{data: 1})

      cp =
        Checkpoint.new(%{
          workflow_id: "wf1",
          node_id: "step2",
          state: state,
          reason: "paused"
        })

      assert cp.workflow_id == "wf1"
      assert cp.node_id == "step2"
      assert cp.status == :suspended
      assert cp.reason == "paused"
      assert %DateTime{} = cp.created_at
      assert is_binary(cp.run_id)
    end
  end

  describe "Checkpoint.ETS store" do
    alias Nous.Workflow.Checkpoint.ETS, as: Store

    test "save and load round-trip" do
      state = Nous.Workflow.State.new(%{x: 1})

      cp =
        Checkpoint.new(%{
          workflow_id: "wf_ets",
          node_id: "s1",
          state: state
        })

      assert :ok = Store.save(cp)
      assert {:ok, loaded} = Store.load(cp.run_id)
      assert loaded.workflow_id == "wf_ets"
      assert loaded.state.data.x == 1
    end

    test "load returns error for missing" do
      assert {:error, :not_found} = Store.load("nonexistent")
    end

    test "list returns checkpoints for workflow" do
      state = Nous.Workflow.State.new()

      cp1 = Checkpoint.new(%{workflow_id: "wf_list", node_id: "a", state: state})
      cp2 = Checkpoint.new(%{workflow_id: "wf_list", node_id: "b", state: state})
      cp3 = Checkpoint.new(%{workflow_id: "other_wf", node_id: "c", state: state})

      Store.save(cp1)
      Store.save(cp2)
      Store.save(cp3)

      {:ok, results} = Store.list("wf_list")
      assert length(results) == 2
      assert Enum.all?(results, &(&1.workflow_id == "wf_list"))
    end

    test "delete removes checkpoint" do
      state = Nous.Workflow.State.new()
      cp = Checkpoint.new(%{workflow_id: "wf_del", node_id: "a", state: state})

      Store.save(cp)
      assert {:ok, _} = Store.load(cp.run_id)

      Store.delete(cp.run_id)
      assert {:error, :not_found} = Store.load(cp.run_id)
    end
  end
end

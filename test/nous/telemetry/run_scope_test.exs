defmodule Nous.Telemetry.RunScopeTest do
  use ExUnit.Case, async: true

  alias Nous.Telemetry.RunScope

  @key :"$nous_run_scope"
  @correlation_keys [:trace_id, :agent_run_id, :parent_agent_run_id, :tool_call_id]

  describe "metadata/0" do
    test "every correlation key is present and nil outside a scope" do
      assert RunScope.metadata() == Map.new(@correlation_keys, &{&1, nil})
    end

    test "reads the installed scope" do
      RunScope.with_scope(%{trace_id: "t", agent_run_id: "r", tool_call_id: "c"}, fn ->
        assert RunScope.metadata() == %{
                 trace_id: "t",
                 agent_run_id: "r",
                 parent_agent_run_id: nil,
                 tool_call_id: "c"
               }
      end)
    end

    test "walks $callers into a task" do
      RunScope.with_scope(%{trace_id: "t", agent_run_id: "r"}, fn ->
        assert %{trace_id: "t", agent_run_id: "r"} =
                 Task.async(fn -> RunScope.metadata() end) |> Task.await()
      end)
    end
  end

  describe "totality over malformed state" do
    test "a non-map scope in the dictionary reads as no scope" do
      for garbage <- [:garbage, "scope", 42, [trace_id: "t"], {:trace_id, "t"}] do
        Process.put(@key, garbage)
        assert RunScope.current() == nil
        assert RunScope.metadata() == Map.new(@correlation_keys, &{&1, nil})
      end
    after
      Process.delete(@key)
    end

    test "non-binary ids and unknown keys never leak into metadata" do
      scope = %{trace_id: :atom_id, agent_run_id: 123, tool_call_id: %{}, other: "x"}

      assert RunScope.metadata(scope) == Map.new(@correlation_keys, &{&1, nil})
      assert RunScope.metadata(nil) == Map.new(@correlation_keys, &{&1, nil})
      assert RunScope.metadata({:not, :a, :map}) == Map.new(@correlation_keys, &{&1, nil})
    end

    test "garbage in $callers (atoms, dead and non-pid entries) does not raise" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      Process.put(:"$callers", [:not_a_pid, dead, "string", self()])
      assert RunScope.current() == nil
      assert %{trace_id: nil} = RunScope.metadata()

      Process.put(:"$callers", :not_a_list)
      assert RunScope.current() == nil
    after
      Process.delete(:"$callers")
    end

    test "start_run/1 tolerates a malformed parent and run labels" do
      run =
        RunScope.start_run(%{
          trace_id: 7,
          agent_run_id: :x,
          role: "judge",
          sub_agent_template: :worker,
          sub_agent_index: -1
        })

      assert run.trace_id =~ ~r/\A[0-9a-f]{32}\z/
      assert run.parent_agent_run_id == nil
      assert run.role == :agent
      assert run.sub_agent_template == nil
      assert run.sub_agent_index == nil

      assert %{role: :agent, parent_tool_call_id: nil, profile_id: nil} =
               RunScope.run_start_metadata(:garbage)
    end
  end

  describe "with_scope/2" do
    test "restores the previous scope after the function returns or raises" do
      RunScope.with_scope(%{trace_id: "outer"}, fn ->
        RunScope.with_scope(%{trace_id: "inner"}, fn ->
          assert RunScope.metadata().trace_id == "inner"
        end)

        assert RunScope.metadata().trace_id == "outer"

        assert_raise RuntimeError, fn ->
          RunScope.with_scope(%{trace_id: "inner"}, fn -> raise "boom" end)
        end

        assert RunScope.metadata().trace_id == "outer"
      end)

      assert Process.get(@key) == nil
    end

    test "bind/1 carries the scope into a process that has no $callers" do
      parent = self()

      fun =
        RunScope.with_scope(%{trace_id: "t", agent_run_id: "r"}, fn ->
          RunScope.bind(fn -> send(parent, {:meta, RunScope.metadata()}) end)
        end)

      spawn(fun)
      assert_receive {:meta, %{trace_id: "t", agent_run_id: "r"}}
    end
  end

  describe "start_run/1" do
    test "inherits the trace, mints a run id and links the parent run and tool call" do
      parent = %{trace_id: "t", agent_run_id: "parent", tool_call_id: "call_1", role: :judge}
      run = RunScope.start_run(parent)

      assert run.trace_id == "t"
      assert run.agent_run_id =~ ~r/\A[0-9a-f]{16}\z/
      assert run.parent_agent_run_id == "parent"
      assert run.parent_tool_call_id == "call_1"
      assert run.tool_call_id == nil
      assert run.role == :judge
    end

    test "sub-agent labels reach the run but not the installed scope" do
      run = RunScope.start_run(%{sub_agent_template: "worker", sub_agent_index: 2})

      assert %{sub_agent_template: "worker", sub_agent_index: 2} =
               RunScope.run_start_metadata(run)

      installed = RunScope.install_scope(run)
      refute Map.has_key?(installed, :sub_agent_template)
      refute Map.has_key?(installed, :sub_agent_index)
      assert RunScope.start_run(installed).sub_agent_template == nil
    end
  end
end

defmodule Nous.Workflow.StateTest do
  use ExUnit.Case, async: true

  alias Nous.Workflow.State

  describe "new/0,1" do
    test "creates empty state" do
      state = State.new()
      assert state.data == %{}
      assert state.node_results == %{}
      assert state.errors == []
      assert %DateTime{} = state.started_at
    end

    test "creates state with initial data" do
      state = State.new(%{query: "test", limit: 10})
      assert state.data == %{query: "test", limit: 10}
    end
  end

  describe "put_result/3" do
    test "records a node result" do
      state =
        State.new()
        |> State.put_result("fetch", %{urls: ["a.com", "b.com"]})

      assert state.node_results["fetch"] == %{urls: ["a.com", "b.com"]}
    end

    test "updates timestamp" do
      state = State.new()
      original_time = state.updated_at
      Process.sleep(1)
      updated = State.put_result(state, "node", :ok)
      assert DateTime.compare(updated.updated_at, original_time) in [:gt, :eq]
    end
  end

  describe "put_error/3" do
    test "records an error" do
      state =
        State.new()
        |> State.put_error("fetch", :timeout)

      assert [{"fetch", :timeout}] = state.errors
    end

    test "prepends errors (most recent first)" do
      state =
        State.new()
        |> State.put_error("a", :error_a)
        |> State.put_error("b", :error_b)

      assert [{"b", :error_b}, {"a", :error_a}] = state.errors
    end
  end

  describe "update_data/2" do
    test "updates data with function" do
      state =
        State.new(%{count: 1})
        |> State.update_data(&Map.update!(&1, :count, fn c -> c + 1 end))

      assert state.data.count == 2
    end
  end
end

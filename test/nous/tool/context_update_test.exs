defmodule Nous.Tool.ContextUpdateTest do
  use ExUnit.Case, async: true

  alias Nous.Tool.ContextUpdate
  alias Nous.Agent.Context
  alias Nous.RunContext

  # Reference implementation = the pre-optimization semantics (append via
  # `++ [item]`). The optimized reduce must produce byte-identical deps.
  defp reference_reduce(ops, initial) do
    Enum.reduce(ops, initial, fn
      {:set, k, v}, acc -> Map.put(acc, k, v)
      {:merge, k, m}, acc -> Map.put(acc, k, ref_deep_merge(Map.get(acc, k, %{}), m))
      {:append, k, item}, acc -> Map.put(acc, k, (Map.get(acc, k) || []) ++ [item])
      {:delete, k}, acc -> Map.delete(acc, k)
    end)
  end

  defp ref_deep_merge(l, r) when is_map(l) and is_map(r) do
    Map.merge(l, r, fn
      _k, lv, rv when is_map(lv) and is_map(rv) -> ref_deep_merge(lv, rv)
      _k, _lv, rv -> rv
    end)
  end

  defp ref_deep_merge(_l, r), do: r

  defp apply_ops(ops, initial_deps \\ %{}) do
    update = %ContextUpdate{operations: ops}
    ContextUpdate.apply(update, Context.new(deps: initial_deps)).deps
  end

  describe "append ordering (Finding #3)" do
    test "pure appends preserve insertion order" do
      ops = [{:append, :log, :a}, {:append, :log, :b}, {:append, :log, :c}]
      assert %{log: [:a, :b, :c]} = apply_ops(ops)
    end

    test "appends extend a pre-existing deps list in order" do
      ops = [{:append, :log, :b}, {:append, :log, :c}]
      assert %{log: [:a, :b, :c]} = apply_ops(ops, %{log: [:a]})
    end

    test "set of a multi-element list followed by append keeps order" do
      ops = [{:set, :k, [9, 8]}, {:append, :k, 1}]
      assert %{k: [9, 8, 1]} = apply_ops(ops)
    end

    test "append followed by set discards the appended list" do
      ops = [{:append, :k, 1}, {:set, :k, [9, 8]}]
      assert %{k: [9, 8]} = apply_ops(ops)
    end

    test "delete between appends resets accumulation" do
      ops = [{:append, :k, 1}, {:append, :k, 2}, {:delete, :k}, {:append, :k, 3}]
      assert %{k: [3]} = apply_ops(ops)
    end

    test "large append run is correct (the O(n^2) -> O(n) case)" do
      ops = Enum.map(1..2_000, &{:append, :log, &1})
      assert %{log: log} = apply_ops(ops)
      assert log == Enum.to_list(1..2_000)
    end

    test "interleaved keys keep independent order" do
      ops = [
        {:append, :a, 1},
        {:append, :b, :x},
        {:append, :a, 2},
        {:append, :b, :y},
        {:append, :a, 3}
      ]

      assert %{a: [1, 2, 3], b: [:x, :y]} = apply_ops(ops)
    end
  end

  describe "differential vs reference implementation" do
    test "a mixed operation sequence matches the old ++ semantics exactly" do
      initial = %{existing: [0], counter: 1, settings: %{a: %{b: 1}}}

      ops = [
        {:append, :existing, 1},
        {:append, :existing, 2},
        {:set, :counter, 5},
        {:merge, :settings, %{a: %{c: 2}, d: 3}},
        {:append, :new, "first"},
        {:append, :new, "second"},
        {:set, :replaced, [10, 11]},
        {:append, :replaced, 12},
        {:delete, :existing},
        {:append, :existing, :restored}
      ]

      assert apply_ops(ops, initial) == reference_reduce(ops, initial)
    end
  end

  describe "apply_to_run_context/2" do
    test "applies the same append semantics to a RunContext" do
      update =
        ContextUpdate.new()
        |> ContextUpdate.append(:log, :a)
        |> ContextUpdate.append(:log, :b)

      run_ctx = ContextUpdate.apply_to_run_context(update, RunContext.new(%{log: [:start]}))
      assert %{log: [:start, :a, :b]} = run_ctx.deps
    end
  end
end

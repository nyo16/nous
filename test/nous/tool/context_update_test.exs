defmodule Nous.Tool.ContextUpdateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nous.Tool.ContextUpdate
  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.RunContext
  alias Nous.Session.Log

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

  describe "log_event/3" do
    test "records the operation in place, interleaved with deps operations" do
      update =
        ContextUpdate.new()
        |> ContextUpdate.set(:a, 1)
        |> ContextUpdate.log_event(:tool_call, %{id: "sub_1"})
        |> ContextUpdate.append(:log, :x)
        |> ContextUpdate.log_event(:tool_call, %{id: "sub_2"})

      assert ContextUpdate.operations(update) == [
               {:set, :a, 1},
               {:log_event, :tool_call, %{id: "sub_1"}},
               {:append, :log, :x},
               {:log_event, :tool_call, %{id: "sub_2"}}
             ]

      assert ContextUpdate.log_events(update) == [
               {:tool_call, %{id: "sub_1"}},
               {:tool_call, %{id: "sub_2"}}
             ]
    end

    test "an update carrying only events still has operations" do
      refute ContextUpdate.empty?(ContextUpdate.log_event(ContextUpdate.new(), :tool_call, %{}))
    end
  end

  describe "apply/2 with log events" do
    test "the event lands in the session log and messages are untouched" do
      ctx = Context.new(messages: [Message.user("hi")], deps: %{count: 0})

      update =
        ContextUpdate.new()
        |> ContextUpdate.set(:count, 1)
        |> ContextUpdate.log_event(:tool_call, %{id: "sub_1", name: "file_read"})

      new_ctx = ContextUpdate.apply(update, ctx)

      # Both halves, or the test proves nothing: recorded *and* invisible to the
      # model. Either one alone passes for a broken implementation.
      assert new_ctx.deps == %{count: 1}
      assert new_ctx.messages == ctx.messages

      assert [%{type: :tool_call, data: %{id: "sub_1", name: "file_read"}}] =
               bookkeeping(new_ctx)
    end

    test "deps operations apply first, then every event in the order added" do
      update =
        ContextUpdate.new()
        |> ContextUpdate.append(:calls, "one")
        |> ContextUpdate.log_event(:tool_call, %{seq: 1})
        |> ContextUpdate.append(:calls, "two")
        |> ContextUpdate.log_event(:tool_call, %{seq: 2})
        |> ContextUpdate.log_event(:tool_call, %{seq: 3})

      new_ctx = ContextUpdate.apply(update, Context.new())

      assert new_ctx.deps == %{calls: ["one", "two"]}
      assert Enum.map(bookkeeping(new_ctx), & &1.data.seq) == [1, 2, 3]
    end

    test "an events-only update leaves deps untouched and reports no keys updated" do
      attach_context_update_telemetry()

      deps = %{existing: [1, 2]}
      ctx = Context.new(deps: deps)

      update =
        ContextUpdate.new()
        |> ContextUpdate.log_event(:tool_call, %{id: "sub_1"})
        |> ContextUpdate.log_event(:tool_call, %{id: "sub_2"})

      new_ctx = ContextUpdate.apply(update, ctx)

      assert new_ctx.deps == deps
      assert length(bookkeeping(new_ctx)) == 2

      # An event type is not a deps key. Counting one here would tell every
      # telemetry consumer that deps changed when nothing did.
      assert_receive {:context_update, %{keys_updated: 0}, %{keys: []}}
    end

    test "a surface type is refused, so an event cannot smuggle content into the transcript" do
      ctx = Context.new(messages: [Message.user("hi")])

      update = ContextUpdate.log_event(ContextUpdate.new(), :user_message, %{content: "injected"})

      log =
        capture_log(fn ->
          new_ctx = ContextUpdate.apply(update, ctx)
          assert new_ctx.messages == ctx.messages
          assert bookkeeping(new_ctx) == []
        end)

      assert log =~ "refuses the surface type"
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

    test "drops log events loudly and still applies the deps operations" do
      update =
        ContextUpdate.new()
        |> ContextUpdate.set(:count, 1)
        |> ContextUpdate.log_event(:tool_call, %{id: "sub_1"})
        |> ContextUpdate.log_event(:step_start, %{step: 2})

      run_ctx = RunContext.new(%{count: 0})

      {updated, log} =
        with_log(fn -> ContextUpdate.apply_to_run_context(update, run_ctx) end)

      # A RunContext has no session log, so the events cannot be honoured. The
      # warning is the contract: a silently discarded audit record looks like it
      # worked.
      assert updated.deps == %{count: 1}
      assert log =~ "dropping 2 log event(s)"
      assert log =~ "[:tool_call, :step_start]"
    end

    test "says nothing when there is nothing to drop" do
      update = ContextUpdate.set(ContextUpdate.new(), :count, 1)

      {_updated, log} =
        with_log(fn -> ContextUpdate.apply_to_run_context(update, RunContext.new(%{})) end)

      refute log =~ "dropping"
    end
  end

  describe "to_deps/2 — the one reducer the runner also uses" do
    # `Nous.AgentRunner.ToolExecution.context_update_to_map/1` used to be a
    # second, independent fold starting from an empty map. These pin the two
    # cases the prepend optimisation could get wrong, against a reference
    # implementation of the pre-optimisation `++` semantics.
    test "set of a list then append is byte-identical to the old ++ fold" do
      ops = [{:set, :k, [9, 8]}, {:append, :k, 1}, {:append, :k, 2}]

      assert ContextUpdate.to_deps(%ContextUpdate{operations: ops}) ==
               reference_reduce(ops, %{})
    end

    test "many appends to one key are byte-identical to the old ++ fold" do
      ops = Enum.map(1..2_000, &{:append, :log, &1})

      assert ContextUpdate.to_deps(%ContextUpdate{operations: ops}) ==
               reference_reduce(ops, %{})
    end

    test "interleaved log events do not perturb the deps fold" do
      deps_ops = [
        {:set, :k, [9, 8]},
        {:append, :k, 1},
        {:append, :other, :x},
        {:delete, :gone}
      ]

      mixed = [
        {:log_event, :tool_call, %{seq: 1}},
        {:set, :k, [9, 8]},
        {:append, :k, 1},
        {:log_event, :tool_call, %{seq: 2}},
        {:append, :other, :x},
        {:delete, :gone},
        {:log_event, :tool_call, %{seq: 3}}
      ]

      initial = %{gone: true}

      assert ContextUpdate.to_deps(%ContextUpdate{operations: mixed}, initial) ==
               reference_reduce(deps_ops, initial)
    end

    test "merge is a deep merge, as merge/3 documents" do
      # The runner's duplicate fold used a shallow `Map.merge` here and dropped
      # the untouched nested branch. One reducer, one answer — this one.
      ops = [{:set, :settings, %{a: %{b: 1}}}, {:merge, :settings, %{a: %{c: 2}}}]

      assert ContextUpdate.to_deps(%ContextUpdate{operations: ops}) ==
               %{settings: %{a: %{b: 1, c: 2}}}
    end
  end

  # Only the events the model never sees. `Context.new(messages: ...)` seeds the
  # log with surface events, which are not what these tests are about.
  defp bookkeeping(%Context{log: log}) do
    log |> Log.events() |> Enum.reject(&Nous.Session.Event.surface?/1)
  end

  defp attach_context_update_telemetry do
    test_pid = self()
    handler_id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(
      handler_id,
      [:nous, :context, :update],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {:context_update, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end

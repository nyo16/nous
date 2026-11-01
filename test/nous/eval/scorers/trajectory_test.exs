defmodule Nous.Eval.Scorers.TrajectoryTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Score, ScorerError}
  alias Nous.Eval.Scorers.Trajectory
  alias Nous.Eval.TraceBuilder, as: B

  defp score(trace, opts) do
    {:ok, config} = Trajectory.init(opts)
    Trajectory.score(B.input(trace), config)
  end

  defp passed?(trace, opts) do
    case score(trace, opts) do
      {:ok, %Score{passed?: passed?}} -> passed?
      other -> flunk("expected a score, got #{inspect(other)}")
    end
  end

  defp e(name, args \\ nil), do: if(args, do: %{name: name, args: args}, else: %{name: name})

  describe "mode matrix" do
    # actual: search, lookup, notify (one call per model response)
    @actual [{"search", %{"q" => 1}}, {"lookup", %{"id" => 2}}, {"notify", %{}}]

    @cases [
      {"same sequence", ~w(search lookup notify),
       %{strict: true, in_order: true, unordered: true, superset: true, subset: true}},
      {"reordered", ~w(lookup search notify),
       %{strict: false, in_order: false, unordered: true, superset: true, subset: true}},
      {"subsequence", ~w(search notify),
       %{strict: false, in_order: true, unordered: false, superset: true, subset: false}},
      {"one more expected", ~w(search lookup notify refund),
       %{strict: false, in_order: false, unordered: false, superset: false, subset: true}},
      {"reordered subsequence", ~w(notify search),
       %{strict: false, in_order: false, unordered: false, superset: true, subset: false}}
    ]

    for {label, expected, results} <- @cases, {mode, want} <- results do
      @tag expected: expected, mode: mode, want: want
      test "#{label} in #{mode} mode #{if want, do: "passes", else: "fails"}", ctx do
        trace = B.trajectory(@actual)
        expected = Enum.map(ctx.expected, &e/1)
        assert passed?(trace, expected: expected, mode: ctx.mode) == ctx.want
      end
    end
  end

  describe "matching" do
    test "a wildcard listed before a specific entry does not steal its call (greedy would fail)" do
      trace = B.trajectory([{"search", %{"q" => "specific"}}, {"search", %{"q" => "other"}}])
      expected = [e("search"), e("search", %{"q" => "specific"})]

      for mode <- [:superset, :unordered, :subset] do
        assert passed?(trace, expected: expected, mode: mode), "#{mode} should match"
      end
    end

    test "repeated calls are a multiset; count relaxes it" do
      one = B.trajectory([{"search", %{}}])
      three = B.trajectory([{"search", %{}}, {"search", %{}}, {"search", %{}}])

      refute passed?(one, expected: [e("search"), e("search")])
      assert passed?(one, expected: [%{name: "search", count: {1, 2}}], mode: :unordered)
      refute passed?(three, expected: [%{name: "search", count: {1, 2}}], mode: :unordered)
      assert passed?(three, expected: [%{"name" => "search", "count" => [1, 3]}], mode: :strict)
      assert passed?(three, expected: [%{name: "search", count: 3}], mode: :in_order)
    end

    test "parallel calls of one response compare order-free within the batch" do
      trace = B.trajectory([[{"b", %{}}, {"a", %{}}], {"c", %{}}])

      assert passed?(trace, expected: [e("a"), e("b"), e("c")], mode: :strict)
      assert passed?(trace, expected: [e("a"), e("c")], mode: :in_order)

      refute passed?(trace,
               expected: [e("a"), e("b"), e("c")],
               mode: :strict,
               parallel: :as_emitted
             )

      refute passed?(trace, expected: [e("c"), e("a"), e("b")], mode: :strict)
      refute passed?(trace, expected: [e("c"), e("a")], mode: :in_order)
    end

    test "out-of-order and missing calls are explained in details" do
      trace = B.trajectory([{"lookup", %{}}, {"search", %{}}, {"extra", %{}}])

      assert {:ok, %Score{passed?: false, details: details, reason: reason}} =
               score(trace, expected: [e("search"), e("lookup"), e("refund")], mode: :in_order)

      assert [%{expected: 0, tool_call_id: "call_1"}] = details.matched

      assert [%{expected: 1, name: "lookup", count: 1}, %{expected: 2, name: "refund", count: 1}] =
               details.missing

      assert details.out_of_order == [1]
      assert reason =~ "2 expected call(s) missing"
    end

    test "f1 scoring" do
      trace = B.trajectory([{"a", %{}}, {"b", %{}}, {"x", %{}}])

      assert {:ok, %Score{value: value, passed?: false}} =
               score(trace,
                 expected: [e("a"), e("b"), e("c"), e("d")],
                 mode: :unordered,
                 score: :f1
               )

      # precision 2/3, recall 2/4
      assert_in_delta value, 2 * (2 / 3) * 0.5 / (2 / 3 + 0.5), 1.0e-9

      assert {:ok, %Score{value: 0.5}} =
               score(trace, expected: [e("a"), e("c")], mode: :superset, score: :f1)
    end
  end

  describe "arguments" do
    test "subset is recursive; exact rejects extra keys and reports paths" do
      trace =
        B.trajectory([
          {"order", %{"id" => "1", "items" => [%{"sku" => "A", "qty" => 2}], "note" => "x"}}
        ])

      assert passed?(trace, expected: [e("order", %{"items" => [%{"sku" => "A"}]})])
      refute passed?(trace, expected: [e("order", %{"items" => [%{"sku" => "B"}]})])

      assert {:ok, %Score{passed?: false, details: details}} =
               score(trace,
                 expected: [e("order", %{"id" => "1", "items" => [%{"sku" => "A", "qty" => 2}]})],
                 args: :exact
               )

      assert [%{expected: 0, tool_call_id: "call_0", paths: ["note"]}] = details.arg_mismatches
    end

    test "numbers, atoms, JSON strings, ignore_args, arg_defaults and overrides" do
      trace =
        B.trajectory([
          {"pay",
           %{"amount" => 10, "request_id" => "r-9", "next_cursor" => "c", "currency" => "eur"}},
          {"find", %{"filter" => ~s({"status":"open"}), "page" => 1}}
        ])

      assert passed?(trace, expected: [e("pay", %{amount: 10.0, currency: :eur})])
      refute passed?(trace, expected: [e("pay", %{"amount" => "10"})])

      assert passed?(trace,
               expected: [e("pay", %{"amount" => 10.001})],
               numbers: {:tolerance, abs: 0.01}
             )

      refute passed?(trace,
               expected: [e("pay", %{"amount" => 10.5})],
               numbers: {:tolerance, abs: 0.01}
             )

      assert passed?(trace, expected: [e("find", %{"filter" => %{"status" => "open"}})])

      assert passed?(trace,
               expected: [
                 e("pay", %{"amount" => 10, "currency" => "eur"}),
                 e("find", %{"filter" => %{"status" => "open"}})
               ],
               args: :exact,
               ignore_args: ["request_id", "*_cursor"],
               arg_defaults: %{"find" => %{"page" => 1}}
             )

      assert passed?(trace,
               expected: [e("pay", %{"amount" => 10, "currency" => "usd"})],
               args_overrides: %{"pay" => ["amount"]}
             )

      assert passed?(trace, expected: [e("pay", %{"amount" => 99})], args: :ignore)

      assert passed?(trace,
               expected: [e("pay", %{"amount" => 1})],
               args: fn actual, _expected -> actual["currency"] == "eur" end
             )
    end

    test "an edited call matches on the arguments it ran with" do
      trace =
        B.trajectory([
          {"pay", %{"amount" => 500}, approval: :edited, arguments: %{"amount" => 50}}
        ])

      assert passed?(trace, expected: [e("pay", %{"amount" => 50})])
      refute passed?(trace, expected: [e("pay", %{"amount" => 500})])
    end
  end

  describe "include and forbid" do
    test "failed attempts are excluded by default and counted with include" do
      trace = B.trajectory([{"search", %{}, outcome: :invalid_arguments}])

      refute passed?(trace, expected: [e("search")])
      assert passed?(trace, expected: [e("search")], include: :all)
      assert passed?(trace, expected: [e("search")], include: ["executed", "invalid_arguments"])
    end

    test "a forbidden tool fails even when a hook denied the call" do
      trace = B.trajectory([{"search", %{}}, {"delete_all", %{}, outcome: :hook_denied}])

      assert {:ok, %Score{passed?: false, value: :fail, details: details, reason: reason}} =
               score(trace, expected: [e("search")], forbid: ["delete_all"])

      assert [%{name: "delete_all", outcome: :hook_denied}] = details.forbidden
      assert reason =~ "1 forbidden call(s)"
      assert passed?(trace, expected: [e("search")], forbid: ["drop_table"])

      assert {:ok, %Score{value: +0.0}} =
               score(trace, expected: [e("search")], forbid: ["delete_all"], score: :f1)
    end
  end

  describe "scope" do
    setup do
      root = "aaaaaaaaaaaaaaaa"
      child = "bbbbbbbbbbbbbbbb"

      trace =
        B.new()
        |> B.run_start(root)
        |> B.tool_start(root, "d1", "delegate_task", %{"task" => "research"})
        |> B.run_start(child,
          parent: root,
          parent_tool_call_id: "d1",
          sub_agent_template: "researcher"
        )
        |> B.tool_call(child, "fetch", %{"url" => "u"})
        |> B.run_stop(child)
        |> B.tool_stop(root, "d1", "delegate_task")
        |> B.run_stop(root)
        |> B.build()

      %{trace: trace}
    end

    test "root scope sees the delegation, not the sub-agent's calls", %{trace: trace} do
      assert passed?(trace, expected: [e("delegate_task")], mode: :strict)
      refute passed?(trace, expected: [e("fetch")])
    end

    test "tree and sub_agent scopes see the sub-agent's calls", %{trace: trace} do
      assert passed?(trace,
               expected: [e("delegate_task"), e("fetch")],
               mode: :unordered,
               scope: :tree
             )

      assert passed?(trace,
               expected: [e("fetch")],
               mode: :strict,
               scope: {:sub_agent, "researcher"}
             )

      assert passed?(trace,
               expected: [e("fetch")],
               mode: :strict,
               scope: %{"sub_agent" => "researcher"}
             )
    end
  end

  describe "truncated traces" do
    test "presence can be proven, absence cannot" do
      trace = B.trajectory([{"search", %{}}], truncated?: true)

      assert passed?(trace, expected: [e("search")])

      for opts <- [
            [expected: [e("search"), e("refund")]],
            [expected: [e("search")], mode: :strict],
            [expected: [e("search")], mode: :subset],
            [expected: [e("search")], forbid: ["delete_all"]]
          ] do
        assert {:error, %ScorerError{kind: :missing_trace, scorer: "trajectory"}} =
                 score(trace, opts)
      end
    end
  end

  describe "init/1" do
    test "accepts string enums from dataset files" do
      assert {:ok,
              %{
                mode: :in_order,
                parallel: :as_emitted,
                score: :f1,
                include: [:executed, :hook_denied],
                args: :exact
              }} =
               Trajectory.init(
                 expected: [%{"name" => "a", "args" => %{"x" => 1}}],
                 mode: "in_order",
                 parallel: "as_emitted",
                 score: "f1",
                 include: ["executed", "hook_denied"],
                 args: "exact"
               )
    end

    test "rejects bad configuration" do
      for opts <- [
            [expected: []],
            [expected: [%{name: "a"}], mode: "sideways"],
            [expected: [%{name: "a", argz: %{}}]],
            [expected: [%{name: "a", count: 0}]],
            [expected: [%{name: "a", count: {3, 1}}]],
            [expected: [%{name: ""}]],
            [expected: [%{name: "a"}], include: ["exploded"]],
            [expected: [%{name: "a"}], numbers: {:tolerance, abs: -1}],
            [expected: [%{name: "a"}], unknown: true],
            [expected: "a"]
          ] do
        assert {:error, message} = Trajectory.init(opts), "#{inspect(opts)} should be rejected"
        assert message =~ "trajectory:"
      end

      assert {:ok, _} = Trajectory.init(expected: [], mode: :strict)
      assert {:ok, _} = Trajectory.init(expected: [], forbid: ["x"])
    end
  end
end

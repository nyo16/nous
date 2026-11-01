defmodule Nous.Eval.CompareTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{Case, CanonicalJSON, Compare, Score}
  alias Nous.Eval.Compare.Metric
  alias Nous.Eval.RunBuilder, as: B
  alias Nous.Eval.Stats.Hypothesis

  doctest Nous.Eval.Compare.Metric

  @fast [resamples: 2_000]

  defp compare!(base, cand, opts \\ []) do
    {:ok, c} = Compare.compare(base, cand, Keyword.merge(@fast, opts))
    c
  end

  defp row(c, id), do: Enum.find(c.cases, &(&1.id == id))

  defp all(n, verdict), do: B.uniform(n, fn _ -> [verdict] end)

  describe "per-case labels" do
    setup do
      base =
        B.run(
          [
            {"fixed", [:fail, :fail, :fail]},
            {"broken", [:pass, :pass, :pass]},
            {"flaky", [:pass, :fail, :fail]},
            {"flaky_up", [:pass, :pass, :pass]},
            {"same_pass", [:pass, :pass, :pass]},
            {"same_fail", [:fail, :fail, :fail]},
            {"new_error", [:pass, :pass, :pass]},
            {"dead", [:pass, :pass, :pass]}
          ],
          id: "base"
        )

      cand =
        B.run(
          [
            {"fixed", [:pass, :pass, :fail]},
            {"broken", [:fail, :pass, :fail]},
            {"flaky", [:fail, :fail, :pass]},
            {"flaky_up", [:pass, :fail, :pass]},
            {"same_pass", [:pass, :pass, :pass]},
            {"same_fail", [:fail, :fail, :fail]},
            {"new_error", [:pass, :error, :pass]},
            {"dead", [:error, :error, :error]}
          ],
          id: "cand"
        )

      %{c: compare!(base, cand, gate: [max_error_rate: 1.0])}
    end

    test "labels by majority pass and sample agreement", %{c: c} do
      assert row(c, "fixed").label == :fixed
      assert row(c, "broken").label == :broken
      assert row(c, "flaky").label == :flaky
      # 3/3 -> 2/3 stays a majority pass but is no longer unanimous
      assert row(c, "flaky_up").label == :flaky
      assert row(c, "same_pass").label == :unchanged
      assert row(c, "same_fail").label == :unchanged
    end

    test "error status is flagged apart from the label", %{c: c} do
      assert %{label: :unchanged, error_changed: true} = row(c, "new_error")
      assert %{label: nil, error_changed: true} = row(c, "dead")
      refute row(c, "fixed").error_changed

      assert c.counts == %{
               fixed: 1,
               broken: 1,
               flaky: 2,
               unchanged: 3,
               not_comparable: 1,
               error_changed: 2
             }

      assert c.comparable_cases == 7
    end

    test "McNemar runs on the fixed/broken discordant pairs", %{c: c} do
      {:ok, expected} = Hypothesis.mcnemar(1, 1)
      assert Map.delete(c.mcnemar, :n) == expected
      assert c.mcnemar.n == 7
    end
  end

  test "with k = 1 no case is flaky" do
    base = B.run([{"a", [:pass]}, {"b", [:fail]}, {"c", [:pass]}])
    cand = B.run([{"a", [:fail]}, {"b", [:pass]}, {"c", [:pass]}])
    c = compare!(base, cand)

    assert Enum.map(c.cases, & &1.label) == [:broken, :fixed, :unchanged]
  end

  describe "dataset hash" do
    setup do
      base = B.run([{"a", [:pass]}, {"b", [:pass]}, {"c", [:fail]}], dataset_hash: "sha256:old")
      cand = B.run([{"b", [:pass]}, {"c", [:pass]}, {"d", [:pass]}], dataset_hash: "sha256:new")
      %{base: base, cand: cand}
    end

    test "different datasets are refused", %{base: base, cand: cand} do
      assert Compare.compare(base, cand) ==
               {:error, {:dataset_changed, %{baseline: "sha256:old", candidate: "sha256:new"}}}
    end

    test "allow_dataset_change compares the common ids and lists the rest", %{
      base: base,
      cand: cand
    } do
      c = compare!(base, cand, allow_dataset_change: true)

      assert Enum.map(c.cases, & &1.id) == ["b", "c"]
      assert c.dataset.changed?
      assert c.dataset.added == ["d"]
      assert c.dataset.removed == ["a"]
      assert c.comparable_cases == 2
      assert [%{metric: :pass_rate, n: 2, baseline: 0.5, candidate: 1.0}] = c.metrics
    end
  end

  describe "bootstrap reproducibility" do
    setup do
      base = B.run(B.uniform(15, fn i -> [if(rem(i, 4) == 0, do: :fail, else: :pass), :pass] end))
      cand = B.run(B.uniform(15, fn i -> [if(rem(i, 3) == 0, do: :fail, else: :pass), :pass] end))
      %{base: base, cand: cand}
    end

    test "the same seed gives an identical comparison", %{base: base, cand: cand} do
      assert compare!(base, cand, seed: 5) == compare!(base, cand, seed: 5)

      [m1] = compare!(base, cand, seed: 5).metrics
      [m2] = compare!(base, cand, seed: 6).metrics
      assert m1.ci != m2.ci
    end

    test "concurrency does not change the result", %{base: base, cand: cand} do
      assert compare!(base, cand, seed: 5, max_concurrency: 4).metrics ==
               compare!(base, cand, seed: 5).metrics
    end

    test "seed, resamples and streams are recorded; the seed defaults to the candidate's", %{
      base: base,
      cand: cand
    } do
      c = compare!(base, %{cand | seed: 1234})

      assert c.bootstrap == %{
               seed: 1234,
               algorithm: :exsss,
               resamples: 2_000,
               streams: 8,
               confidence: 0.95
             }
    end
  end

  describe "gate" do
    test "a clear drop is a regression" do
      base = B.run(all(30, :pass))
      cand = B.run(B.uniform(30, fn i -> [if(i <= 12, do: :fail, else: :pass)] end))
      c = compare!(base, cand)

      assert c.verdict == :regression
      assert [%{metric: :pass_rate, regression?: true, delta: delta} = m] = c.metrics
      assert_in_delta delta, -0.4, 1.0e-12
      assert m.adjusted_p_value <= 0.05
      assert m.upper_bound < 0
      assert [%{reason: :regression, metric: :pass_rate}] = c.reasons
    end

    test "noise at small n is not a regression" do
      # 10 cases, one broken: the drop is within what 10 cases can show by chance
      base = B.run(all(10, :pass))
      cand = B.run(B.uniform(10, fn i -> [if(i == 1, do: :fail, else: :pass)] end))
      c = compare!(base, cand)

      assert c.verdict == :pass
      assert [%{regression?: false, p_value: p, small_n?: true, mde: mde}] = c.metrics
      assert p > 0.05
      assert mde > 0.1
      assert c.reasons == []
    end

    test "identical runs pass with p = 1" do
      run = B.run(B.uniform(8, fn i -> [if(rem(i, 2) == 0, do: :pass, else: :fail)] end))
      c = compare!(run, run)

      assert c.verdict == :pass
      assert [%{p_value: 1.0, delta: +0.0, mde: mde}] = c.metrics
      assert mde > 0.0
    end

    test "the margin tolerates drops up to its size" do
      base = B.run(all(40, :pass))
      cand = B.run(B.uniform(40, fn i -> [if(i <= 6, do: :fail, else: :pass)] end))

      assert compare!(base, cand).verdict == :regression
      assert compare!(base, cand, gate: [margin: 0.3]).verdict == :pass
    end

    test "the candidate's error rate above max_error_rate is an error" do
      base = B.run(all(10, :pass))
      cand = B.run(B.uniform(10, fn i -> [if(i == 1, do: :error, else: :pass)] end))

      c = compare!(base, cand)
      assert c.verdict == :error
      assert [%{reason: :error_rate, error_rate: 0.1, max_error_rate: +0.0}] = c.reasons

      assert compare!(base, cand, gate: %{max_error_rate: 0.1}).verdict == :pass
    end

    test "errors take precedence over a regression" do
      base = B.run(all(30, :pass))

      cand =
        B.run(
          B.uniform(30, fn i -> [if(i <= 15, do: :fail, else: :pass)] end) ++ [{"x", [:error]}]
        )

      c = compare!(base, cand)

      assert c.verdict == :error
      assert [%{regression?: true}] = c.metrics
    end

    test "no comparable case is an error" do
      base = B.run([{"a", [:pass]}, {"b", [:pass]}])
      cand = B.run([{"a", [:error]}, {"b", [:error]}])
      c = compare!(base, cand, gate: [max_error_rate: 1.0])

      assert c.verdict == :error
      assert %{reason: :no_comparable_cases} in c.reasons
    end

    test "an aborted run is an error" do
      run = B.run(all(5, :pass))
      c = compare!(run, %{run | status: :aborted})

      assert c.verdict == :error
      assert c.reasons == [%{reason: :run_aborted, run: :candidate}]
    end

    test "a gate metric without data fails closed" do
      run = B.run(all(5, :pass))
      c = compare!(run, run, gate: [metrics: [:pass_rate, "scorer:missing"]])

      assert c.verdict == :error

      assert [
               %{
                 reason: :metric_untestable,
                 metric: {:scorer, "missing"},
                 detail: :insufficient_cases
               }
             ] =
               c.reasons
    end

    test "Holm adjusts across the declared gate metrics" do
      style = fn passed? ->
        [%Score{name: "style", value: if(passed?, do: :pass, else: :fail), passed?: passed?}]
      end

      base = B.run(B.uniform(30, fn _ -> [{:pass, extra_scores: style.(true)}] end))

      cand =
        B.run(
          B.uniform(30, fn i ->
            [{if(i <= 4, do: :fail, else: :pass), extra_scores: style.(i > 9)}]
          end)
        )

      c = compare!(base, cand, gate: [metrics: [:pass_rate, {:scorer, "style"}, :case_score]])
      raw = Enum.map(c.metrics, & &1.p_value)
      {:ok, holm} = Hypothesis.holm(raw, alpha: 0.05)

      assert Enum.map(c.metrics, & &1.adjusted_p_value) == holm.adjusted
      assert Enum.map(c.metrics, & &1.regression?) == holm.rejected
      assert Enum.map(c.metrics, & &1.metric) == [:pass_rate, {:scorer, "style"}, :case_score]
      assert c.verdict == :regression
    end

    test "the p-value is the bootstrap share of replicates no worse than -margin" do
      base = B.run(all(6, :pass))
      cand = B.run(B.uniform(6, fn i -> [if(i <= 3, do: :fail, else: :pass)] end))
      c = compare!(base, cand, resamples: 999)
      [m] = c.metrics

      # Δ* >= 0 only when a draw holds no broken case: (1/2)^6 of draws
      assert_in_delta m.p_value, (1 + 999 * 0.5 ** 6) / 1000, 0.01
    end
  end

  test "breakdowns are Benjamini-Hochberg adjusted as one family" do
    tags = fn i -> if(i <= 10, do: ["billing"], else: ["search"]) end
    cases = for i <- 1..20, do: %Case{id: id(i), input: "q", tags: tags.(i) ++ ["all"]}
    base = B.run(all(20, :pass))
    cand = B.run(B.uniform(20, fn i -> [if(i <= 6, do: :fail, else: :pass)] end))

    c = compare!(base, cand, cases: cases)
    names = Enum.map(c.breakdowns, &{&1.kind, &1.name})
    assert names == [{:tag, "all"}, {:tag, "billing"}, {:tag, "search"}, {:scorer, "check"}]

    raw = Enum.map(c.breakdowns, & &1.p_value)
    {:ok, bh} = Hypothesis.benjamini_hochberg(raw, alpha: 0.05)
    assert Enum.map(c.breakdowns, & &1.adjusted_p_value) == bh.adjusted
    assert Enum.map(c.breakdowns, & &1.significant?) == bh.rejected

    billing = Enum.find(c.breakdowns, &(&1.name == "billing"))
    assert %{n: 10, baseline: 1.0, candidate: 0.4} = billing
    search = Enum.find(c.breakdowns, &(&1.name == "search"))
    assert search.p_value == 1.0
  end

  test "cost, latency and token deltas" do
    base = B.run(B.uniform(4, fn _ -> [{:pass, cost: 0.002, duration_ms: 1_000}] end))
    cand = B.run(B.uniform(4, fn _ -> [{:pass, cost: 0.003, duration_ms: 500}] end))
    c = compare!(base, cand)

    assert_in_delta c.resources.cost_mean.baseline, 0.002, 1.0e-12
    assert_in_delta c.resources.cost_mean.candidate, 0.003, 1.0e-12
    assert_in_delta c.resources.cost_mean.relative, 0.5, 1.0e-9
    assert c.resources.duration_ms_mean.delta == -500.0
    assert c.resources.duration_ms_mean.relative == -0.5
    assert c.resources.tokens_mean.delta == 0.0
  end

  test "fingerprint changes list the differing keys except the id" do
    base =
      B.run(all(3, :pass),
        fingerprint: %{"id" => "a", "model" => "m1", "tools" => %{"hash" => "t"}, "k" => 1}
      )

    cand =
      B.run(all(3, :pass),
        fingerprint: %{"id" => "b", "model" => "m2", "tools" => %{"hash" => "t"}, "k" => 3}
      )

    assert compare!(base, cand).fingerprint_changes == [
             %{key: "k", baseline: 1, candidate: 3},
             %{key: "model", baseline: "m1", candidate: "m2"}
           ]
  end

  test "options are validated" do
    run = B.run(all(3, :pass))

    assert Compare.compare(run, run, gaet: []) == {:error, {:unknown_option, :gaet}}

    assert Compare.compare(run, run, gate: [metrics: ["accuracy"]]) ==
             {:error, {:invalid_metric, "accuracy"}}

    assert Compare.compare(run, run, gate: [metrics: []]) == {:error, {:invalid_option, :metrics}}
    assert Compare.compare(run, run, gate: [alpha: 0.5]) == {:error, {:invalid_option, :alpha}}
    assert Compare.compare(run, run, gate: [margin: -0.1]) == {:error, {:invalid_option, :margin}}

    assert Compare.compare(run, run, gate: [tolerance: 1]) ==
             {:error, {:unknown_option, {:gate, :tolerance}}}

    assert Compare.compare(run, run, seed: "x") == {:error, {:invalid_option, :seed}}
    assert Compare.compare(run, run, cases: [:a]) == {:error, {:invalid_option, :cases}}

    assert {:ok, %Compare{gate: %{metrics: [:pass_rate, {:scorer, "check"}]}}} =
             Compare.compare(
               run,
               run,
               Keyword.put(@fast, :gate, metrics: ["pass_rate", "scorer:check"])
             )
  end

  test "to_map is JSON-native with string metric names" do
    base = B.run(all(4, :pass))
    cand = B.run(B.uniform(4, fn i -> [if(i == 1, do: :error, else: :pass)] end))
    map = Compare.to_map(compare!(base, cand))

    assert map["schema"] == "nous.eval.comparison/1"
    assert map["verdict"] == "error"
    assert map["gate"]["metrics"] == ["pass_rate"]
    assert [%{"metric" => "pass_rate", "ci" => [_, _]}] = map["metrics"]
    assert [%{"reason" => "error_rate"}] = map["reasons"]
    assert JSON.decode!(CanonicalJSON.encode(map))["verdict"] == "error"
  end

  test "Metric names round-trip through parse" do
    for m <- [:pass_rate, :case_score, {:scorer, "judge.relevance"}] do
      assert Metric.parse(Metric.name(m)) == {:ok, m}
    end
  end

  defp id(i), do: "c" <> String.pad_leading(Integer.to_string(i), 2, "0")
end

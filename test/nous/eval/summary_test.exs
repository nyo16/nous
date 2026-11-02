defmodule Nous.Eval.SummaryTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.{CanonicalJSON, Score, ScorerError, Stats, Summary}
  alias Nous.Eval.RunBuilder, as: B
  alias Nous.Eval.Stats.Power

  defp case_entry(summary, id), do: Enum.find(summary["cases"], &(&1["id"] == id))

  describe "per-case aggregation over k" do
    setup do
      run =
        B.run(
          [
            {"all_pass", [:pass, :pass, :pass]},
            {"two_of_three", [:pass, :fail, :pass]},
            {"with_error", [:pass, :error, :fail]},
            {"all_error", [:error, :error, :error]}
          ],
          k: 3
        )

      %{summary: Summary.build(run)}
    end

    test "pass rates use only :pass/:fail samples", %{summary: s} do
      assert case_entry(s, "two_of_three")["pass_rate"] == 2 / 3
      # 1 pass, 1 fail, 1 error: the error is out of numerator and denominator
      assert %{"pass_rate" => 0.5, "scored" => 2, "errors" => 1, "status" => "mixed"} =
               case_entry(s, "with_error")

      # pooled: 3 + 2 + 1 passes over 3 + 3 + 2 scored samples
      assert s["pass_rate"]["estimate"] == 6 / 8
      assert s["pass_rate"]["samples"] == 8
      assert s["pass_rate"]["cases"] == 3
    end

    test "a case whose samples all errored is :error, not :fail", %{summary: s} do
      assert %{"status" => "error", "pass_rate" => nil, "scored" => 0} =
               case_entry(s, "all_error")

      assert case_entry(s, "all_pass")["status"] == "pass"
    end

    test "pass@k and pass^k are the unbiased estimators at the run's k", %{summary: s} do
      {:ok, at} = Stats.pass_at_k(3, 2, 3)
      {:ok, hat} = Stats.pass_hat_k(3, 2, 3)
      assert case_entry(s, "two_of_three")["pass_at_k"] == at
      assert case_entry(s, "two_of_three")["pass_hat_k"] == hat

      # only 2 scored samples < k = 3: undefined, and left out of the mean
      assert case_entry(s, "with_error")["pass_at_k"] == nil

      assert s["pass_hat_k"] == %{
               "k" => 3,
               "cases" => 2,
               "estimate" => (1.0 + 0.0) / 2,
               "ci" => [0.0, 1.0]
             }
    end

    test "error rate and error counts", %{summary: s} do
      totals = s["totals"]
      assert totals["error_rate"] == 4 / 12
      assert totals["verdicts"] == %{"pass" => 6, "fail" => 2, "error" => 4, "none" => 0}
      assert totals["errors_by_kind"] == %{"judge_unparseable" => 4}
      assert totals["outcomes"]["ok"] == 12
      assert length(s["error_examples"]) == 4
      assert hd(s["error_examples"])["kind"] == "judge_unparseable"
    end

    test "the clustered interval treats each case as one cluster", %{summary: s} do
      {:ok, cl} = Stats.clustered_se([[1, 1, 1], [1, 0, 1], [1, 0]])
      assert s["pass_rate"]["clustered"]["se"] == cl.se
      assert s["pass_rate"]["clustered"]["clusters"] == 3
      [lo, hi] = s["pass_rate"]["clustered"]["ci"]
      assert lo < cl.mean and hi <= 1.0
    end
  end

  test "k = 1: Wilson on the samples, clustered SE equals the plain SE" do
    run = B.run(B.uniform(10, fn i -> [if(i <= 7, do: :pass, else: :fail)] end), k: 1)
    s = Summary.build(run)

    {:ok, wilson} = Stats.wilson(7, 10)
    assert s["pass_rate"]["wilson"] == Tuple.to_list(wilson.ci)
    {:ok, plain} = Stats.describe(List.duplicate(1, 7) ++ List.duplicate(0, 3))
    assert_in_delta s["pass_rate"]["clustered"]["se"], plain.se, 1.0e-12
    assert s["pass_at_k"]["estimate"] == 0.7
    assert s["pass_hat_k"]["estimate"] == 0.7
  end

  test "MDE follows Miller eq. 10 with the unpaired variance at one-sided alpha" do
    # per-case rates 1.0 / 0.0: variance 0.263 is above the floor 0.5 * 0.5 / 2
    run =
      B.run(
        B.uniform(20, fn i -> if(rem(i, 2) == 0, do: [:pass, :pass], else: [:fail, :fail]) end)
      )

    s = Summary.build(run)

    rates = Enum.map(1..20, fn i -> if(rem(i, 2) == 0, do: 1.0, else: 0.0) end)
    {:ok, %{variance: v}} = Stats.describe(rates)
    {:ok, expected} = Power.mde(20, 2 * v, alpha: 0.1, power: 0.8)
    assert_in_delta s["mde"]["pass_rate"], expected, 1.0e-12

    # all-pass run: variance 0, the binomial floor keeps the MDE finite
    all_pass = Summary.build(B.run(B.uniform(20, fn _ -> [:pass] end)))
    assert all_pass["mde"]["pass_rate"] > 0.0
    # more cases detect smaller effects
    bigger = Summary.build(B.run(B.uniform(80, fn _ -> [:pass] end)))
    assert bigger["mde"]["pass_rate"] < all_pass["mde"]["pass_rate"]
  end

  test "an empty run has nil estimates and does not raise" do
    s = Summary.build(B.run([]))

    assert s["totals"]["cases"] == 0
    assert s["totals"]["samples"] == 0
    assert s["totals"]["error_rate"] == nil

    assert s["pass_rate"] == %{
             "estimate" => nil,
             "cases" => 0,
             "samples" => 0,
             "wilson" => nil,
             "clustered" => nil
           }

    assert s["mde"]["pass_rate"] == nil
    assert s["scorers"] == %{}
    assert s["resources"]["cost"]["total"] == nil
    assert s["resources"]["duration_ms"]["p95"] == nil
  end

  test "an all-error run" do
    s = Summary.build(B.run([{"a", [:error, :error]}, {"b", [:error]}]))

    assert s["totals"]["error_rate"] == 1.0
    assert s["pass_rate"]["estimate"] == nil
    assert Enum.all?(s["cases"], &(&1["status"] == "error"))
    assert s["mde"]["pass_rate"] == nil
    assert s["scorers"]["judge"]["errors"] == %{"judge_unparseable" => 3}
    # the error samples' other scores are still counted per scorer
    assert s["scorers"]["check"]["samples"] == 3
  end

  test "a budget-exhausted run counts unrun samples apart and excludes them from means" do
    run =
      B.run([{"a", [:pass, nil]}, {"b", [nil, nil]}],
        status: :budget_exhausted,
        budget: %{max_cost: 0.5, spent: %{cost: 0.5}, limit: {:max_cost, 0.5}}
      )

    s = Summary.build(run)
    assert s["budget"]["exhausted"]
    assert s["budget"]["unrun_samples"] == 3

    assert s["budget"]["config"] == %{
             "max_cost" => 0.5,
             "spent" => %{"cost" => 0.5},
             "limit" => ["max_cost", 0.5]
           }

    assert s["totals"]["verdicts"]["none"] == 3
    assert s["totals"]["outcomes"]["budget_exhausted"] == 3
    assert s["totals"]["error_rate"] == 0.0
    assert %{"status" => "not_run"} = case_entry(s, "b")
    assert s["resources"]["duration_ms"]["mean"] == 1000.0
    assert s["resources"]["duration_ms"]["total"] == 1000
  end

  test "per-scorer metrics are independent of verdict composition" do
    style = fn value, passed? -> %Score{name: "style", value: value, passed?: passed?} end
    label = fn l -> %Score{name: "tone", value: {:label, l}, passed?: true} end

    run =
      B.run([
        {"a", [{:pass, extra_scores: [style.(0.2, false), label.("polite")]}]},
        {"b", [{:pass, extra_scores: [style.(0.9, true), label.("polite")]}]},
        {"c",
         [
           {:fail,
            extra_scores: [label.("rude")],
            skipped: [{"style", "no output"}],
            scorer_errors: [%ScorerError{scorer: "judge", kind: :timeout}]}
         ]}
      ])

    s = Summary.build(run)

    # "style" failed on a passing sample: still a failure in its own metric
    assert %{"samples" => 2, "passed" => 1, "skipped" => 1} = s["scorers"]["style"]
    assert_in_delta s["scorers"]["style"]["mean"]["estimate"], 0.55, 1.0e-12
    assert s["scorers"]["style"]["pass_rate"]["estimate"] == 0.5
    assert s["scorers"]["tone"]["labels"] == %{"polite" => 2, "rude" => 1}
    assert s["scorers"]["tone"]["mean"] == nil
    assert s["scorers"]["judge"]["errors"] == %{"timeout" => 1}
  end

  test "is JSON-native and deterministic for a seed" do
    run = B.run(B.uniform(12, fn i -> [if(rem(i, 3) == 0, do: :fail, else: :pass), :pass] end))
    s = Summary.build(run, seed: 11, resamples: 300)

    assert JSON.decode!(JSON.encode!(s)) == s
    assert is_binary(CanonicalJSON.encode(s))
    assert s == Summary.build(run, seed: 11, resamples: 300)

    assert s["bootstrap"] == %{
             "seed" => 11,
             "resamples" => 300,
             "streams" => 8,
             "algorithm" => "exsss"
           }

    assert [lo, hi] = s["scorers"]["check"]["mean"]["ci"]
    assert lo <= s["scorers"]["check"]["mean"]["estimate"] and hi <= 1.0
  end

  test "the bootstrap seed defaults to the run seed" do
    run = B.run(B.uniform(5, fn _ -> [:pass, :fail] end), seed: 99)
    assert Summary.build(run)["bootstrap"]["seed"] == 99
    assert Summary.build(%{run | seed: nil})["bootstrap"]["seed"] == 0
  end

  test "rejects invalid options" do
    assert_raise ArgumentError, fn -> Summary.build(B.run([]), alpha: 0.7) end
    assert_raise ArgumentError, fn -> Summary.build(B.run([]), resamples: 0) end
  end
end

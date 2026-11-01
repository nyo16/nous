defmodule Nous.Eval.Stats.ClassifierTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats.Classifier

  doctest Classifier

  # Golden values: scikit-learn / SciPy (see test/fixtures/stats/generate.py).
  @fixture_path Path.expand("../../../fixtures/stats/classifier.json", __DIR__)
  @external_resource @fixture_path
  @golden @fixture_path |> File.read!() |> JSON.decode!()

  defp assert_close(actual, expected, rtol, atol) do
    assert is_float(actual), "expected a float, got #{inspect(actual)}"
    diff = abs(actual - expected)

    assert diff <= atol + rtol * abs(expected),
           "expected #{expected}, got #{actual} (diff #{diff})"
  end

  defp scored(%{"scores" => scores, "labels" => labels}), do: Enum.zip(scores, labels)

  describe "threshold-free metrics" do
    test "ROC-AUC (rank form, ties as ½) matches sklearn and Mann–Whitney U" do
      for set <- @golden["sets"] do
        assert {:ok, auc} = Classifier.roc_auc(scored(set))
        assert_close(auc, set["roc_auc"], 1.0e-12, 0.0)
        assert_close(auc, set["mann_whitney_auc"], 1.0e-12, 0.0)
      end
    end

    test "average precision matches sklearn" do
      for set <- @golden["sets"] do
        assert {:ok, ap} = Classifier.average_precision(scored(set))
        assert_close(ap, set["average_precision"], 1.0e-12, 0.0)
      end
    end

    test "ROC curve matches sklearn roc_curve(drop_intermediate: false)" do
      for set <- @golden["sets"] do
        assert {:ok, points} = Classifier.roc_curve(scored(set))
        assert length(points) == length(set["roc_curve"])

        for {p, e} <- Enum.zip(points, set["roc_curve"]) do
          assert p.threshold == e["threshold"]
          assert_close(p.tpr, e["tpr"], 1.0e-14, 0.0)
          assert_close(p.fpr, e["fpr"], 1.0e-14, 0.0)
        end
      end
    end

    test "PR curve recall/precision come from the same cumulative counts" do
      [set | _] = @golden["sets"]
      {:ok, pr} = Classifier.pr_curve(scored(set))

      for {p, row} <- Enum.zip(pr, set["threshold_sweep"]) do
        assert p.threshold == row["threshold"]
        assert p.precision == row["tp"] / (row["tp"] + row["fp"])
        assert p.recall == row["tp"] / (row["tp"] + row["fn"])
      end
    end
  end

  describe "operating points" do
    test "recall@FPR matches the best admissible sklearn ROC point" do
      for set <- @golden["sets"], row <- set["recall_at_fpr"] do
        assert {:ok, r} = Classifier.recall_at_fpr(scored(set), row["max_fpr"])
        assert r.threshold == row["threshold"]
        assert_close(r.recall, row["recall"], 1.0e-14, 0.0)
        assert_close(r.fpr, row["fpr"], 1.0e-14, 0.0)
      end
    end

    test "threshold sweep matches sklearn confusion_matrix and fbeta_score" do
      for set <- @golden["sets"] do
        assert {:ok, rows} = Classifier.threshold_sweep(scored(set), beta: 2.0)
        assert length(rows) == length(set["threshold_sweep"])

        for {r, e} <- Enum.zip(rows, set["threshold_sweep"]) do
          assert {r.threshold, r.tp, r.fp, r.tn, r.fn} ==
                   {e["threshold"], e["tp"], e["fp"], e["tn"], e["fn"]}

          assert_close(r.f_beta, e["f2"], 1.0e-12, 0.0)
        end
      end
    end

    test "cost-weighted threshold matches a brute-force minimum" do
      for set <- @golden["sets"], row <- set["cost_weighted"] do
        opts =
          [cost_fp: row["cost_fp"], cost_fn: row["cost_fn"]] ++
            if(row["prevalence"], do: [prevalence: row["prevalence"]], else: [])

        assert {:ok, r} = Classifier.cost_weighted_threshold(scored(set), opts)
        assert r.threshold == row["threshold"]
        assert_close(r.expected_cost, row["expected_cost"], 1.0e-12, 1.0e-15)
      end
    end

    test "with too few negatives only the flag-nothing point fits a 1% FPR" do
      # 2 negatives: FPR moves in steps of 0.5, and the top score is a negative.
      scored = [{0.9, false}, {0.8, true}, {0.7, true}, {0.1, false}]

      assert {:ok, %{threshold: nil, recall: +0.0, fpr: +0.0}} =
               Classifier.recall_at_fpr(scored, 0.01)
    end
  end

  describe "metrics/2" do
    test "matches sklearn precision/recall/F1/F0.5/accuracy" do
      for %{"tp" => tp, "fp" => fp, "tn" => tn, "fn" => fneg} = row <- @golden["metrics"] do
        counts = %{tp: tp, fp: fp, tn: tn, fn: fneg}
        assert {:ok, m1} = Classifier.metrics(counts)
        assert {:ok, m05} = Classifier.metrics(counts, beta: 0.5)

        assert_close(m1.precision, row["precision"], 1.0e-14, 0.0)
        assert_close(m1.recall, row["recall"], 1.0e-14, 0.0)
        assert_close(m1.f_beta, row["f1"], 1.0e-14, 0.0)
        assert_close(m05.f_beta, row["f05"], 1.0e-14, 0.0)
        assert_close(m1.accuracy, row["accuracy"], 1.0e-14, 0.0)
      end
    end

    test "zero denominators give nil, never NaN" do
      assert {:ok, m} = Classifier.metrics(%{tp: 0, fp: 0, tn: 5, fn: 0})
      assert %{precision: nil, recall: nil, fnr: nil, f_beta: nil, fpr: +0.0} = m

      assert {:ok, %{accuracy: nil, prevalence: nil}} =
               Classifier.metrics(%{tp: 0, fp: 0, tn: 0, fn: 0})

      assert {:ok, %{f_beta: +0.0}} = Classifier.metrics(%{tp: 0, fp: 3, tn: 1, fn: 2})

      assert Classifier.metrics(%{tp: 1, fp: 0, tn: 0, fn: 0}, beta: 0) ==
               {:error, {:invalid_option, :beta}}

      assert Classifier.metrics(%{tp: -1, fp: 0, tn: 0, fn: 0}) == {:error, :invalid_counts}
    end

    test "confusion_at/2 predicts positive at score >= threshold" do
      scored = [{0.5, true}, {0.4, false}, {0.5, false}, {0.1, true}]
      assert Classifier.confusion_at(scored, 0.5) == {:ok, %{tp: 1, fp: 1, tn: 1, fn: 1}}
    end
  end

  describe "prevalence_adjusted/3" do
    test "matches the closed-form PPV/NPV" do
      for %{"tpr" => tpr, "fpr" => fpr, "prevalence" => prev} = row <-
            @golden["prevalence_adjusted"] do
        assert {:ok, r} = Classifier.prevalence_adjusted(tpr, fpr, prev)
        assert_close(r.ppv, row["ppv"], 1.0e-14, 0.0)
        assert_close(r.npv, row["npv"], 1.0e-14, 0.0)
      end
    end

    test "undefined values are nil" do
      assert Classifier.prevalence_adjusted(0.0, 0.0, 0.5) == {:ok, %{ppv: nil, npv: 0.5}}
      assert {:ok, %{npv: nil}} = Classifier.prevalence_adjusted(1.0, 1.0, 0.3)

      assert Classifier.prevalence_adjusted(0.5, 0.1, 1.5) ==
               {:error, {:invalid_option, :prevalence}}
    end
  end

  describe "edge cases" do
    test "single-class data" do
      only_neg = [{0.2, false}, {0.4, false}]
      assert Classifier.roc_auc(only_neg) == {:error, :single_class}
      assert Classifier.roc_curve(only_neg) == {:error, :single_class}
      assert Classifier.average_precision(only_neg) == {:error, :no_positives}
      assert Classifier.recall_at_fpr(only_neg, 0.1) == {:error, :single_class}
      assert Classifier.cost_weighted_threshold(only_neg) == {:error, :single_class}

      assert {:ok, [%{threshold: 0.4, recall: nil, fpr: 0.5}, %{threshold: 0.2, fpr: 1.0}]} =
               Classifier.threshold_sweep(only_neg)
    end

    test "all scores tied give AUC 0.5 and a single threshold" do
      tied = [{1, true}, {1.0, false}, {1, false}, {1.0, true}]
      assert Classifier.roc_auc(tied) == {:ok, 0.5}
      assert {:ok, [_]} = Classifier.pr_curve(tied)
    end

    test "invalid inputs" do
      assert Classifier.roc_auc([{0.3, 1}]) == {:error, :invalid_values}
      assert Classifier.confusion([{true, nil}]) == {:error, :invalid_values}
      assert Classifier.threshold_sweep([]) == {:error, :empty}

      assert Classifier.recall_at_fpr([{0.3, true}, {0.1, false}], 2) ==
               {:error, {:invalid_option, :max_fpr}}
    end
  end
end

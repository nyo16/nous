defmodule Nous.Eval.Stats.HypothesisTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats.Hypothesis
  alias Nous.Eval.Stats.Power

  doctest Hypothesis

  # Golden values: statsmodels/SciPy, and an independent mpmath reference for
  # Tango (see test/fixtures/stats/generate.py).
  @fixture_path Path.expand("../../../fixtures/stats/hypothesis.json", __DIR__)
  @external_resource @fixture_path
  @golden @fixture_path |> File.read!() |> JSON.decode!()

  defp assert_close(actual, expected, rtol, atol) do
    assert is_float(actual), "expected a float, got #{inspect(actual)}"
    diff = abs(actual - expected)

    assert diff <= atol + rtol * abs(expected),
           "expected #{expected}, got #{actual} (diff #{diff})"
  end

  describe "mcnemar/2" do
    test "exact and mid-P p-values match statsmodels / scipy.stats.binom" do
      for %{"b" => b, "c" => c} = row <- @golden["mcnemar"] do
        assert {:ok, r} = Hypothesis.mcnemar(b, c)
        assert_close(r.p_value, row["p_value"], 1.0e-11, 1.0e-300)
        assert_close(r.mid_p_value, row["mid_p_value"], 1.0e-11, 1.0e-300)
        assert r.statistic == min(b, c)
      end
    end

    test "no discordant pairs gives p = 1, and b = c gives mid-P = 1" do
      assert {:ok, %{p_value: 1.0, mid_p_value: 1.0}} = Hypothesis.mcnemar(0, 0)
      assert {:ok, %{mid_p_value: 1.0}} = Hypothesis.mcnemar(4, 4)
    end

    test "fewer than 6 discordant pairs can never reach p < 0.05" do
      for b <- 0..5, c <- 0..(5 - b) do
        {:ok, %{p_value: p}} = Hypothesis.mcnemar(b, c)
        assert p > 0.05
      end
    end

    test "rejects negative or non-integer counts" do
      assert Hypothesis.mcnemar(-1, 2) == {:error, :invalid_counts}
      assert Hypothesis.mcnemar(1.0, 2) == {:error, :invalid_counts}
    end
  end

  describe "fisher_exact/4" do
    test "two-sided p-value and odds ratio match scipy.stats.fisher_exact" do
      for %{"table" => [[a, b], [c, d]], "p_value" => p, "odds_ratio" => odds} <-
            @golden["fisher_exact"] do
        assert {:ok, r} = Hypothesis.fisher_exact(a, b, c, d)
        assert_close(r.p_value, p, 1.0e-10, 1.0e-300)

        case odds do
          "infinity" -> assert r.odds_ratio == :infinity
          "undefined" -> assert r.odds_ratio == :undefined
          value -> assert_close(r.odds_ratio, value, 1.0e-14, 0.0)
        end
      end
    end

    test "a single case with 3-of-3 vs 0-of-3 is only p = 0.1 two-sided" do
      assert {:ok, %{p_value: p}} = Hypothesis.fisher_exact(3, 0, 0, 3)
      assert_close(p, 0.1, 1.0e-12, 0.0)
    end
  end

  describe "tango_test/4" do
    test "Z matches the mpmath likelihood reference and McNemar at delta0 = 0" do
      for %{"b" => b, "c" => c, "n" => n, "delta0" => d0} = row <- @golden["tango_test"] do
        assert {:ok, r} = Hypothesis.tango_test(b, c, n, delta0: d0)
        assert_close(r.z, row["z"], 1.0e-10, 1.0e-12)

        if chi2 = row["mcnemar_chi2"] do
          assert_close(r.z * r.z, chi2, 1.0e-10, 1.0e-12)
        end
      end
    end

    test "p-values follow the alternative" do
      {:ok, two} = Hypothesis.tango_test(9, 4, 50)
      {:ok, less} = Hypothesis.tango_test(9, 4, 50, alternative: :less)
      {:ok, greater} = Hypothesis.tango_test(9, 4, 50, alternative: :greater)

      assert_close(less.p_value + greater.p_value, 1.0, 1.0e-14, 0.0)
      assert_close(two.p_value, 2 * greater.p_value, 1.0e-12, 0.0)
    end

    test "edge cases" do
      assert {:ok, %{z: +0.0, p_value: 1.0}} = Hypothesis.tango_test(0, 0, 10)
      assert Hypothesis.tango_test(0, 0, 0) == {:error, :empty}
      assert Hypothesis.tango_test(6, 6, 10) == {:error, :invalid_counts}
      assert Hypothesis.tango_test(1, 0, 10, delta0: 1.0) == {:error, {:invalid_option, :delta0}}

      assert Hypothesis.tango_test(1, 0, 10, alternative: :up) ==
               {:error, {:invalid_option, :alternative}}
    end
  end

  describe "tango_ci/4" do
    test "bounds match the mpmath reference, including the ±1 boundaries" do
      for %{"b" => b, "c" => c, "n" => n, "confidence" => conf} = row <- @golden["tango_ci"] do
        assert {:ok, %{ci: {lo, hi}, estimate: est}} =
                 Hypothesis.tango_ci(b, c, n, confidence: conf)

        assert_close(lo, row["lower"], 1.0e-10, 1.0e-12)
        assert_close(hi, row["upper"], 1.0e-10, 1.0e-12)
        assert lo <= est and est <= hi
      end
    end

    test "is an error with no pairs" do
      assert Hypothesis.tango_ci(0, 0, 0) == {:error, :empty}
    end
  end

  describe "noninferiority/5" do
    test "is equivalent to the upper (1 - 2α) Tango bound lying below the margin" do
      for {b, c, n} <- [{0, 0, 61}, {1, 0, 61}, {3, 1, 120}, {0, 4, 40}, {6, 2, 90}],
          margin <- [0.02, 0.05, 0.1] do
        {:ok, r} = Hypothesis.noninferiority(b, c, n, margin)
        assert r.non_inferior? == elem(r.ci, 1) < margin
      end
    end

    test "with identical behaviour it passes exactly from noninferiority_n/4 pairs on" do
      for margin <- [0.05, 0.02, 0.01] do
        {:ok, needed} = Power.noninferiority_n(0.0, 0.0, margin)
        assert {:ok, %{non_inferior?: true}} = Hypothesis.noninferiority(0, 0, needed, margin)

        assert {:ok, %{non_inferior?: false}} =
                 Hypothesis.noninferiority(0, 0, needed - 1, margin)
      end
    end

    test "fails closed on too-small datasets and rejects invalid margins" do
      # 18 malicious holdout items cannot certify a 5 pp margin even with no change.
      assert {:ok, %{non_inferior?: false}} = Hypothesis.noninferiority(0, 0, 18, 0.05)
      assert Hypothesis.noninferiority(0, 0, 18, 0.0) == {:error, {:invalid_option, :margin}}

      assert Hypothesis.noninferiority(0, 0, 18, 0.05, alpha: 0.7) ==
               {:error, {:invalid_option, :alpha}}

      assert Hypothesis.noninferiority(0, 0, 0, 0.05) == {:error, :empty}
    end
  end

  describe "holm/2 and benjamini_hochberg/2" do
    test "adjusted p-values and rejections match statsmodels multipletests" do
      for %{"p_values" => ps} = row <- @golden["adjust"] do
        assert {:ok, holm} = Hypothesis.holm(ps)
        assert {:ok, bh} = Hypothesis.benjamini_hochberg(ps)

        for {a, e} <- Enum.zip(holm.adjusted, row["holm"]),
            do: assert_close(a, e, 1.0e-14, 1.0e-15)

        for {a, e} <- Enum.zip(bh.adjusted, row["bh"]), do: assert_close(a, e, 1.0e-14, 1.0e-15)
        assert holm.rejected == row["holm_rejected"]
        assert bh.rejected == row["bh_rejected"]
      end
    end

    test "adjusted values are monotone in the raw p-values" do
      ps = [0.3, 0.001, 0.04, 0.02, 0.5, 0.04, 0.011]

      for fun <- [&Hypothesis.holm/1, &Hypothesis.benjamini_hochberg/1] do
        {:ok, %{adjusted: adjusted}} = fun.(ps)
        pairs = Enum.zip(ps, adjusted) |> Enum.sort()

        pairs
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [{_, a1}, {_, a2}] -> assert a1 <= a2 end)
      end
    end

    test "empty input and invalid p-values" do
      assert {:ok, %{adjusted: [], rejected: []}} = Hypothesis.holm([])
      assert Hypothesis.benjamini_hochberg([0.1, 1.2]) == {:error, :invalid_values}
      assert Hypothesis.holm([0.1], alpha: 0) == {:error, {:invalid_option, :alpha}}
    end
  end
end

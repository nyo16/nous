defmodule Nous.Eval.StatsTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats

  doctest Stats

  # Golden values: NumPy/SciPy/statsmodels and exact rationals, see
  # test/fixtures/stats/generate.py.
  @fixtures Path.expand("../../fixtures/stats", __DIR__)
  @external_resource Path.join(@fixtures, "descriptives.json")
  @external_resource Path.join(@fixtures, "proportions.json")
  @external_resource Path.join(@fixtures, "pass_k.json")
  @descriptives @fixtures |> Path.join("descriptives.json") |> File.read!() |> JSON.decode!()
  @proportions @fixtures |> Path.join("proportions.json") |> File.read!() |> JSON.decode!()
  @pass_k @fixtures |> Path.join("pass_k.json") |> File.read!() |> JSON.decode!()

  defp assert_close(actual, expected, rtol, atol) do
    assert is_float(actual), "expected a float, got #{inspect(actual)}"
    diff = abs(actual - expected)

    assert diff <= atol + rtol * abs(expected),
           "expected #{expected}, got #{actual} (diff #{diff})"
  end

  defp assert_ci({lo, hi}, [e_lo, e_hi], rtol, atol) do
    assert_close(lo, e_lo, rtol, atol)
    assert_close(hi, e_hi, rtol, atol)
  end

  describe "describe/1" do
    test "Welford mean and variance match NumPy, including large offsets" do
      for %{"values" => values, "mean" => mean, "variance" => variance} <-
            @descriptives["describe"] do
        assert {:ok, r} = Stats.describe(values)
        assert r.n == length(values)
        assert_close(r.mean, mean, 1.0e-14, 1.0e-15)
        assert_close(r.variance, variance, 1.0e-10, 1.0e-15)
        assert_close(r.se, :math.sqrt(variance / length(values)), 1.0e-10, 1.0e-15)
      end
    end

    test "edge cases are errors or nil, never a crash" do
      assert Stats.describe([]) == {:error, :empty}
      assert Stats.describe([1, :a]) == {:error, :invalid_values}
      assert {:ok, %{n: 1, mean: 3.0, variance: nil, sd: nil, se: nil}} = Stats.describe([3])
    end
  end

  describe "mean_ci/2" do
    test "t-interval matches scipy.stats.t.interval" do
      for %{"values" => values, "confidence" => conf} = row <- @descriptives["mean_ci"] do
        assert {:ok, %{ci: ci}} = Stats.mean_ci(values, confidence: conf)
        assert_ci(ci, [row["lower"], row["upper"]], 1.0e-11, 1.0e-12)
      end
    end

    test "needs two values and a valid confidence" do
      assert Stats.mean_ci([0.5]) == {:error, :insufficient_data}
      assert Stats.mean_ci([]) == {:error, :empty}
      assert Stats.mean_ci([0.1, 0.2], confidence: 1.0) == {:error, :invalid_confidence}
    end

    test "constant data gives a zero-width interval" do
      assert {:ok, %{estimate: 0.25, se: +0.0, ci: {0.25, 0.25}}} =
               Stats.mean_ci([0.25, 0.25, 0.25])
    end
  end

  describe "quantile/2" do
    test "type-7 interpolation and errors" do
      assert Stats.quantiles([10, 0, 5], [0.0, 0.25, 1.0]) == {:ok, [0.0, 2.5, 10.0]}
      assert Stats.quantile([7], 0.3) == {:ok, 7.0}
      assert Stats.quantile([], 0.5) == {:error, :empty}
      assert Stats.quantile([1, 2], 1.5) == {:error, {:invalid_option, :p}}
    end
  end

  describe "clustered_se/1" do
    test "matches statsmodels' cluster-robust (CR1) standard error" do
      for %{"clusters" => clusters, "mean" => mean, "se" => se} <- @descriptives["clustered_se"] do
        assert {:ok, r} = Stats.clustered_se(clusters)
        assert_close(r.mean, mean, 1.0e-13, 1.0e-15)
        assert_close(r.se, se, 1.0e-10, 1.0e-15)
        assert r.clusters == length(clusters)
      end
    end

    test "treating k samples of one case as independent understates the error" do
      # Three cases, each with 4 identical samples: the information is 3 cases.
      clusters = [[1, 1, 1, 1], [0, 0, 0, 0], [1, 1, 1, 1]]
      {:ok, clustered} = Stats.clustered_se(clusters)
      {:ok, naive} = clusters |> List.flatten() |> Stats.describe()
      {:ok, per_case} = Stats.describe([1, 0, 1])

      assert_close(clustered.se, per_case.se, 1.0e-12, 1.0e-15)
      assert naive.se < clustered.se / 1.5
    end

    test "needs two non-empty clusters" do
      assert Stats.clustered_se([[1, 0, 1]]) == {:error, :insufficient_clusters}
      assert Stats.clustered_se([[1, 0], []]) == {:error, :insufficient_clusters}
      assert Stats.clustered_se([[1], [:x]]) == {:error, :invalid_values}
    end
  end

  describe "paired_se/2" do
    test "matches the SE of differences and the Pearson correlation" do
      for %{"candidate" => cand, "baseline" => base} = row <- @descriptives["paired_se"] do
        assert {:ok, r} = Stats.paired_se(cand, base)
        assert_close(r.mean_difference, row["mean_difference"], 1.0e-12, 1.0e-15)
        assert_close(r.se, row["se"], 1.0e-10, 1.0e-15)
        assert_close(r.correlation, row["correlation"], 1.0e-12, 1.0e-15)
      end
    end

    test "edge cases" do
      assert Stats.paired_se([1, 2], [1]) == {:error, :length_mismatch}
      assert Stats.paired_se([1], [1]) == {:error, :insufficient_data}
      assert {:ok, %{correlation: nil, se: +0.0}} = Stats.paired_se([1, 1, 1], [0, 0, 0])
    end
  end

  describe "proportion intervals" do
    test "Wilson, Clopper–Pearson and Jeffreys match statsmodels proportion_confint" do
      for %{"successes" => x, "n" => n, "confidence" => conf} = row <- @proportions["intervals"] do
        assert {:ok, w} = Stats.wilson(x, n, confidence: conf)
        assert_ci(w.ci, row["wilson"], 1.0e-12, 1.0e-15)
        assert {:ok, cp} = Stats.clopper_pearson(x, n, confidence: conf)
        assert_ci(cp.ci, row["clopper_pearson"], 1.0e-11, 1.0e-15)
        assert {:ok, j} = Stats.jeffreys(x, n, confidence: conf)
        assert_ci(j.ci, row["jeffreys"], 1.0e-11, 1.0e-15)
        assert w.estimate == x / n
      end
    end

    test "Beta posterior matches scipy.stats.beta" do
      for %{"successes" => x, "n" => n, "prior" => [a, b]} = row <- @proportions["beta_posterior"] do
        assert {:ok, r} = Stats.beta_posterior(x, n, prior: {a, b})
        assert_close(r.estimate, row["mean"], 1.0e-14, 1.0e-15)
        assert_ci(r.ci, [row["lower"], row["upper"]], 1.0e-11, 1.0e-15)
      end
    end

    test "n = 0 is an error for rate intervals and returns the prior for the posterior" do
      assert Stats.wilson(0, 0) == {:error, :empty}
      assert Stats.clopper_pearson(0, 0) == {:error, :empty}
      assert Stats.jeffreys(0, 0) == {:error, :empty}
      assert {:ok, %{estimate: 0.5, posterior: {1, 1}, ci: {lo, hi}}} = Stats.beta_posterior(0, 0)
      assert_close(lo, 0.025, 1.0e-12, 1.0e-15)
      assert_close(hi, 0.975, 1.0e-12, 1.0e-15)
    end

    test "invalid counts and options" do
      assert Stats.wilson(5, 4) == {:error, :invalid_counts}
      assert Stats.wilson(-1, 4) == {:error, :invalid_counts}
      assert Stats.wilson(1.0, 4) == {:error, :invalid_counts}
      assert Stats.wilson(1, 4, confidence: 0) == {:error, :invalid_confidence}
      assert Stats.beta_posterior(1, 4, prior: {0, 1}) == {:error, {:invalid_option, :prior}}
    end

    test "one-sided Clopper–Pearson upper bound for zero events follows the rule of three" do
      for {n, expected} <- [{18, 0.153}, {61, 0.048}, {100, 0.0295}, {300, 0.0099}] do
        {:ok, %{ci: {+0.0, upper}}} = Stats.clopper_pearson(0, n, confidence: 0.90)
        assert_in_delta upper, expected, 0.0006
      end
    end
  end

  describe "pass_at_k/3 and pass_hat_k/3" do
    test "match exact rational binomial ratios" do
      for %{"n" => n, "c" => c, "k" => k} = row <- @pass_k["cases"] do
        assert {:ok, at} = Stats.pass_at_k(n, c, k)
        assert_close(at, row["pass_at_k"], 1.0e-12, 1.0e-15)
        assert {:ok, hat} = Stats.pass_hat_k(n, c, k)
        assert_close(hat, row["pass_hat_k"], 1.0e-12, 1.0e-300)
      end
    end

    test "k = 1 reduces both to c / n" do
      for {n, c} <- [{3, 0}, {3, 2}, {7, 7}] do
        assert {:ok, at} = Stats.pass_at_k(n, c, 1)
        assert {:ok, hat} = Stats.pass_hat_k(n, c, 1)
        assert_close(at, c / n, 1.0e-15, 1.0e-15)
        assert_close(hat, c / n, 1.0e-15, 1.0e-15)
      end
    end

    test "argument errors" do
      assert Stats.pass_at_k(3, 1, 4) == {:error, :k_exceeds_n}
      assert Stats.pass_hat_k(3, 1, 0) == {:error, :invalid_k}
      assert Stats.pass_at_k(3, 4, 1) == {:error, :invalid_counts}
      assert Stats.pass_hat_k(0, 0, 1) == {:error, :k_exceeds_n}
    end
  end
end

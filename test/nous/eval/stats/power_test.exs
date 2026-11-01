defmodule Nous.Eval.Stats.PowerTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats.Power

  doctest Power

  # Golden values: statsmodels NormalIndPower, mpmath for Connor and the
  # non-inferiority formula, scipy for Miller eq. 9/10 (see
  # test/fixtures/stats/generate.py).
  @fixture_path Path.expand("../../../fixtures/stats/power.json", __DIR__)
  @external_resource @fixture_path
  @golden @fixture_path |> File.read!() |> JSON.decode!()

  defp assert_close(actual, expected, rtol, atol) do
    assert is_float(actual), "expected a float, got #{inspect(actual)}"
    diff = abs(actual - expected)

    assert diff <= atol + rtol * abs(expected),
           "expected #{expected}, got #{actual} (diff #{diff})"
  end

  describe "paired MDE and sample size (Miller eq. 9/10)" do
    test "mde/3 reproduces the ω² = 1/9, σ² = 1/6 table" do
      for %{"n" => n, "variance" => v, "mde" => mde} <- @golden["mde"] do
        assert {:ok, actual} = Power.mde(n, v)
        assert_close(actual, mde, 1.0e-13, 0.0)
      end
    end

    test "sample_size/3 reproduces the cases-needed table" do
      for %{"delta" => d, "variance" => v, "n" => n} <- @golden["sample_size"] do
        assert Power.sample_size(d, v) == {:ok, n}
      end
    end

    test "the MDE at the planned n is detectable with the requested power" do
      {:ok, n} = Power.sample_size(0.1, 0.2)
      {:ok, mde} = Power.mde(n, 0.2)
      assert mde <= 0.1
      {:ok, mde_smaller} = Power.mde(n - 1, 0.2)
      assert mde_smaller > 0.1
    end

    test "errors" do
      assert Power.mde(0, 0.2) == {:error, :empty}
      assert Power.mde(10, -1) == {:error, :invalid_values}
      assert Power.mde(10, 0.2, power: 1.0) == {:error, {:invalid_option, :power}}
      assert Power.sample_size(0, 0.2) == {:error, :no_effect}
    end
  end

  describe "variance_components/2" do
    test "recovers the variance of per-case differences at the observed k" do
      cand = [[1, 1, 0], [0, 0, 1], [1, 1, 1], [0, 1, 0], [1, 0, 1]]
      base = [[1, 0, 0], [0, 0, 0], [1, 1, 0], [0, 1, 1], [0, 0, 1]]
      {:ok, c} = Power.variance_components(cand, base)

      diffs = Enum.zip_with(cand, base, &(Enum.sum(&1) / 3 - Enum.sum(&2) / 3))
      {:ok, %{variance: var_d}} = Nous.Eval.Stats.describe(diffs)

      # Binary scores: within-case variance is p(1-p)·k/(k-1), averaged.
      expected_sigma_a =
        Enum.sum(Enum.map(cand, &(Enum.sum(&1) / 3 * (1 - Enum.sum(&1) / 3) * 1.5))) / 5

      assert_close(c.sigma2_a, expected_sigma_a, 1.0e-12, 1.0e-15)
      assert c.k_a == 3.0
      assert_close(max(var_d - c.sigma2_a / 3 - c.sigma2_b / 3, 0.0), c.omega2, 1.0e-12, 1.0e-15)
    end

    test "needs two samples per case and matching case lists" do
      assert Power.variance_components([[1], [0]], [[1, 0], [0, 0]]) ==
               {:error, :insufficient_data}

      assert Power.variance_components([[1, 0]], [[1, 0], [0, 0]]) == {:error, :length_mismatch}

      assert Power.variance_components([[1, :x], [0, 0]], [[1, 0], [0, 0]]) ==
               {:error, :invalid_values}
    end
  end

  describe "two independent proportions" do
    test "power matches statsmodels NormalIndPower" do
      for %{"p1" => p1, "p2" => p2, "n" => n, "alpha" => a, "power" => power} <-
            @golden["two_proportion_power"] do
        assert {:ok, actual} = Power.two_proportion_power(p1, p2, n, alpha: a)
        assert_close(actual, power, 1.0e-12, 1.0e-15)
      end
    end

    test "sample size matches ceil(statsmodels solve_power)" do
      for %{"p1" => p1, "p2" => p2, "alpha" => a, "power" => power, "n" => n} <-
            @golden["two_proportion_n"] do
        assert Power.two_proportion_n(p1, p2, alpha: a, power: power) == {:ok, n}
      end
    end

    test "equal proportions have no effect to size for" do
      assert Power.two_proportion_n(0.5, 0.5) == {:error, :no_effect}
      assert Power.two_proportion_power(0.5, 1.5, 10) == {:error, {:invalid_option, :p2}}
    end
  end

  describe "McNemar (Connor 1987)" do
    test "power matches the mpmath reference" do
      for %{"p_b" => pb, "p_c" => pc, "n" => n, "alpha" => a, "power" => power} <-
            @golden["mcnemar_power"] do
        assert {:ok, actual} = Power.mcnemar_power(pb, pc, n, alpha: a)
        assert_close(actual, power, 1.0e-12, 1.0e-15)
      end
    end

    test "sample size matches the mpmath reference" do
      for %{"p_b" => pb, "p_c" => pc, "alpha" => a, "power" => power, "n" => n} <-
            @golden["mcnemar_n"] do
        assert Power.mcnemar_n(pb, pc, alpha: a, power: power) == {:ok, n}
      end
    end

    test "degenerate discordance" do
      assert Power.mcnemar_power(0.0, 0.0, 100) == {:ok, 0.0}
      assert Power.mcnemar_power(1.0, 0.0, 100) == {:ok, 1.0}
      assert Power.mcnemar_n(0.1, 0.1) == {:error, :no_effect}
      assert Power.mcnemar_power(0.7, 0.6, 10) == {:error, {:invalid_option, :p_c}}
    end
  end

  describe "paired non-inferiority (Tango / Nam)" do
    test "power matches the mpmath reference" do
      for %{"p_b" => pb, "p_c" => pc, "margin" => m, "n" => n, "alpha" => a, "power" => power} <-
            @golden["noninferiority_power"] do
        assert {:ok, actual} = Power.noninferiority_power(pb, pc, m, n, alpha: a)
        assert_close(actual, power, 1.0e-11, 1.0e-15)
      end
    end

    test "sample size matches the mpmath reference and the research worked numbers" do
      for %{"p_b" => pb, "p_c" => pc, "margin" => m, "alpha" => a, "power" => power, "n" => n} <-
            @golden["noninferiority_n"] do
        assert Power.noninferiority_n(pb, pc, m, alpha: a, power: power) == {:ok, n}
      end

      assert Power.noninferiority_n(0.0, 0.0, 0.05) == {:ok, 52}
      assert Power.noninferiority_n(0.0, 0.0, 0.01) == {:ok, 268}
    end

    test "a true difference at or above the margin cannot be certified" do
      assert Power.noninferiority_n(0.06, 0.0, 0.05) == {:error, :effect_not_below_margin}

      assert Power.noninferiority_power(0.06, 0.0, 0.05, 100) ==
               {:error, :effect_not_below_margin}
    end

    test "with no discordance the power is a step in n" do
      assert Power.noninferiority_power(0.0, 0.0, 0.05, 52) == {:ok, 1.0}
      assert Power.noninferiority_power(0.0, 0.0, 0.05, 51) == {:ok, 0.0}
    end
  end
end

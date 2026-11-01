defmodule Nous.Eval.Stats.SpecialTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Stats.Special

  doctest Special

  # Golden values: SciPy, see test/fixtures/stats/generate.py.
  @fixture_path Path.expand("../../../fixtures/stats/special.json", __DIR__)
  @external_resource @fixture_path
  @golden @fixture_path |> File.read!() |> JSON.decode!()

  defp assert_close(actual, expected, rtol, atol) do
    assert is_float(actual), "expected a float, got #{inspect(actual)}"
    diff = abs(actual - expected)

    assert diff <= atol + rtol * abs(expected),
           "expected #{expected}, got #{actual} (diff #{diff})"
  end

  describe "lgamma/1" do
    test "matches scipy.special.gammaln (rel 1e-13)" do
      for %{"x" => x, "expected" => e} <- @golden["lgamma"] do
        assert_close(Special.lgamma(x), e, 1.0e-13, 1.0e-14)
      end
    end

    test "log_choose/2 agrees with exact integer binomials" do
      for {n, k} <- [{10, 3}, {52, 5}, {100, 50}, {7, 0}, {7, 7}] do
        exact = :math.log(binomial(n, k))
        assert_close(Special.log_choose(n, k), exact, 1.0e-13, 1.0e-13)
      end
    end
  end

  describe "betainc/3" do
    test "matches scipy.special.betainc (rel 1e-12)" do
      for %{"a" => a, "b" => b, "x" => x, "expected" => e} <- @golden["betainc"] do
        assert_close(Special.betainc(a, b, x), e, 1.0e-12, 1.0e-15)
      end
    end

    test "is exactly 0 and 1 at the ends of the support" do
      assert Special.betainc(2.5, 3.0, 0) == 0.0
      assert Special.betainc(2.5, 3.0, 1) == 1.0
    end
  end

  describe "beta_quantile/3" do
    test "matches scipy.special.betaincinv (rel 1e-12)" do
      for %{"p" => p, "a" => a, "b" => b, "expected" => e} <- @golden["beta_quantile"] do
        assert_close(Special.beta_quantile(p, a, b), e, 1.0e-12, 1.0e-15)
      end
    end

    test "returns the support ends for p = 0 and p = 1" do
      assert Special.beta_quantile(0, 3, 4) == 0.0
      assert Special.beta_quantile(1, 3, 4) == 1.0
    end
  end

  describe "normal distribution" do
    # 1e-12: OTP's libm erfc is ~2e-13 relative deep in the tail (x = -37).
    test "norm_cdf/1 matches scipy.special.ndtr (rel 1e-12)" do
      for %{"x" => x, "expected" => e} <- @golden["norm_cdf"] do
        assert_close(Special.norm_cdf(x), e, 1.0e-12, 0.0)
      end
    end

    test "norm_quantile/1 matches scipy.special.ndtri in both tails (rel 1e-14)" do
      for %{"p" => p, "expected" => e} <- @golden["norm_quantile"] do
        assert_close(Special.norm_quantile(p), e, 1.0e-14, 1.0e-15)
      end
    end
  end

  describe "Student t distribution" do
    test "t_cdf/2 matches scipy.stats.t.cdf (rel 1e-12)" do
      for %{"t" => t, "df" => df, "expected" => e} <- @golden["t_cdf"] do
        assert_close(Special.t_cdf(t, df), e, 1.0e-12, 1.0e-15)
      end
    end

    test "t_quantile/2 matches scipy.stats.t.ppf (rel 1e-11)" do
      for %{"p" => p, "df" => df, "expected" => e} <- @golden["t_quantile"] do
        assert_close(Special.t_quantile(p, df), e, 1.0e-11, 1.0e-14)
      end
    end
  end

  test "sorted_quantile/2 matches numpy type-7 quantiles" do
    %{"values" => values, "probs" => probs, "expected" => expected} = @golden["quantile"]
    sorted = Enum.sort(values)

    for {p, e} <- Enum.zip(probs, expected) do
      assert_close(Special.sorted_quantile(sorted, p), e, 1.0e-14, 1.0e-15)
    end
  end

  defp binomial(n, k),
    do:
      div(
        Enum.reduce(1..n//1, 1, &(&1 * &2)),
        Enum.reduce(1..k//1, 1, &(&1 * &2)) * Enum.reduce(1..(n - k)//1, 1, &(&1 * &2))
      )
end

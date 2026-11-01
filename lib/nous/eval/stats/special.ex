defmodule Nous.Eval.Stats.Special do
  @moduledoc """
  Special functions and distribution primitives behind `Nous.Eval.Stats`.

  OTP's `:math` has `erf/1` and `erfc/1` but no log-gamma, so everything that
  needs a Beta or binomial term is built here from a Lanczos `lgamma/1`.

  These are numeric primitives: each function is total on the domain stated in
  its `@doc` and returns a float. Arguments outside that domain do not match
  any clause (`FunctionClauseError`); the data-facing functions in
  `Nous.Eval.Stats` and its other submodules validate their inputs and return
  `{:error, reason}` before calling in here.

  Accuracy (checked against SciPy in `test/nous/eval/stats/special_test.exs`):
  `lgamma/1` about 1e-14 relative, `betainc/3` and `beta_quantile/3` about
  1e-12, `norm_quantile/1` about 1e-14 (Acklam's approximation plus one
  Halley step).
  """

  # Lanczos approximation, g = 7, n = 9 (the coefficient set published with
  # Numerical Recipes 3rd ed. §6.1 and widely reused); ~15 significant digits.
  @lanczos_g 7
  @lanczos_coefs [
    676.5203681218851,
    -1259.1392167224028,
    771.32342877765313,
    -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
    9.9843695780195716e-6,
    1.5056327351493116e-7
  ]
  @lanczos_c0 0.99999999999980993
  @half_log_2pi 0.9189385332046727

  # Continued-fraction controls for `betainc/3` (modified Lentz).
  @cf_eps 3.0e-16
  @cf_tiny 1.0e-300
  @cf_max_iter 20_000

  # Acklam's inverse-normal rational approximation (relative error < 1.15e-9
  # before refinement).
  @acklam_a [
    -3.969683028665376e+01,
    2.209460984245205e+02,
    -2.759285104469687e+02,
    1.383577518672690e+02,
    -3.066479806614716e+01,
    2.506628277459239e+00
  ]
  @acklam_b [
    -5.447609879822406e+01,
    1.615858368580409e+02,
    -1.556989798598866e+02,
    6.680131188771972e+01,
    -1.328068155288572e+01,
    1.0
  ]
  @acklam_c [
    -7.784894002430293e-03,
    -3.223964580411365e-01,
    -2.400758277161838e+00,
    -2.549732539343734e+00,
    4.374664141464968e+00,
    2.938163982698783e+00
  ]
  @acklam_d [
    7.784695709041462e-03,
    3.224671290700398e-01,
    2.445134137142996e+00,
    3.754408661907416e+00,
    1.0
  ]
  @acklam_low 0.02425

  @doc """
  Natural log of the gamma function, `ln Γ(x)`, for `x > 0`.

  ## Examples

      iex> Nous.Eval.Stats.Special.lgamma(1.0) |> abs() < 1.0e-14
      true
      iex> Nous.Eval.Stats.Special.lgamma(10) |> Float.round(10)
      12.8018274801
  """
  @spec lgamma(number()) :: float()
  def lgamma(x) when is_number(x) and x > 0 and x < 0.5 do
    # Reflection keeps the Lanczos sum in its accurate range.
    :math.log(:math.pi() / :math.sin(:math.pi() * x)) - lgamma(1 - x)
  end

  def lgamma(x) when is_number(x) and x >= 0.5 do
    z = x - 1

    {sum, _} =
      Enum.reduce(@lanczos_coefs, {@lanczos_c0, 1}, fn c, {acc, i} ->
        {acc + c / (z + i), i + 1}
      end)

    t = z + @lanczos_g + 0.5
    @half_log_2pi + (z + 0.5) * :math.log(t) - t + :math.log(sum)
  end

  @doc """
  `ln C(n, k)` for integers `0 <= k <= n`.

  ## Examples

      iex> Nous.Eval.Stats.Special.log_choose(10, 3) |> :math.exp() |> round()
      120
  """
  @spec log_choose(non_neg_integer(), non_neg_integer()) :: float()
  def log_choose(n, k) when is_integer(n) and is_integer(k) and k >= 0 and k <= n do
    if k == 0 or k == n,
      do: 0.0,
      else: -:math.log(n + 1) - log_beta(k + 1, n - k + 1)
  end

  @doc """
  `ln B(a, b)` for `a, b > 0`.

  When an argument is 10 or more the large `lgamma` terms are combined
  analytically (Stirling remainder plus `log1p`, as in R's `lbeta`), so the
  result keeps full relative accuracy instead of losing digits to
  cancellation between `lgamma(b)` and `lgamma(a + b)`.
  """
  @spec log_beta(number(), number()) :: float()
  def log_beta(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0 do
    p = min(a, b)
    q = max(a, b)
    ratio = p / (p + q)

    cond do
      p >= 10 ->
        corr = stirling_corr(p) + stirling_corr(q) - stirling_corr(p + q)

        -0.5 * :math.log(q) + @half_log_2pi + corr + (p - 0.5) * :math.log(ratio) +
          q * log1p(-ratio)

      q >= 10 ->
        corr = stirling_corr(q) - stirling_corr(p + q)
        lgamma(p) + corr + p - p * :math.log(p + q) + (q - 0.5) * log1p(-ratio)

      true ->
        lgamma(a) + lgamma(b) - lgamma(a + b)
    end
  end

  # lgamma(x) − [(x − ½)·ln x − x + ½·ln 2π] for x >= 10: the Stirling
  # series Σ B₂ₖ / (2k(2k−1)·x^(2k−1)); eight terms reach double precision.
  @stirling_coefs [
    -3617 / 122_400,
    1 / 156,
    -691 / 360_360,
    1 / 1188,
    -1 / 1680,
    1 / 1260,
    -1 / 360,
    1 / 12
  ]
  defp stirling_corr(x) do
    inv2 = 1 / (x * x)
    Enum.reduce(@stirling_coefs, 0.0, &(&2 * inv2 + &1)) / x
  end

  @doc """
  Regularized incomplete beta function `I_x(a, b)` for `a, b > 0` and
  `0 <= x <= 1`; this is also the CDF of `Beta(a, b)` at `x`.

  Evaluated by the continued fraction of Numerical Recipes §6.4 with the
  modified Lentz method, using the symmetry `I_x(a, b) = 1 - I_{1-x}(b, a)`
  on the side where the fraction converges fast.

  ## Examples

      iex> Nous.Eval.Stats.Special.betainc(2, 3, 0.4) |> Float.round(12)
      0.5248
  """
  @spec betainc(number(), number(), number()) :: float()
  def betainc(a, b, x)
      when is_number(a) and is_number(b) and a > 0 and b > 0 and is_number(x) and x >= 0 and
             x <= 1 do
    cond do
      x == 0 ->
        0.0

      x == 1 ->
        1.0

      x < (a + 1) / (a + b + 2) ->
        beta_front(a, b, x) * beta_cf(a, b, x) / a

      true ->
        1.0 - beta_front(b, a, 1 - x) * beta_cf(b, a, 1 - x) / b
    end
  end

  defp beta_front(a, b, x) do
    :math.exp(a * :math.log(x) + b * log1p(-x) - log_beta(a, b))
  end

  defp beta_cf(a, b, x) do
    qab = a + b
    qap = a + 1
    qam = a - 1
    d = 1 / nonzero(1 - qab * x / qap)
    lentz(1, 1.0, d, d, {a, b, x, qab, qap, qam})
  end

  # One iteration evaluates an even and an odd term of the fraction. It
  # converges in O(sqrt(max(a, b))) iterations; the cap is only reached for
  # a, b around 1e8, far beyond any eval count.
  defp lentz(m, c, d, h, {a, b, x, qab, qap, qam} = params) do
    m2 = 2 * m
    even = m * (b - m) * x / ((qam + m2) * (a + m2))
    d = 1 / nonzero(1 + even * d)
    c = nonzero(1 + even / c)
    h = h * d * c
    odd = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
    d = 1 / nonzero(1 + odd * d)
    c = nonzero(1 + odd / c)
    delta = d * c
    h = h * delta

    if abs(delta - 1) < @cf_eps or m >= @cf_max_iter,
      do: h,
      else: lentz(m + 1, c, d, h, params)
  end

  defp nonzero(v) when abs(v) < @cf_tiny, do: @cf_tiny
  defp nonzero(v), do: v

  @doc """
  Quantile of `Beta(a, b)`: the `x` with `betainc(a, b, x) == p`, for
  `0 <= p <= 1` and `a, b > 0`. Found by bisection to full double precision.

  ## Examples

      iex> Nous.Eval.Stats.Special.beta_quantile(0.5, 2, 2) |> Float.round(12)
      0.5
  """
  @spec beta_quantile(number(), number(), number()) :: float()
  def beta_quantile(p, a, b)
      when is_number(p) and p >= 0 and p <= 1 and is_number(a) and is_number(b) and a > 0 and
             b > 0 do
    cond do
      p == 0 -> 0.0
      p == 1 -> 1.0
      true -> bisect(fn x -> betainc(a, b, x) < p end, 0.0, 1.0)
    end
  end

  # Bisection on a monotone predicate `below?(x)` (true left of the root),
  # stopping once the bracket is a few ulps wide or cannot be split further.
  @doc false
  @spec bisect((float() -> boolean()), float(), float()) :: float()
  def bisect(below?, lo, hi), do: bisect(below?, lo, hi, 0)

  defp bisect(below?, lo, hi, iter) do
    mid = (lo + hi) / 2

    cond do
      iter >= 2_000 or mid <= lo or mid >= hi or hi - lo <= 4.0e-16 * abs(hi) -> mid
      below?.(mid) -> bisect(below?, mid, hi, iter + 1)
      true -> bisect(below?, lo, mid, iter + 1)
    end
  end

  @doc """
  Standard normal CDF `Φ(x)`.

  ## Examples

      iex> Nous.Eval.Stats.Special.norm_cdf(0)
      0.5
  """
  @spec norm_cdf(number()) :: float()
  def norm_cdf(x) when is_number(x), do: 0.5 * :math.erfc(-x / :math.sqrt(2))

  @doc """
  Standard normal quantile `Φ⁻¹(p)` for `0 < p < 1`.

  Acklam's rational approximation refined by one Halley step on the
  `erfc`-based CDF. The upper half is computed as `-Φ⁻¹(1 - p)`, which is
  exact in floating point for `p >= 0.5`, so both tails keep full relative
  accuracy.

  ## Examples

      iex> Nous.Eval.Stats.Special.norm_quantile(0.975) |> Float.round(10)
      1.9599639845
  """
  @spec norm_quantile(number()) :: float()
  def norm_quantile(p) when is_number(p) and p > 0 and p < 1 do
    cond do
      p == 0.5 -> 0.0
      p > 0.5 -> -lower_norm_quantile(1 - p)
      true -> lower_norm_quantile(p)
    end
  end

  defp lower_norm_quantile(p) do
    x = acklam(p)
    e = norm_cdf(x) - p

    if e == 0 do
      x
    else
      # u = e / φ(x), written so that exp() never overflows deep in the tail.
      u = e / p * :math.exp(:math.log(p) + x * x / 2 + @half_log_2pi)
      x - u / (1 + x * u / 2)
    end
  end

  defp acklam(p) when p < @acklam_low do
    q = :math.sqrt(-2 * :math.log(p))
    horner(@acklam_c, q) / horner(@acklam_d, q)
  end

  defp acklam(p) do
    q = p - 0.5
    r = q * q
    horner(@acklam_a, r) * q / horner(@acklam_b, r)
  end

  defp horner([c | rest], x), do: Enum.reduce(rest, c, fn coef, acc -> acc * x + coef end)

  @doc """
  CDF of Student's t distribution with `df > 0` degrees of freedom.

  ## Examples

      iex> Nous.Eval.Stats.Special.t_cdf(0, 5)
      0.5
  """
  @spec t_cdf(number(), number()) :: float()
  def t_cdf(t, df) when is_number(t) and is_number(df) and df > 0 do
    tail = 0.5 * betainc(df / 2, 0.5, df / (df + t * t))
    if t >= 0, do: 1.0 - tail, else: tail
  end

  @doc """
  Quantile of Student's t distribution with `df > 0` degrees of freedom, for
  `0 < p < 1`.

  ## Examples

      iex> Nous.Eval.Stats.Special.t_quantile(0.975, 10) |> Float.round(6)
      2.228139
  """
  @spec t_quantile(number(), number()) :: float()
  def t_quantile(p, df) when is_number(p) and p > 0 and p < 1 and is_number(df) and df > 0 do
    cond do
      p == 0.5 -> 0.0
      p > 0.5 -> -lower_t_quantile(1 - p, df)
      true -> lower_t_quantile(p, df)
    end
  end

  # For t < 0, P(T <= t) = I_x(df/2, 1/2) / 2 with x = df / (df + t²).
  defp lower_t_quantile(p, df) do
    x = beta_quantile(2 * p, df / 2, 0.5)
    -:math.sqrt(df * (1 - x) / x)
  end

  @doc """
  Sample quantile of a list at probability `0 <= p <= 1`, using linear
  interpolation between order statistics (Hyndman–Fan type 7, the default of
  R's `quantile` and NumPy's `quantile`). The list must be non-empty and
  already sorted ascending.
  """
  @spec sorted_quantile([number()], number()) :: float()
  def sorted_quantile([_ | _] = sorted, p) when is_number(p) and p >= 0 and p <= 1 do
    sorted |> List.to_tuple() |> tuple_quantile(p)
  end

  @doc false
  @spec tuple_quantile(tuple(), number()) :: float()
  def tuple_quantile(tuple, p) do
    h = (tuple_size(tuple) - 1) * p
    lo = floor(h)
    x_lo = elem(tuple, lo) / 1

    if lo + 1 >= tuple_size(tuple),
      do: x_lo,
      else: x_lo + (h - lo) * (elem(tuple, lo + 1) - x_lo)
  end

  @doc false
  @spec log1p(float()) :: float()
  def log1p(x) do
    # Exact-enough log(1 + x) for small x without :math.log1p (absent in OTP).
    u = 1.0 + x
    if u == 1.0, do: x / 1, else: :math.log(u) * x / (u - 1.0)
  end
end

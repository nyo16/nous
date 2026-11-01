defmodule Nous.Eval.Stats.Hypothesis do
  @moduledoc """
  Significance tests and multiple-comparison control for eval comparisons.

    * `mcnemar/2` - exact McNemar test (binomial on discordant pairs) with the
      mid-P variant, for paired binary outcomes
    * `fisher_exact/4` - Fisher's exact test for an unpaired 2×2 table
    * `tango_test/4`, `tango_ci/4` - Tango's score test and interval for the
      difference of two paired proportions (Tango 1998, Statistics in
      Medicine 17:891–908; the interval of R's `PropCIs::scoreci.mp`)
    * `noninferiority/5` - the paired non-inferiority gate used for guard
      non-regression (H0: Δ ≥ margin)
    * `holm/2`, `benjamini_hochberg/2` - adjusted p-values

  ## Orientation of paired counts

  For `n` paired cases, `b` counts cases where the candidate has the event
  and the baseline does not, and `c` the reverse. The paired difference is
  `Δ = p_candidate − p_baseline = (b − c) / n`. For a guard's false-allow
  rate, `b` is "new misses" and `c` is "fixes".

  Per-case significance is almost never reachable at realistic k (the most
  extreme 3-of-3 vs 0-of-3 table has two-sided Fisher p = 0.1), so gate on aggregate
  tests and use Holm across a small declared family of metrics; use
  Benjamini–Hochberg for exploratory per-tag breakdowns.
  """

  import Nous.Eval.Stats.Guards

  alias Nous.Eval.Stats.Special

  # Tables whose probability is within this relative distance of the observed
  # one count as "as extreme" (R's fisher.test uses the same 1e-7).
  @fisher_rel_tol 1.0e-7

  @doc """
  Exact McNemar test on the discordant counts `b` and `c`.

  `:p_value` is the two-sided exact p-value, `min(1, 2·P(X ≤ min(b, c)))`
  with `X ~ Binomial(b + c, ½)`. `:mid_p_value` subtracts half the
  probability of the observed table (Fagerland, Lydersen & Laake 2013), which
  is less conservative and close to nominal size. `:statistic` is `min(b, c)`.

  `b + c == 0` (no discordant pairs) gives `p_value: 1.0, mid_p_value: 1.0`.

  ## Examples

      iex> Nous.Eval.Stats.Hypothesis.mcnemar(0, 5)
      {:ok, %{b: 0, c: 5, statistic: 0, p_value: 0.0625, mid_p_value: 0.03125}}
  """
  @spec mcnemar(non_neg_integer(), non_neg_integer()) ::
          {:ok,
           %{
             b: non_neg_integer(),
             c: non_neg_integer(),
             statistic: non_neg_integer(),
             p_value: float(),
             mid_p_value: float()
           }}
          | {:error, :invalid_counts}
  def mcnemar(b, c) when is_count(b) and is_count(c) do
    k = min(b, c)
    base = %{b: b, c: c, statistic: k}

    if b + c == 0 do
      {:ok, Map.merge(base, %{p_value: 1.0, mid_p_value: 1.0})}
    else
      {cdf, pmf} = binomial_half_lower_tail(k, b + c)

      {:ok,
       Map.merge(base, %{
         p_value: min(1.0, 2 * cdf),
         mid_p_value: min(1.0, 2 * (cdf - pmf / 2))
       })}
    end
  end

  def mcnemar(_b, _c), do: {:error, :invalid_counts}

  # {P(X <= k), P(X = k)} for X ~ Binomial(n, 1/2), k <= n/2. Starts from the
  # observed term (one lgamma evaluation) and walks down with exact ratios
  # P(X = i - 1) / P(X = i) = i / (n - i + 1), stopping once terms vanish.
  defp binomial_half_lower_tail(k, n) do
    pmf_k = :math.exp(Special.log_choose(n, k) - n * :math.log(2))
    {sum_down(k, n, pmf_k, pmf_k), pmf_k}
  end

  defp sum_down(0, _n, _term, acc), do: acc

  defp sum_down(i, n, term, acc) do
    term = term * i / (n - i + 1)

    if term < acc * 1.0e-17,
      do: acc,
      else: sum_down(i - 1, n, term, acc + term)
  end

  @doc """
  Fisher's exact test, two-sided, for the 2×2 table `[[a, b], [c, d]]`.

  The p-value sums the hypergeometric probabilities of every table with the
  same margins that is no more likely than the observed one (relative
  tolerance 1e-7, as in R). `:odds_ratio` is the sample odds ratio
  `a·d / (b·c)`: `:infinity` when only `b·c` is zero, `:undefined` when both
  products are zero.

  An all-zero table gives `p_value: 1.0`.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.Hypothesis.fisher_exact(3, 0, 0, 3)
      iex> {Float.round(r.p_value, 6), r.odds_ratio}
      {0.1, :infinity}
  """
  @spec fisher_exact(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, %{p_value: float(), odds_ratio: float() | :infinity | :undefined}}
          | {:error, :invalid_counts}
  def fisher_exact(a, b, c, d)
      when is_count(a) and is_count(b) and is_count(c) and is_count(d) do
    row1 = a + b
    row2 = c + d
    col1 = a + c
    n = row1 + row2

    log_pmf = fn x ->
      Special.log_choose(row1, x) + Special.log_choose(row2, col1 - x) -
        Special.log_choose(n, col1)
    end

    cutoff = log_pmf.(a) + :math.log(1 + @fisher_rel_tol)

    p =
      max(0, col1 - row2)..min(row1, col1)//1
      |> Enum.reduce(0.0, fn x, acc ->
        lp = log_pmf.(x)
        if lp <= cutoff, do: acc + :math.exp(lp), else: acc
      end)

    {:ok, %{p_value: min(1.0, p), odds_ratio: odds_ratio(a * d, b * c)}}
  end

  def fisher_exact(_a, _b, _c, _d), do: {:error, :invalid_counts}

  defp odds_ratio(0, 0), do: :undefined
  defp odds_ratio(_ad, 0), do: :infinity
  defp odds_ratio(ad, bc), do: ad / bc

  @doc """
  Tango's score test for the paired difference `Δ = (b − c) / n` against
  `delta0`.

  The statistic is `Z(δ₀) = (b − c − n·δ₀) / √(n·(2q̃ + δ₀(1 − δ₀)))` where
  `q̃` is the maximum-likelihood estimate of the `c`-cell probability under
  `Δ = δ₀` (closed form, Tango 1998). At `δ₀ = 0` it reduces to McNemar's
  `(b − c)/√(b + c)`.

  Options:

    * `:delta0` - null difference in `(-1, 1)`, default `0.0`
    * `:alternative` - `:two_sided` (default), `:less` (H1: Δ < δ₀) or
      `:greater` (H1: Δ > δ₀)

  When `b + c == 0` and `delta0 == 0` the data say nothing about Δ; `z` is
  `0.0`. Returns `{:error, :empty}` when `n == 0`.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.Hypothesis.tango_test(9, 4, 50)
      iex> {Float.round(r.z, 6), Float.round(r.p_value, 6)}
      {1.38675, 0.165518}
  """
  @spec tango_test(non_neg_integer(), non_neg_integer(), pos_integer(), keyword()) ::
          {:ok,
           %{
             estimate: float(),
             delta0: float(),
             alternative: :two_sided | :less | :greater,
             z: float(),
             p_value: float()
           }}
          | {:error, :empty | :invalid_counts | {:invalid_option, :delta0 | :alternative}}
  def tango_test(b, c, n, opts \\ []) do
    with :ok <- check_paired(b, c, n),
         {:ok, delta0} <- delta_opt(opts, :delta0, 0.0),
         {:ok, alternative} <- alternative_opt(opts) do
      z = tango_z(b, c, n, delta0)

      p =
        case alternative do
          :two_sided -> min(1.0, :math.erfc(abs(z) / :math.sqrt(2)))
          :less -> Special.norm_cdf(z)
          :greater -> Special.norm_cdf(-z)
        end

      {:ok, %{estimate: (b - c) / n, delta0: delta0, alternative: alternative, z: z, p_value: p}}
    end
  end

  @doc """
  Tango's score confidence interval for the paired difference
  `Δ = (b − c) / n`: the set of `δ` with `|Z(δ)| ≤ z_{1−α/2}`, found by
  bisection. Unlike the Wald interval it stays inside `[-1, 1]` and behaves
  well when `b + c` is small.

  Options: `:confidence` (default `0.95`). Returns `{:error, :empty}` when
  `n == 0`.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.Hypothesis.tango_ci(0, 0, 61)
      iex> {r.estimate, r.ci |> elem(1) |> Float.round(4)}
      {0.0, 0.0592}
  """
  @spec tango_ci(non_neg_integer(), non_neg_integer(), pos_integer(), keyword()) ::
          {:ok, Nous.Eval.Stats.interval()}
          | {:error, :empty | :invalid_counts | :invalid_confidence}
  def tango_ci(b, c, n, opts \\ []) do
    with :ok <- check_paired(b, c, n),
         {:ok, conf} <- confidence(opts) do
      z = -Special.norm_quantile((1 - conf) / 2)
      {:ok, %{estimate: (b - c) / n, ci: tango_bounds(b, c, n, z)}}
    end
  end

  @doc """
  Paired non-inferiority test with margin `margin` (Tango score test).

  H0: `Δ ≥ margin` (the candidate is worse by at least the margin) against
  H1: `Δ < margin`, where `Δ = (b − c) / n` is the candidate's rate minus the
  baseline's. For a guard's false-allow rate, `b` = new misses and `c` =
  fixes on the same malicious items. The candidate passes
  (`non_inferior?: true`) only if H0 is rejected at one-sided `alpha`, which
  is the same as the upper bound of the two-sided `1 − 2α` Tango interval
  (`:ci`) lying below the margin.

  Data that are too few to ever pass simply fail; use
  `Nous.Eval.Stats.Power.noninferiority_n/4` to report the n needed.

  Options: `:alpha` (one-sided, default `0.05`).

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.Hypothesis.noninferiority(0, 0, 61, 0.05)
      iex> {r.non_inferior?, Float.round(r.z, 3)}
      {true, -1.792}

      iex> {:ok, r} = Nous.Eval.Stats.Hypothesis.noninferiority(1, 0, 61, 0.05)
      iex> {r.non_inferior?, Float.round(r.z, 3)}
      {false, -1.204}
  """
  @spec noninferiority(non_neg_integer(), non_neg_integer(), pos_integer(), number(), keyword()) ::
          {:ok,
           %{
             estimate: float(),
             margin: float(),
             alpha: float(),
             z: float(),
             p_value: float(),
             ci: Nous.Eval.Stats.ci(),
             non_inferior?: boolean()
           }}
          | {:error,
             :empty
             | :invalid_counts
             | {:invalid_option, :margin | :alpha | :delta0 | :alternative}}
  def noninferiority(b, c, n, margin, opts \\ []) do
    with {:ok, margin} <- margin_arg(margin),
         {:ok, alpha} <- probability_opt(opts, :alpha, 0.05),
         :ok <- if(alpha < 0.5, do: :ok, else: {:error, {:invalid_option, :alpha}}),
         {:ok, test} <- tango_test(b, c, n, delta0: margin, alternative: :less) do
      z = -Special.norm_quantile(alpha)

      {:ok,
       %{
         estimate: test.estimate,
         margin: margin,
         alpha: alpha,
         z: test.z,
         p_value: test.p_value,
         ci: tango_bounds(b, c, n, z),
         non_inferior?: test.p_value <= alpha
       }}
    end
  end

  defp margin_arg(m) when is_open_unit(m), do: {:ok, m / 1}
  defp margin_arg(_), do: {:error, {:invalid_option, :margin}}

  # Z(δ) for Tango's statistic; 0.0 in the degenerate b = c = 0, δ = 0 case.
  defp tango_z(b, c, n, delta) do
    num = b - c - n * delta
    var = n * tango_variance(b, c, n, delta)
    if var <= 0, do: 0.0, else: num / :math.sqrt(var)
  end

  # Per-pair variance 2q̃ + δ(1 − δ) at the restricted MLE q̃, the positive
  # root of 2n·q² + B·q + C = 0 (Tango 1998). The root is taken in the
  # cancellation-free form for each sign of B.
  defp tango_variance(b, c, n, delta) do
    a_coef = 2 * n
    b_coef = -b - c + (2 * n - b + c) * delta
    c_coef = -c * delta * (1 - delta)
    s = :math.sqrt(max(b_coef * b_coef - 4 * a_coef * c_coef, 0.0))

    q =
      cond do
        b_coef < 0 -> (s - b_coef) / (2 * a_coef)
        b_coef + s > 0 -> -2 * c_coef / (b_coef + s)
        true -> 0.0
      end

    max(2 * q + delta * (1 - delta), 0.0)
  end

  # Bounds of {δ : |Z(δ)| ≤ z}. Written as sign conditions on
  # b − c − nδ ∓ z·√(n·V(δ)) so the degenerate V = 0 points need no division.
  defp tango_bounds(b, c, n, z) do
    estimate = (b - c) / n
    upper_side = fn d -> b - c - n * d + z * :math.sqrt(n * tango_variance(b, c, n, d)) end
    lower_side = fn d -> b - c - n * d - z * :math.sqrt(n * tango_variance(b, c, n, d)) end

    lower =
      if lower_side.(-1.0) <= 0,
        do: -1.0,
        else: Special.bisect(fn d -> lower_side.(d) > 0 end, -1.0, estimate)

    upper =
      if upper_side.(1.0) >= 0,
        do: 1.0,
        else: Special.bisect(fn d -> upper_side.(d) > 0 end, estimate, 1.0)

    {lower, upper}
  end

  defp check_paired(b, c, n) when is_count(b) and is_count(c) and is_count(n) and b + c <= n do
    if n == 0, do: {:error, :empty}, else: :ok
  end

  defp check_paired(_b, _c, _n), do: {:error, :invalid_counts}

  defp delta_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      d when is_number(d) and d > -1 and d < 1 -> {:ok, d / 1}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp alternative_opt(opts) do
    case Keyword.get(opts, :alternative, :two_sided) do
      alt when alt in [:two_sided, :less, :greater] -> {:ok, alt}
      _ -> {:error, {:invalid_option, :alternative}}
    end
  end

  @doc """
  Holm step-down adjusted p-values (family-wise error control, uniformly
  more powerful than Bonferroni).

  `adjusted_(j) = min(1, max_{i ≤ j} (m − i + 1)·p_(i))` over the ascending
  order; results come back in input order. `:rejected` marks
  `adjusted <= alpha`. An empty list gives empty results.

  Options: `:alpha` (default `0.05`).

  ## Examples

      iex> Nous.Eval.Stats.Hypothesis.holm([0.01, 0.04, 0.03])
      {:ok, %{adjusted: [0.03, 0.06, 0.06], rejected: [true, false, false], alpha: 0.05}}
  """
  @spec holm([number()], keyword()) ::
          {:ok, %{adjusted: [float()], rejected: [boolean()], alpha: float()}}
          | {:error, :invalid_values | {:invalid_option, :alpha}}
  def holm(p_values, opts \\ []) do
    adjust(p_values, opts, fn sorted, m ->
      sorted
      |> Enum.with_index(1)
      |> Enum.map_reduce(0.0, fn {{p, idx}, rank}, running ->
        adj = min(1.0, max(running, (m - rank + 1) * p))
        {{idx, adj}, adj}
      end)
      |> elem(0)
    end)
  end

  @doc """
  Benjamini–Hochberg adjusted p-values (false discovery rate control), for
  exploratory breakdowns such as per-tag deltas.

  `adjusted_(j) = min_{i ≥ j} min(1, m·p_(i)/i)` over the ascending order;
  results come back in input order. `:rejected` marks `adjusted <= alpha`.

  Options: `:alpha` (default `0.05`).

  ## Examples

      iex> Nous.Eval.Stats.Hypothesis.benjamini_hochberg([0.01, 0.04, 0.03])
      {:ok, %{adjusted: [0.03, 0.04, 0.04], rejected: [true, true, true], alpha: 0.05}}
  """
  @spec benjamini_hochberg([number()], keyword()) ::
          {:ok, %{adjusted: [float()], rejected: [boolean()], alpha: float()}}
          | {:error, :invalid_values | {:invalid_option, :alpha}}
  def benjamini_hochberg(p_values, opts \\ []) do
    adjust(p_values, opts, fn sorted, m ->
      sorted
      |> Enum.with_index(1)
      |> Enum.reverse()
      |> Enum.map_reduce(1.0, fn {{p, idx}, rank}, running ->
        adj = min(running, min(1.0, m * p / rank))
        {{idx, adj}, adj}
      end)
      |> elem(0)
    end)
  end

  defp adjust(p_values, opts, step) do
    with {:ok, alpha} <- probability_opt(opts, :alpha, 0.05),
         :ok <- check_p_values(p_values) do
      m = length(p_values)

      adjusted =
        p_values
        |> Enum.with_index()
        |> Enum.sort_by(fn {p, idx} -> {p, idx} end)
        |> step.(m)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      {:ok, %{adjusted: adjusted, rejected: Enum.map(adjusted, &(&1 <= alpha)), alpha: alpha}}
    end
  end

  defp check_p_values(ps) when is_list(ps) do
    if Enum.all?(ps, &is_unit/1), do: :ok, else: {:error, :invalid_values}
  end

  defp check_p_values(_), do: {:error, :invalid_values}
end

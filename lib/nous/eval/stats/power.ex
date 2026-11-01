defmodule Nous.Eval.Stats.Power do
  @moduledoc """
  Power, sample size and minimum detectable effect (MDE) for eval
  comparisons, all from normal approximations.

    * `mde/3`, `sample_size/3`, `variance_components/2` - paired comparison
      of per-case scores with k samples per case (Miller 2024, "Adding Error
      Bars to Evals", eq. 9–10). Reporters print the MDE of a run so a
      "no significant change" is read against what the run could detect.
    * `two_proportion_power/4`, `two_proportion_n/3` - two independent
      proportions (Cohen's effect size h = 2·asin√p₁ − 2·asin√p₂).
    * `mcnemar_power/4`, `mcnemar_n/3` - paired proportions, McNemar test
      (Connor 1987, Biometrics 43:207–211).
    * `noninferiority_power/5`, `noninferiority_n/4` - the paired Tango
      non-inferiority test of `Nous.Eval.Stats.Hypothesis.noninferiority/5`
      (Nam 1997, Biometrics 53:1422–1430).

  `:alpha` is two-sided for the difference tests and one-sided for
  non-inferiority, default `0.05`; `:power` defaults to `0.8`. Sample sizes
  are the smallest integer reaching the requested power.
  """

  import Nous.Eval.Stats.Guards

  alias Nous.Eval.Stats.Special

  @doc """
  Minimum detectable effect of a paired comparison over `n` cases (Miller
  eq. 10): `δ = (z_{1−α/2} + z_{power}) · √(variance / n)`.

  `variance` is the variance of the per-case difference `d̄_i` at the
  planned k. From a finished comparison it is the sample variance of the
  per-case differences (`describe/1` on them); for planning at other k use
  `variance_components/2` and `ω² + σ_A²/k_A + σ_B²/k_B`.

  Options: `:alpha` (two-sided, default `0.05`), `:power` (default `0.8`).

  ## Examples

      # Miller's illustrative ω² = 1/9, σ² = 1/6, k = 3 ⇒ variance 2/9
      iex> {:ok, mde} = Nous.Eval.Stats.Power.mde(100, 2 / 9)
      iex> Float.round(mde, 3)
      0.132
  """
  @spec mde(pos_integer(), number(), keyword()) ::
          {:ok, float()}
          | {:error, :empty | :invalid_values | {:invalid_option, :n | :alpha | :power}}
  def mde(n, variance, opts \\ []) do
    with :ok <- check_n(n),
         :ok <- check_variance(variance),
         {:ok, za, zb} <- z_pair(opts, 2) do
      {:ok, (za + zb) * :math.sqrt(variance / n)}
    end
  end

  @doc """
  Cases needed to detect a paired difference `delta` (Miller eq. 9):
  `n = ⌈(z_{1−α/2} + z_{power})² · variance / δ²⌉`. See `mde/3` for
  `variance`.

  ## Examples

      iex> Nous.Eval.Stats.Power.sample_size(0.10, 2 / 9)
      {:ok, 175}
  """
  @spec sample_size(number(), number(), keyword()) ::
          {:ok, pos_integer()}
          | {:error, :no_effect | :invalid_values | {:invalid_option, :alpha | :power}}
  def sample_size(delta, variance, opts \\ []) do
    with :ok <- check_effect(delta),
         :ok <- check_variance(variance),
         {:ok, za, zb} <- z_pair(opts, 2) do
      {:ok, ceil_n((za + zb) ** 2 * variance / (delta * delta))}
    end
  end

  @doc """
  Estimates the variance components of a paired comparison from per-case
  sample scores, for planning `n` and k with `mde/3` / `sample_size/3`.

  `candidate` and `baseline` are lists (same case order) of per-case lists
  of sample scores; every case needs at least two samples per arm.

    * `sigma2_a`, `sigma2_b` - mean within-case sample variance per arm
      (unbiased for E[σᵢ²]; for binary scores it is `p̂(1−p̂)·k/(k−1)`)
    * `omega2` - between-case variance of the true difference,
      `Var(d̄) − σ_A²/k_A − σ_B²/k_B`, floored at 0
    * `k_a`, `k_b` - mean samples per case per arm

  The variance at other sample counts is
  `omega2 + sigma2_a / k_a' + sigma2_b / k_b'`.
  """
  @spec variance_components([[number()]], [[number()]]) ::
          {:ok,
           %{
             omega2: float(),
             sigma2_a: float(),
             sigma2_b: float(),
             k_a: float(),
             k_b: float(),
             n: pos_integer()
           }}
          | {:error, :length_mismatch | :insufficient_data | :invalid_values}
  def variance_components(candidate, baseline) do
    cond do
      not (cases?(candidate) and cases?(baseline)) ->
        {:error, :invalid_values}

      length(candidate) != length(baseline) ->
        {:error, :length_mismatch}

      length(candidate) < 2 or Enum.any?(candidate ++ baseline, &(length(&1) < 2)) ->
        {:error, :insufficient_data}

      true ->
        {sigma2_a, k_a} = within(candidate)
        {sigma2_b, k_b} = within(baseline)
        diffs = Enum.zip_with(candidate, baseline, &(mean(&1) - mean(&2)))
        {:ok, %{variance: var_d}} = Nous.Eval.Stats.describe(diffs)

        {:ok,
         %{
           omega2: max(var_d - sigma2_a / k_a - sigma2_b / k_b, 0.0),
           sigma2_a: sigma2_a,
           sigma2_b: sigma2_b,
           k_a: k_a,
           k_b: k_b,
           n: length(candidate)
         }}
    end
  end

  defp cases?(cases), do: is_list(cases) and Enum.all?(cases, &numbers?/1)

  defp within(cases) do
    n = length(cases)

    {var_sum, k_sum} =
      Enum.reduce(cases, {0.0, 0}, fn samples, {vs, ks} ->
        {:ok, %{variance: v}} = Nous.Eval.Stats.describe(samples)
        {vs + v, ks + length(samples)}
      end)

    {var_sum / n, k_sum / n}
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  @doc """
  Power of the two-sided test comparing two independent proportions with
  `n` cases per group, using Cohen's h (matches statsmodels
  `NormalIndPower` with `proportion_effectsize`).

  Options: `:alpha` (two-sided, default `0.05`).

  ## Examples

      iex> {:ok, p} = Nous.Eval.Stats.Power.two_proportion_power(0.6, 0.7, 356)
      iex> Float.round(p, 3)
      0.801
  """
  @spec two_proportion_power(number(), number(), pos_integer(), keyword()) ::
          {:ok, float()}
          | {:error, :empty | {:invalid_option, :n | :alpha | :p1 | :p2}}
  def two_proportion_power(p1, p2, n, opts \\ []) do
    with {:ok, h} <- cohen_h(p1, p2),
         :ok <- check_n(n),
         {:ok, alpha} <- probability_opt(opts, :alpha, 0.05) do
      {:ok, two_sided_power(abs(h) * :math.sqrt(n / 2), alpha)}
    end
  end

  @doc """
  Cases per group for `two_proportion_power/4` to reach `:power`
  (default `0.8`).

  ## Examples

      iex> Nous.Eval.Stats.Power.two_proportion_n(0.6, 0.7)
      {:ok, 356}
  """
  @spec two_proportion_n(number(), number(), keyword()) ::
          {:ok, pos_integer()}
          | {:error, :no_effect | {:invalid_option, :alpha | :power | :p1 | :p2}}
  def two_proportion_n(p1, p2, opts \\ []) do
    with {:ok, h} <- cohen_h(p1, p2),
         :ok <- check_effect(h),
         {:ok, alpha} <- probability_opt(opts, :alpha, 0.05),
         {:ok, power} <- probability_opt(opts, :power, 0.8) do
      za = -Special.norm_quantile(alpha / 2)
      zb = Special.norm_quantile(power)
      # The closed form ignores the far rejection tail, so it never
      # undershoots; step down while the exact power still suffices.
      start = ceil_n(2 * ((za + zb) / h) ** 2)
      {:ok, smallest_n(start, &(two_sided_power(abs(h) * :math.sqrt(&1 / 2), alpha) >= power))}
    end
  end

  defp cohen_h(p1, p2) do
    cond do
      not is_unit(p1) -> {:error, {:invalid_option, :p1}}
      not is_unit(p2) -> {:error, {:invalid_option, :p2}}
      true -> {:ok, 2 * :math.asin(:math.sqrt(p1)) - 2 * :math.asin(:math.sqrt(p2))}
    end
  end

  defp two_sided_power(shift, alpha) do
    z = -Special.norm_quantile(alpha / 2)
    Special.norm_cdf(shift - z) + Special.norm_cdf(-shift - z)
  end

  @doc """
  Power of the two-sided McNemar test over `n` pairs (Connor 1987), where
  `p_b` and `p_c` are the probabilities of the two discordant outcomes (see
  `Nous.Eval.Stats.Hypothesis` for the orientation):

  `Φ((|p_b − p_c|·√n − z_{1−α/2}·√ψ) / √(ψ − (p_b − p_c)²))`, `ψ = p_b + p_c`.

  With no discordance at all (`ψ == 0`) nothing can be detected and the
  power is `0.0`; if `ψ == (p_b − p_c)²` (every pair discordant one way) the
  outcome is deterministic and the power is `0.0` or `1.0`.

  Options: `:alpha` (two-sided, default `0.05`).

  ## Examples

      iex> {:ok, p} = Nous.Eval.Stats.Power.mcnemar_power(0.15, 0.05, 150)
      iex> Float.round(p, 3)
      0.788
  """
  @spec mcnemar_power(number(), number(), pos_integer(), keyword()) ::
          {:ok, float()}
          | {:error, :empty | {:invalid_option, :n | :alpha | :p_b | :p_c}}
  def mcnemar_power(p_b, p_c, n, opts \\ []) do
    with :ok <- check_discordant(p_b, p_c),
         :ok <- check_n(n),
         {:ok, alpha} <- probability_opt(opts, :alpha, 0.05) do
      {:ok, connor_power(p_b, p_c, n, -Special.norm_quantile(alpha / 2))}
    end
  end

  @doc """
  Pairs needed for `mcnemar_power/4` to reach `:power` (Connor 1987):
  `n = ⌈(z_{1−α/2}·√ψ + z_{power}·√(ψ − δ²))² / δ²⌉` with `δ = p_b − p_c`.

  ## Examples

      iex> Nous.Eval.Stats.Power.mcnemar_n(0.15, 0.05)
      {:ok, 155}
  """
  @spec mcnemar_n(number(), number(), keyword()) ::
          {:ok, pos_integer()}
          | {:error, :no_effect | {:invalid_option, :alpha | :power | :p_b | :p_c}}
  def mcnemar_n(p_b, p_c, opts \\ []) do
    with :ok <- check_discordant(p_b, p_c),
         :ok <- check_effect(p_b - p_c),
         {:ok, za, zb} <- z_pair(opts, 2) do
      psi = p_b + p_c
      delta = p_b - p_c

      {:ok,
       ceil_n(
         (za * :math.sqrt(psi) + zb * :math.sqrt(max(psi - delta * delta, 0.0))) ** 2 /
           (delta * delta)
       )}
    end
  end

  defp connor_power(p_b, p_c, n, za) do
    psi = p_b + p_c
    delta = abs(p_b - p_c)
    spread = psi - delta * delta
    num = delta * :math.sqrt(n) - za * :math.sqrt(psi)

    cond do
      psi == 0 -> 0.0
      spread <= 0 -> step(num)
      true -> Special.norm_cdf(num / :math.sqrt(spread))
    end
  end

  defp check_discordant(p_b, p_c) do
    cond do
      not is_unit(p_b) -> {:error, {:invalid_option, :p_b}}
      not is_unit(p_c) -> {:error, {:invalid_option, :p_c}}
      p_b + p_c > 1 -> {:error, {:invalid_option, :p_c}}
      true -> :ok
    end
  end

  @doc """
  Power of the paired non-inferiority test
  (`Nous.Eval.Stats.Hypothesis.noninferiority/5`) over `n` pairs, for true
  discordant probabilities `p_b` (candidate has the event, baseline not) and
  `p_c` (the reverse), so the true difference is `δ = p_b − p_c`:

  `Φ((√n·(M − δ) − z_{1−α}·w̃) / w)` with `w² = p_b + p_c − δ²` and `w̃²`
  the variance at the restricted estimate under `Δ = M` (Nam 1997).

  Requires `δ < margin`. With no discordance (`w == 0`) the outcome is
  deterministic: `1.0` once n is large enough, else `0.0`.

  Options: `:alpha` (one-sided, default `0.05`).
  """
  @spec noninferiority_power(number(), number(), number(), pos_integer(), keyword()) ::
          {:ok, float()}
          | {:error,
             :empty
             | :effect_not_below_margin
             | {:invalid_option, :n | :alpha | :margin | :p_b | :p_c}}
  def noninferiority_power(p_b, p_c, margin, n, opts \\ []) do
    with :ok <- check_discordant(p_b, p_c),
         :ok <- check_margin(margin, p_b - p_c),
         :ok <- check_n(n),
         {:ok, alpha} <- probability_opt(opts, :alpha, 0.05) do
      {w_null, w} = ni_spreads(p_b, p_c, margin)
      num = :math.sqrt(n) * (margin - (p_b - p_c)) + Special.norm_quantile(alpha) * w_null
      {:ok, if(w == 0, do: step(num), else: Special.norm_cdf(num / w))}
    end
  end

  @doc """
  Pairs needed for the paired non-inferiority test to reach `:power`:
  `n = ⌈((z_{1−α}·w̃ + z_{power}·w) / (M − δ))²⌉` (see
  `noninferiority_power/5`).

  With identical behaviour (`p_b = p_c = 0`) this is the smallest n that can
  certify the margin at all, `z²(1 − M)/M`: 52 at M = 0.05, 133 at 0.02 and
  268 at 0.01 (α = 0.05). A guard dataset smaller than that "cannot
  certify; n ≥ X needed" and must fail closed.

  Options: `:alpha` (one-sided, default `0.05`), `:power` (default `0.8`).

  ## Examples

      iex> Nous.Eval.Stats.Power.noninferiority_n(0.0, 0.0, 0.02)
      {:ok, 133}
  """
  @spec noninferiority_n(number(), number(), number(), keyword()) ::
          {:ok, pos_integer()}
          | {:error,
             :effect_not_below_margin | {:invalid_option, :alpha | :power | :margin | :p_b | :p_c}}
  def noninferiority_n(p_b, p_c, margin, opts \\ []) do
    with :ok <- check_discordant(p_b, p_c),
         :ok <- check_margin(margin, p_b - p_c),
         {:ok, za, zb} <- z_pair(opts, 1) do
      {w_null, w} = ni_spreads(p_b, p_c, margin)
      {:ok, ceil_n(((za * w_null + zb * w) / (margin - (p_b - p_c))) ** 2)}
    end
  end

  # {w̃, w}: standard deviations per pair under H0 (Δ = M, restricted
  # estimate at the expected cell probabilities) and under the truth.
  defp ni_spreads(p_b, p_c, margin) do
    b_coef = -(p_b + p_c) + (2 - p_b + p_c) * margin
    c_coef = -p_c * margin * (1 - margin)
    s = :math.sqrt(max(b_coef * b_coef - 8 * c_coef, 0.0))

    q =
      cond do
        b_coef < 0 -> (s - b_coef) / 4
        b_coef + s > 0 -> -2 * c_coef / (b_coef + s)
        true -> 0.0
      end

    delta = p_b - p_c
    w_null = :math.sqrt(max(2 * q + margin * (1 - margin), 0.0))
    {w_null, :math.sqrt(max(p_b + p_c - delta * delta, 0.0))}
  end

  defp check_margin(margin, delta) do
    cond do
      not is_open_unit(margin) -> {:error, {:invalid_option, :margin}}
      delta >= margin -> {:error, :effect_not_below_margin}
      true -> :ok
    end
  end

  # ── Shared helpers ──────────────────────────────────────────────────────

  # {z_{1-α/sides}, z_{power}}
  defp z_pair(opts, sides) do
    with {:ok, alpha} <- probability_opt(opts, :alpha, 0.05),
         {:ok, power} <- probability_opt(opts, :power, 0.8) do
      {:ok, -Special.norm_quantile(alpha / sides), Special.norm_quantile(power)}
    end
  end

  defp check_n(0), do: {:error, :empty}
  defp check_n(n) when is_integer(n) and n > 0, do: :ok
  defp check_n(_n), do: {:error, {:invalid_option, :n}}

  defp check_variance(v) when is_number(v) and v >= 0, do: :ok
  defp check_variance(_v), do: {:error, :invalid_values}

  defp check_effect(delta) when is_number(delta) and delta != 0, do: :ok
  defp check_effect(_delta), do: {:error, :no_effect}

  defp step(num) when num > 0, do: 1.0
  defp step(num) when num < 0, do: 0.0
  defp step(_num), do: 0.5

  # Guards against a float like 52.00000000000001 for an exact integer.
  defp ceil_n(x), do: max(1, ceil(x - 1.0e-9))

  defp smallest_n(n, ok?) do
    if n > 1 and ok?.(n - 1), do: smallest_n(n - 1, ok?), else: n
  end
end

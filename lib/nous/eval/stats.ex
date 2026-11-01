defmodule Nous.Eval.Stats do
  @moduledoc """
  Statistics for evaluation runs, hand-rolled in pure Elixir (no Nx, no NIFs).

  This module holds descriptive statistics, standard errors, proportion
  intervals, the pass@k / pass^k estimators and inter-rater agreement
  (Cohen's κ, unweighted and weighted). The rest lives in submodules:

    * `Nous.Eval.Stats.Hypothesis` - exact McNemar (+ mid-P), Fisher exact,
      Tango's paired score test and interval, the paired non-inferiority
      gate, Holm and Benjamini–Hochberg adjustment
    * `Nous.Eval.Stats.Bootstrap` - seeded paired cluster bootstrap
    * `Nous.Eval.Stats.Power` - power, sample size and minimum detectable
      effect
    * `Nous.Eval.Stats.Classifier` - confusion counts, precision/recall/FPR,
      ROC-AUC, PR curve and average precision, threshold selection
    * `Nous.Eval.Stats.Special` - `lgamma`, incomplete beta, normal and t
      distributions (the numeric primitives)

  ## Conventions

    * Every data-facing function returns `{:ok, result}` or
      `{:error, reason}`. They never raise on empty or degenerate data and
      never return NaN or infinities; undefined quantities are `nil` and are
      documented per function.
    * Interval results are maps with `:estimate` and `:ci` (`{lower, upper}`).
    * `:confidence` options are two-sided levels in `(0, 1)`, default `0.95`.
    * The unit of analysis is the **case**. With k samples per case, reduce
      each case to its mean first (or use `clustered_se/1` with one cluster
      per case); pooling all samples as independent understates the error
      (Miller 2024, "Adding Error Bars to Evals", §3.1).

  ## Which interval for what

  | Quantity | n ≥ ~100 cases | n < ~100 cases |
  |---|---|---|
  | Single proportion (pass rate, FPR, recall) | `wilson/3` | `wilson/3`; `jeffreys/3` or `beta_posterior/3` as options |
  | Mean of fractional per-case scores | `mean_ci/2` | `Nous.Eval.Stats.Bootstrap.paired_cluster/2`, flagged "small n" |
  | Paired Δ, binary per case | `Nous.Eval.Stats.Hypothesis.mcnemar/2`, `Nous.Eval.Stats.Hypothesis.tango_ci/4` | same |
  | Paired Δ, fractional per case | `paired_se/2` or the paired cluster bootstrap | `Nous.Eval.Stats.Bootstrap.paired_cluster/2`, flagged "small n" |

  Intervals based on the normal approximation (and percentile bootstrap)
  undercover below a few hundred cases (Bowyer et al. 2025); Wilson and the
  Beta intervals keep nominal coverage for single proportions.
  """

  import Nous.Eval.Stats.Guards

  alias Nous.Eval.Stats.Special

  @typedoc "A two-sided interval `{lower, upper}`."
  @type ci :: {float(), float()}

  @typedoc "An interval estimate."
  @type interval :: %{estimate: float(), ci: ci()}

  @typedoc "Reasons returned by the validating functions of `Nous.Eval.Stats.*`."
  @type reason ::
          :empty
          | :insufficient_data
          | :insufficient_clusters
          | :length_mismatch
          | :invalid_values
          | :invalid_counts
          | :invalid_confidence
          | :invalid_k
          | :k_exceeds_n
          | {:invalid_option, atom()}

  @type error :: {:error, reason()}

  # ── Descriptives ────────────────────────────────────────────────────────

  @doc """
  Mean, sample variance, standard deviation and standard error of the mean,
  computed in one pass with Welford's algorithm.

  `:variance`, `:sd` and `:se` use the `n - 1` denominator and are `nil` when
  `n == 1`. Returns `{:error, :empty}` for `[]` and `{:error, :invalid_values}`
  if any element is not a number.

  ## Examples

      iex> Nous.Eval.Stats.describe([1, 2, 3, 4])
      {:ok, %{n: 4, mean: 2.5, variance: 1.6666666666666667, sd: 1.2909944487358056, se: 0.6454972243679028}}

      iex> Nous.Eval.Stats.describe([0.5])
      {:ok, %{n: 1, mean: 0.5, variance: nil, sd: nil, se: nil}}
  """
  @spec describe([number()]) ::
          {:ok,
           %{
             n: pos_integer(),
             mean: float(),
             variance: float() | nil,
             sd: float() | nil,
             se: float() | nil
           }}
          | {:error, :empty | :invalid_values}
  def describe([]), do: {:error, :empty}

  def describe(values) do
    if numbers?(values) do
      {n, mean, m2} = welford(values)

      if n == 1 do
        {:ok, %{n: 1, mean: mean, variance: nil, sd: nil, se: nil}}
      else
        variance = m2 / (n - 1)
        sd = :math.sqrt(variance)
        {:ok, %{n: n, mean: mean, variance: variance, sd: sd, se: sd / :math.sqrt(n)}}
      end
    else
      {:error, :invalid_values}
    end
  end

  defp welford(values) do
    Enum.reduce(values, {0, 0.0, 0.0}, fn x, {n, mean, m2} ->
      n = n + 1
      delta = x - mean
      mean = mean + delta / n
      {n, mean, m2 + delta * (x - mean)}
    end)
  end

  @doc """
  Student-t confidence interval for the mean of per-case values (Inspect's
  `ci()` style), with `n - 1` degrees of freedom.

  Needs at least two values (`{:error, :insufficient_data}` otherwise).
  Constant data gives a zero-width interval.

  Options: `:confidence` (default `0.95`).

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.mean_ci([0.2, 0.4, 0.6, 0.8])
      iex> {Float.round(r.estimate, 6), r.df, Tuple.to_list(r.ci) |> Enum.map(&Float.round(&1, 6))}
      {0.5, 3, [0.089148, 0.910852]}
  """
  @spec mean_ci([number()], keyword()) ::
          {:ok, %{estimate: float(), se: float(), df: pos_integer(), ci: ci()}}
          | {:error, :empty | :insufficient_data | :invalid_values | :invalid_confidence}
  def mean_ci(values, opts \\ []) do
    with {:ok, conf} <- confidence(opts),
         {:ok, %{n: n, mean: mean, se: se}} <- describe(values),
         :ok <- at_least(n, 2) do
      t = Special.t_quantile(1 - (1 - conf) / 2, n - 1)
      {:ok, %{estimate: mean, se: se, df: n - 1, ci: {mean - t * se, mean + t * se}}}
    end
  end

  @doc """
  Sample quantile at probability `p` (`0 <= p <= 1`), linear interpolation
  between order statistics (Hyndman–Fan type 7; R and NumPy default).

  ## Examples

      iex> Nous.Eval.Stats.quantile([4, 1, 3, 2], 0.5)
      {:ok, 2.5}
  """
  @spec quantile([number()], number()) ::
          {:ok, float()} | {:error, :empty | :invalid_values | {:invalid_option, :p}}
  def quantile(values, p) do
    with {:ok, [q]} <- quantiles(values, [p]), do: {:ok, q}
  end

  @doc """
  Several type-7 quantiles of one list (sorts once). See `quantile/2`.
  """
  @spec quantiles([number()], [number()]) ::
          {:ok, [float()]} | {:error, :empty | :invalid_values | {:invalid_option, :p}}
  def quantiles([], _ps), do: {:error, :empty}

  def quantiles(values, ps) do
    cond do
      not numbers?(values) -> {:error, :invalid_values}
      not (is_list(ps) and Enum.all?(ps, &is_unit/1)) -> {:error, {:invalid_option, :p}}
      true -> {:ok, sorted_quantiles(values, ps)}
    end
  end

  defp sorted_quantiles(values, ps) do
    sorted = values |> Enum.sort() |> List.to_tuple()
    Enum.map(ps, &Special.tuple_quantile(sorted, &1))
  end

  @doc """
  Mean and cluster-robust standard error of the mean of all observations,
  where each inner list is one cluster.

  Use one cluster per case with its k sample scores ("cluster = case,
  samples = k"), or one cluster per scenario/template with per-case means.
  For a paired, clustered comparison pass the per-case differences grouped by
  cluster (Miller eq. 8).

  The variance is the CR1 sandwich estimator of an intercept-only model,
  `G/(G-1) · Σ_c (Σ_i (s_ic − s̄))² / N²` (what statsmodels'
  `cov_type="cluster"` computes). With singleton clusters it equals the
  ordinary standard error; with equal-size clusters it equals the standard
  error of the cluster means, so the case stays the unit of analysis.

  Needs at least two non-empty clusters (`{:error, :insufficient_clusters}`).
  Empty inner lists are ignored.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.clustered_se([[1, 1, 0], [0, 0, 0], [1, 1, 1]])
      iex> {r.n, r.clusters, Float.round(r.mean, 6), Float.round(r.se, 6)}
      {9, 3, 0.555556, 0.293972}
  """
  @spec clustered_se([[number()]]) ::
          {:ok, %{mean: float(), se: float(), n: pos_integer(), clusters: pos_integer()}}
          | {:error, :insufficient_clusters | :invalid_values}
  def clustered_se(clusters) when is_list(clusters) do
    if Enum.all?(clusters, &numbers?/1) do
      clusters = Enum.reject(clusters, &(&1 == []))
      g = length(clusters)
      n = Enum.reduce(clusters, 0, &(length(&1) + &2))

      if g < 2 do
        {:error, :insufficient_clusters}
      else
        mean = Enum.reduce(clusters, 0.0, &(Enum.sum(&1) + &2)) / n

        meat =
          Enum.reduce(clusters, 0.0, fn cluster, acc ->
            dev = Enum.reduce(cluster, 0.0, &(&1 - mean + &2))
            acc + dev * dev
          end)

        se = :math.sqrt(g / (g - 1) * meat / (n * n))
        {:ok, %{mean: mean, se: se, n: n, clusters: g}}
      end
    else
      {:error, :invalid_values}
    end
  end

  def clustered_se(_), do: {:error, :invalid_values}

  @doc """
  Paired difference of per-case values (Miller eq. 7): `d_i = candidate_i -
  baseline_i`, mean difference and `SE = sd(d) / √n`.

  Both lists hold one value per case in the same case order. `:correlation`
  is the Pearson correlation between the two runs (Miller reports it next to
  Δ); it is `nil` when either run is constant.

  Needs at least two cases.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.paired_se([0.9, 0.8, 0.7, 1.0], [0.8, 0.8, 0.5, 0.9])
      iex> {r.n, Float.round(r.mean_difference, 6), Float.round(r.se, 6)}
      {4, 0.1, 0.040825}
  """
  @spec paired_se([number()], [number()]) ::
          {:ok,
           %{
             n: pos_integer(),
             mean_difference: float(),
             se: float(),
             correlation: float() | nil
           }}
          | {:error, :length_mismatch | :insufficient_data | :invalid_values | :empty}
  def paired_se(candidate, baseline) do
    cond do
      not (numbers?(candidate) and numbers?(baseline)) ->
        {:error, :invalid_values}

      length(candidate) != length(baseline) ->
        {:error, :length_mismatch}

      length(candidate) < 2 ->
        {:error, :insufficient_data}

      true ->
        diffs = Enum.zip_with(candidate, baseline, &(&1 - &2))
        {:ok, %{n: n, mean: mean, se: se}} = describe(diffs)

        {:ok,
         %{n: n, mean_difference: mean, se: se, correlation: correlation(candidate, baseline)}}
    end
  end

  defp correlation(xs, ys) do
    n = length(xs)
    mx = Enum.sum(xs) / n
    my = Enum.sum(ys) / n

    {sxy, sxx, syy} =
      Enum.zip_reduce(xs, ys, {0.0, 0.0, 0.0}, fn x, y, {sxy, sxx, syy} ->
        dx = x - mx
        dy = y - my
        {sxy + dx * dy, sxx + dx * dx, syy + dy * dy}
      end)

    if sxx == 0 or syy == 0, do: nil, else: clamp(sxy / :math.sqrt(sxx * syy), -1.0, 1.0)
  end

  # ── Proportion intervals ────────────────────────────────────────────────

  @doc """
  Wilson score interval for `successes` out of `n` trials.

  The recommended default for single proportions at any n. Returns
  `{:error, :empty}` when `n == 0`. Bounds are clamped to `[0, 1]`.

  Options: `:confidence` (default `0.95`).

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.wilson(33, 41)
      iex> Tuple.to_list(r.ci) |> Enum.map(&Float.round(&1, 3))
      [0.66, 0.898]
  """
  @spec wilson(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, interval()} | {:error, :empty | :invalid_counts | :invalid_confidence}
  def wilson(successes, n, opts \\ []) do
    with :ok <- check_proportion(successes, n),
         {:ok, conf} <- confidence(opts) do
      z = -Special.norm_quantile((1 - conf) / 2)
      p = successes / n
      z2 = z * z
      denom = 1 + z2 / n
      center = (p + z2 / (2 * n)) / denom
      half = z * :math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denom
      {:ok, %{estimate: p, ci: {clamp(center - half, 0.0, 1.0), clamp(center + half, 0.0, 1.0)}}}
    end
  end

  @doc """
  Clopper–Pearson ("exact") interval from Beta quantiles. Conservative:
  coverage is at least nominal. The lower bound is `0.0` when
  `successes == 0` and the upper bound is `1.0` when `successes == n`.

  For a one-sided upper bound at level `1 - α` (e.g. "0 false positives in
  n benign items"), ask for the two-sided `confidence: 1 - 2α` and read the
  upper bound.

  Returns `{:error, :empty}` when `n == 0`. Options: `:confidence`.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.clopper_pearson(0, 100, confidence: 0.90)
      iex> r.ci |> elem(1) |> Float.round(4)
      0.0295
  """
  @spec clopper_pearson(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, interval()} | {:error, :empty | :invalid_counts | :invalid_confidence}
  def clopper_pearson(successes, n, opts \\ []) do
    with :ok <- check_proportion(successes, n),
         {:ok, conf} <- confidence(opts) do
      tail = (1 - conf) / 2

      lower =
        if successes == 0,
          do: 0.0,
          else: Special.beta_quantile(tail, successes, n - successes + 1)

      upper =
        if successes == n,
          do: 1.0,
          else: Special.beta_quantile(1 - tail, successes + 1, n - successes)

      {:ok, %{estimate: successes / n, ci: {lower, upper}}}
    end
  end

  @doc """
  Jeffreys interval: equal-tailed quantiles of `Beta(successes + ½,
  n − successes + ½)`. Close to nominal coverage with shorter intervals than
  Clopper–Pearson.

  Returns `{:error, :empty}` when `n == 0`. Options: `:confidence`.

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.jeffreys(5, 10)
      iex> Tuple.to_list(r.ci) |> Enum.map(&Float.round(&1, 4))
      [0.2235, 0.7765]
  """
  @spec jeffreys(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, interval()} | {:error, :empty | :invalid_counts | :invalid_confidence}
  def jeffreys(successes, n, opts \\ []) do
    with :ok <- check_proportion(successes, n),
         {:ok, conf} <- confidence(opts) do
      {:ok,
       %{
         estimate: successes / n,
         ci: beta_interval(successes + 0.5, n - successes + 0.5, conf)
       }}
    end
  end

  @doc """
  Beta-Bernoulli posterior for a pass rate: `Beta(a₀ + successes,
  b₀ + n − successes)`, its mean (`:estimate`) and equal-tailed credible
  interval (`:ci`). The default prior `{1, 1}` is uniform (Bowyer et al.
  2025, eq. 7).

  `n == 0` is allowed and returns the prior.

  Options: `:confidence` (credible mass, default `0.95`), `:prior`
  (`{a₀, b₀}`, both `> 0`, default `{1, 1}`).

  ## Examples

      iex> {:ok, r} = Nous.Eval.Stats.beta_posterior(8, 10)
      iex> {r.posterior, Float.round(r.estimate, 4)}
      {{9, 3}, 0.75}
  """
  @spec beta_posterior(non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, %{estimate: float(), ci: ci(), posterior: {number(), number()}}}
          | {:error, :invalid_counts | :invalid_confidence | {:invalid_option, :prior}}
  def beta_posterior(successes, n, opts \\ []) do
    with :ok <- check_counts(successes, n),
         {:ok, conf} <- confidence(opts),
         {:ok, {a0, b0}} <- prior(opts) do
      a = a0 + successes
      b = b0 + n - successes
      {:ok, %{estimate: a / (a + b), ci: beta_interval(a, b, conf), posterior: {a, b}}}
    end
  end

  defp prior(opts) do
    case Keyword.get(opts, :prior, {1, 1}) do
      {a, b} when is_number(a) and is_number(b) and a > 0 and b > 0 -> {:ok, {a, b}}
      _ -> {:error, {:invalid_option, :prior}}
    end
  end

  defp beta_interval(a, b, conf) do
    tail = (1 - conf) / 2
    {Special.beta_quantile(tail, a, b), Special.beta_quantile(1 - tail, a, b)}
  end

  # ── pass@k / pass^k ─────────────────────────────────────────────────────

  @doc """
  Unbiased pass@k for one case with `n` samples of which `c` passed: the
  probability that at least one of `k` samples drawn without replacement
  passes, `1 − C(n−c, k) / C(n, k)` (Chen et al. 2021, "Evaluating Large
  Language Models Trained on Code", eq. 1).

  Uses the numerically stable product `1 − Π_{i=n−c+1}^{n} (1 − k/i)`, so no
  binomial coefficients are formed. The plug-in `1 − (1 − c/n)^k` is biased
  and is not used.

  Requires `1 <= k <= n` and `0 <= c <= n` (`{:error, :k_exceeds_n}`,
  `{:error, :invalid_k}`, `{:error, :invalid_counts}`).

  ## Examples

      iex> Nous.Eval.Stats.pass_at_k(10, 3, 1)
      {:ok, 0.30000000000000004}

      iex> Nous.Eval.Stats.pass_at_k(5, 3, 3)
      {:ok, 1.0}
  """
  @spec pass_at_k(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, float()} | {:error, :invalid_counts | :invalid_k | :k_exceeds_n}
  def pass_at_k(n, c, k) do
    with :ok <- check_pass_k(n, c, k) do
      if n - c < k do
        {:ok, 1.0}
      else
        {:ok, 1.0 - Enum.reduce((n - c + 1)..n//1, 1.0, fn i, acc -> acc * (1.0 - k / i) end)}
      end
    end
  end

  @doc """
  Unbiased pass^k for one case (τ-bench, Yao et al. 2024, §3): the
  probability that all `k` samples drawn without replacement pass,
  `C(c, k) / C(n, k) = Π_{i=0}^{k−1} (c − i)/(n − i)`. Measures reliability,
  where pass@k measures capability; `pass^1 == pass@1 == c/n`.

  Same argument rules as `pass_at_k/3`.

  ## Examples

      iex> Nous.Eval.Stats.pass_hat_k(4, 3, 2)
      {:ok, 0.5}

      iex> Nous.Eval.Stats.pass_hat_k(4, 1, 2)
      {:ok, 0.0}
  """
  @spec pass_hat_k(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, float()} | {:error, :invalid_counts | :invalid_k | :k_exceeds_n}
  def pass_hat_k(n, c, k) do
    with :ok <- check_pass_k(n, c, k) do
      if c < k do
        {:ok, 0.0}
      else
        {:ok, Enum.reduce(0..(k - 1)//1, 1.0, fn i, acc -> acc * (c - i) / (n - i) end)}
      end
    end
  end

  defp check_pass_k(n, c, k) do
    cond do
      not (is_count(n) and is_count(c) and c <= n) -> {:error, :invalid_counts}
      not (is_integer(k) and k >= 1) -> {:error, :invalid_k}
      k > n -> {:error, :k_exceeds_n}
      true -> :ok
    end
  end

  # ── Inter-rater agreement ───────────────────────────────────────────────

  @doc """
  Cohen's κ for two raters labelling the same items (e.g. a human and an LLM
  judge). `pairs` is a list of `{label_a, label_b}`, one per item; labels are
  any terms.

  `κ = 1 − Σ w·O / Σ w·E`, where `O` is the observed confusion matrix, `E` the
  matrix expected by chance from the two raters' label frequencies, and `w`
  the disagreement weight of each cell. Matches scikit-learn's
  `cohen_kappa_score`.

  ## Options

    * `:labels` - the label set, in order (default: every label seen,
      sorted). A pair with a label outside it is `{:error, :invalid_values}`.
      For weighted κ the position in this list is the label's rank
    * `:weights` - `nil` (default, unweighted: every disagreement weighs 1),
      `:linear` (`|i − j|`) or `:quadratic` (`(i − j)²`). Weighted κ needs
      an explicit `:labels` order (`{:error, {:invalid_option, :labels}}`
      otherwise); see `weighted_kappa/3`

  Returns `{:ok, nil}` when κ is undefined: the chance disagreement `Σ w·E`
  is zero, as when both raters give every item the same single label
  (scikit-learn returns NaN). `{:error, :empty}` for no pairs,
  `{:error, :invalid_values}` for an element that is not a 2-tuple.

  ## Examples

      iex> {:ok, k} = Nous.Eval.Stats.cohen_kappa([{"pass", "pass"}, {"pass", "fail"}, {"fail", "fail"}, {"fail", "fail"}])
      iex> Float.round(k, 4)
      0.5
  """
  @spec cohen_kappa([{term(), term()}], keyword()) ::
          {:ok, float() | nil}
          | {:error, :empty | :invalid_values | {:invalid_option, :labels | :weights}}
  def cohen_kappa(pairs, opts \\ [])

  def cohen_kappa([], _opts), do: {:error, :empty}

  def cohen_kappa(pairs, opts) when is_list(pairs) and is_list(opts) do
    with :ok <- check_pairs(pairs),
         {:ok, weights} <- kappa_weights(Keyword.get(opts, :weights)),
         {:ok, labels} <- kappa_labels(pairs, Keyword.get(opts, :labels), weights),
         {:ok, counts} <- kappa_counts(pairs, labels) do
      {:ok, kappa(counts, length(labels), length(pairs), weights)}
    end
  end

  def cohen_kappa(_pairs, _opts), do: {:error, :invalid_values}

  @doc """
  Weighted Cohen's κ for ordinal labels (e.g. a 1–5 Likert scale), with the
  labels' order given by `labels`. `:weights` is `:quadratic` (default) or
  `:linear`. Same results and errors as `cohen_kappa/2`.

  ## Examples

      iex> {:ok, k} = Nous.Eval.Stats.weighted_kappa([{1, 1}, {2, 3}, {3, 3}, {4, 5}, {5, 5}], [1, 2, 3, 4, 5])
      iex> Float.round(k, 4)
      0.9091
  """
  @spec weighted_kappa([{term(), term()}], [term()], keyword()) ::
          {:ok, float() | nil}
          | {:error, :empty | :invalid_values | {:invalid_option, :labels | :weights}}
  def weighted_kappa(pairs, labels, opts \\ []) when is_list(opts) do
    weights = Keyword.get(opts, :weights, :quadratic)

    if weights in [:linear, :quadratic],
      do: cohen_kappa(pairs, labels: labels, weights: weights),
      else: {:error, {:invalid_option, :weights}}
  end

  defp check_pairs(pairs) do
    if Enum.all?(pairs, &match?({_, _}, &1)), do: :ok, else: {:error, :invalid_values}
  end

  defp kappa_weights(weights) when weights in [nil, :linear, :quadratic], do: {:ok, weights}
  defp kappa_weights(_weights), do: {:error, {:invalid_option, :weights}}

  defp kappa_labels(pairs, nil, nil) do
    {:ok, pairs |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.uniq() |> Enum.sort()}
  end

  defp kappa_labels(_pairs, [_ | _] = labels, _weights) do
    if length(Enum.uniq(labels)) == length(labels),
      do: {:ok, labels},
      else: {:error, {:invalid_option, :labels}}
  end

  defp kappa_labels(_pairs, _labels, _weights), do: {:error, {:invalid_option, :labels}}

  # Confusion counts keyed by `{row, column}` label index.
  defp kappa_counts(pairs, labels) do
    index = labels |> Enum.with_index() |> Map.new()

    Enum.reduce_while(pairs, {:ok, %{}}, fn {a, b}, {:ok, counts} ->
      case {Map.fetch(index, a), Map.fetch(index, b)} do
        {{:ok, i}, {:ok, j}} -> {:cont, {:ok, Map.update(counts, {i, j}, 1, &(&1 + 1))}}
        _ -> {:halt, {:error, :invalid_values}}
      end
    end)
  end

  defp kappa(counts, k, n, weights) do
    rows = Enum.reduce(counts, %{}, fn {{i, _j}, c}, acc -> Map.update(acc, i, c, &(&1 + c)) end)
    cols = Enum.reduce(counts, %{}, fn {{_i, j}, c}, acc -> Map.update(acc, j, c, &(&1 + c)) end)

    observed =
      Enum.reduce(counts, 0.0, fn {{i, j}, c}, acc -> acc + c * weight(i, j, weights) end)

    expected =
      for i <- 0..(k - 1)//1, j <- 0..(k - 1)//1, reduce: 0.0 do
        acc -> acc + Map.get(rows, i, 0) * Map.get(cols, j, 0) / n * weight(i, j, weights)
      end

    if expected == 0.0, do: nil, else: 1.0 - observed / expected
  end

  defp weight(i, i, _weights), do: 0
  defp weight(_i, _j, nil), do: 1
  defp weight(i, j, :linear), do: abs(i - j)
  defp weight(i, j, :quadratic), do: (i - j) * (i - j)

  # ── Shared helpers ──────────────────────────────────────────────────────

  defp check_counts(x, n) when is_count(x) and is_count(n) and x <= n, do: :ok
  defp check_counts(_x, _n), do: {:error, :invalid_counts}

  defp check_proportion(x, n) do
    with :ok <- check_counts(x, n) do
      if n == 0, do: {:error, :empty}, else: :ok
    end
  end

  defp at_least(n, min) when n >= min, do: :ok
  defp at_least(_n, _min), do: {:error, :insufficient_data}

  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)
end

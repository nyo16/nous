defmodule Nous.Eval.Compare do
  @moduledoc ~S"""
  Compares a candidate eval run against a baseline run of the same dataset
  and decides whether the candidate regressed.

      {:ok, comparison} = Nous.Eval.Compare.compare(baseline, candidate)
      comparison.verdict
      #=> :pass | :regression | :error

  The result is a `%Nous.Eval.Compare{}` (atom keys, atoms for verdicts and
  labels); `to_map/1` turns it into JSON-native data for storage and
  `Nous.Eval.Reporter`.

  ## Matching cases

  Cases are matched by id. Runs of different datasets (`:dataset_hash`)
  are refused with `{:error, {:dataset_changed, %{baseline: hash,
  candidate: hash}}}` unless `allow_dataset_change: true`. Either way only
  the ids present in both runs are compared; ids only in the candidate are
  listed as `added`, ids only in the baseline as `removed`. A matched case
  is *comparable* when it has at least one scored (`:pass`/`:fail`) sample
  in both runs.

  ## Per-case labels (descriptive, never a gate)

  With `p` the share of a case's scored samples that passed and "majority
  pass" meaning `p > 0.5`:

    * `:fixed` - not a majority pass in the baseline, a majority pass in the
      candidate
    * `:broken` - the reverse
    * `:flaky` - neither, and some samples passed while others failed
      (`0 < p < 1`) in either run; only possible with k > 1
    * `:unchanged` - neither, and every scored sample agreed in both runs

  A matched case without scored samples on one side has label `nil`.
  `error_changed` is set, separately from the label, when the case has
  `:error` samples in one run and none in the other. With k samples per
  case no single case can be significant at realistic k (3-of-3 vs 0-of-3
  has Fisher p = 0.1), so labels are for reading failures, not for gating.

  ## Gate rule

  The gate options (`:gate`, a map or keyword list) are:

    * `:metrics` - the declared family of gate metrics, default
      `[:pass_rate]` (see `Nous.Eval.Compare.Metric`: `:pass_rate`,
      `:case_score`, `{:scorer, name}`)
    * `:margin` - tolerated drop, `0.0 <= margin < 1`, default `0.0`
    * `:alpha` - one-sided level, `0 < alpha < 0.5`, default `0.05`
    * `:max_error_rate` - highest tolerated share of `:error` samples in the
      candidate, default `0.0`

  For each gate metric, over the `n` cases where it is defined in both
  runs, let `Δ` be the candidate's mean per-case value minus the
  baseline's. `B` paired cluster bootstrap replicates `Δ*₁…Δ*_B` are drawn
  with the case as the cluster (`Nous.Eval.Stats.Bootstrap.paired_cluster/2`,
  seeded). The one-sided test of

    * H0: `Δ ≥ −margin` (the candidate is no worse than the margin) against
    * H1: `Δ < −margin` (the candidate is worse by more than the margin)

  has the bootstrap p-value `p = (1 + #{b : Δ*_b ≥ −margin}) / (B + 1)`.
  The p-values of the declared metrics are Holm-adjusted together
  (`Nous.Eval.Stats.Hypothesis.holm/2`); a metric **regresses** when its
  adjusted p-value is `<= alpha`. For a single metric this is the
  percentile rule "the upper one-sided `1 − α` bootstrap bound of `Δ` is
  below `−margin`" (reported as `:upper_bound`), up to the `+1` correction.

  The verdict is, in this order:

    1. `:error` when the candidate's error rate exceeds `:max_error_rate`,
       no case is comparable, either run is `:aborted`, or a gate metric
       cannot be tested (defined for fewer than two cases): operational
       failures fail closed and never read as a pass
    2. `:regression` when any gate metric regresses
    3. `:pass` otherwise

  `:reasons` lists why (`%{reason: :error_rate | :no_comparable_cases |
  :run_aborted | :metric_untestable | :regression, ...}`).

  A `:pass` means no drop larger than the margin was *detected*. Each gate
  metric carries `:mde`, the drop this comparison could detect with 80%
  power (`Nous.Eval.Stats.Power.mde/3` with the variance of the per-case
  differences, floored at the binomial noise `m̃(1 − m̃)(1/k_A + 1/k_B)`
  of the smoothed metric mean `m̃` so identical runs still report a
  finite MDE); no significant change is not the same as no change.
  Percentile bootstrap intervals undercover below about 100 cases (Bowyer
  et al. 2025), flagged by `small_n?: true`.

  ## Secondary statistics

    * `:mcnemar` - exact McNemar on per-case majority pass (`b` = fixed,
      `c` = broken cases), reported, not gated
    * `:breakdowns` - exploratory per-tag (pass rate) and per-scorer (score
      pass rate) deltas with two-sided bootstrap p-values
      `min(1, 2·min(1 + #{Δ* ≤ 0}, 1 + #{Δ* ≥ 0}) / (B + 1))`,
      Benjamini–Hochberg adjusted across all breakdowns as one family
      (`significant?` at `alpha`). Tags come from the `:cases` option.
    * `:resources` - cost, latency and token deltas from both runs'
      `Nous.Eval.Summary`: `:cost_total`, `:cost_mean`, `:duration_ms_total`,
      `:duration_ms_mean`, `:duration_ms_p95`, `:tokens_total` and
      `:tokens_mean` (per sample), each `%{baseline, candidate, delta,
      relative}` with `relative = delta / baseline` (`nil` when the baseline
      is zero or unknown)
    * `:fingerprint_changes` - the top-level `Nous.Eval.Fingerprint` keys
      (except `"id"`) whose values differ
    * `:bootstrap` - `seed`, `algorithm`, `resamples`, `streams`,
      `confidence`: everything needed to reproduce the intervals
  """

  alias Nous.Eval.{Case, Run, Stats, Summary}
  alias Nous.Eval.Compare.Metric
  alias Nous.Eval.Stats.{Bootstrap, Hypothesis, Power}

  @default_seed 20_261_101
  @default_resamples 10_000
  @default_streams 8
  @small_n 100
  # Replicates are means of floats; a zero difference can come back as
  # -1.0e-17. Compare against the margin with this slack.
  @tolerance 1.0e-12
  @default_gate %{metrics: [:pass_rate], margin: 0.0, alpha: 0.05, max_error_rate: 0.0}
  @option_keys [
    :gate,
    :seed,
    :resamples,
    :streams,
    :max_concurrency,
    :confidence,
    :allow_dataset_change,
    :cases
  ]

  @type label :: :fixed | :broken | :flaky | :unchanged
  @type verdict :: :pass | :regression | :error
  @type ci :: {float(), float()}

  @type t :: %__MODULE__{
          verdict: verdict(),
          reasons: [map()],
          baseline: %{id: String.t(), status: Run.status(), summary: Summary.t()},
          candidate: %{id: String.t(), status: Run.status(), summary: Summary.t()},
          gate: %{
            metrics: [Metric.t()],
            margin: float(),
            alpha: float(),
            max_error_rate: float()
          },
          dataset: %{
            changed?: boolean(),
            baseline_hash: String.t() | nil,
            candidate_hash: String.t() | nil,
            added: [String.t()],
            removed: [String.t()]
          },
          cases: [map()],
          counts: %{atom() => non_neg_integer()},
          comparable_cases: non_neg_integer(),
          metrics: [map()],
          mcnemar: map() | nil,
          breakdowns: [map()],
          resources: map(),
          fingerprint_changes: [%{key: String.t(), baseline: term(), candidate: term()}],
          bootstrap: map()
        }

  defstruct verdict: :error,
            reasons: [],
            baseline: nil,
            candidate: nil,
            gate: @default_gate,
            dataset: %{},
            cases: [],
            counts: %{},
            comparable_cases: 0,
            metrics: [],
            mcnemar: nil,
            breakdowns: [],
            resources: %{},
            fingerprint_changes: [],
            bootstrap: %{}

  @doc """
  Compares `candidate` against `baseline`.

  Options:

    * `:gate` - see "Gate rule" in the moduledoc
    * `:allow_dataset_change` - compare runs of different datasets on their
      common case ids, default `false`
    * `:seed` - bootstrap seed (integer); default the candidate run's seed,
      else a fixed constant
    * `:resamples` - bootstrap replicates, default `10_000`
    * `:streams` / `:max_concurrency` - bootstrap random streams (default
      `8`) and how many run at once (default `1`); results depend on
      `:streams`, never on `:max_concurrency`
    * `:confidence` - two-sided level of the reported intervals, default
      `0.95`
    * `:cases` - the dataset's cases (`[Nous.Eval.Case.t()]`) or a map of
      case id to tags, for the per-tag breakdown

  Returns `{:error, {:dataset_changed, %{baseline: h, candidate: h}}}`,
  `{:error, {:invalid_option, key}}` or `{:error, {:unknown_option, key}}`
  before computing anything.
  """
  @spec compare(Run.t(), Run.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def compare(baseline, candidate, opts \\ [])

  def compare(%Run{} = baseline, %Run{} = candidate, opts) do
    with {:ok, opts} <- validate(opts, candidate),
         :ok <- check_dataset(baseline, candidate, opts) do
      {:ok, build(baseline, candidate, opts)}
    end
  end

  def compare(_baseline, _candidate, _opts), do: {:error, :not_a_run}

  @doc """
  The comparison as JSON-native data: string keys, strings for atoms,
  `[lower, upper]` lists for intervals and metric names in their string
  form (`"scorer:contains"`). Includes both runs' summaries; never traces.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = c) do
    c
    |> Map.from_struct()
    |> Map.update!(:gate, fn gate ->
      Map.update!(gate, :metrics, &Enum.map(&1, fn m -> Metric.name(m) end))
    end)
    |> Map.update!(
      :metrics,
      &Enum.map(&1, fn m -> Map.update!(m, :metric, fn x -> Metric.name(x) end) end)
    )
    |> Map.update!(
      :breakdowns,
      &Enum.map(&1, fn b -> Map.update!(b, :metric, fn x -> Metric.name(x) end) end)
    )
    |> Map.update!(
      :reasons,
      &Enum.map(&1, fn r -> Map.replace_lazy(r, :metric, fn x -> Metric.name(x) end) end)
    )
    |> Summary.plain()
    |> Map.put("schema", "nous.eval.comparison/1")
  end

  # ── Options ─────────────────────────────────────────────────────────────

  defp validate(opts, candidate) when is_list(opts) do
    with :ok <- known_keys(opts),
         {:ok, gate} <- gate_opt(Keyword.get(opts, :gate, [])),
         {:ok, seed} <- seed_opt(opts, candidate),
         {:ok, resamples} <- pos_int(opts, :resamples, @default_resamples),
         {:ok, streams} <- pos_int(opts, :streams, @default_streams),
         {:ok, concurrency} <- pos_int(opts, :max_concurrency, 1),
         {:ok, confidence} <- confidence_opt(opts),
         {:ok, allow} <- boolean_opt(opts, :allow_dataset_change),
         {:ok, tags} <- tags_opt(Keyword.get(opts, :cases)) do
      {:ok,
       %{
         gate: gate,
         seed: seed,
         resamples: resamples,
         streams: streams,
         max_concurrency: concurrency,
         confidence: confidence,
         allow_dataset_change: allow,
         tags: tags
       }}
    end
  end

  defp validate(_opts, _candidate), do: {:error, {:invalid_option, :opts}}

  defp known_keys(opts) do
    if Keyword.keyword?(opts) do
      case Enum.find(Keyword.keys(opts), &(&1 not in @option_keys)) do
        nil -> :ok
        key -> {:error, {:unknown_option, key}}
      end
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp gate_opt(gate) when is_list(gate) do
    if Keyword.keyword?(gate),
      do: gate_opt(Map.new(gate)),
      else: {:error, {:invalid_option, :gate}}
  end

  defp gate_opt(gate) when is_map(gate) and not is_struct(gate) do
    gate = Map.merge(@default_gate, gate)

    with :ok <- gate_keys(gate),
         {:ok, metrics} <- metrics_opt(gate.metrics),
         :ok <- check(is_number(gate.margin) and gate.margin >= 0 and gate.margin < 1, :margin),
         :ok <- check(is_number(gate.alpha) and gate.alpha > 0 and gate.alpha < 0.5, :alpha),
         :ok <-
           check(
             is_number(gate.max_error_rate) and gate.max_error_rate >= 0 and
               gate.max_error_rate <= 1,
             :max_error_rate
           ) do
      {:ok,
       %{
         metrics: metrics,
         margin: gate.margin / 1,
         alpha: gate.alpha / 1,
         max_error_rate: gate.max_error_rate / 1
       }}
    end
  end

  defp gate_opt(_gate), do: {:error, {:invalid_option, :gate}}

  defp gate_keys(gate) do
    case Enum.find(Map.keys(gate), &(&1 not in Map.keys(@default_gate))) do
      nil -> :ok
      key -> {:error, {:unknown_option, {:gate, key}}}
    end
  end

  defp metrics_opt([_ | _] = metrics) do
    metrics
    |> Enum.reduce_while({:ok, []}, fn metric, {:ok, acc} ->
      case Metric.parse(metric) do
        {:ok, m} -> {:cont, {:ok, [m | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, parsed |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp metrics_opt(_metrics), do: {:error, {:invalid_option, :metrics}}

  defp seed_opt(opts, %Run{seed: run_seed}) do
    case Keyword.get(opts, :seed) do
      nil when is_integer(run_seed) -> {:ok, run_seed}
      nil -> {:ok, @default_seed}
      seed when is_integer(seed) -> {:ok, seed}
      _ -> {:error, {:invalid_option, :seed}}
    end
  end

  defp pos_int(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp confidence_opt(opts) do
    case Keyword.get(opts, :confidence, 0.95) do
      c when is_number(c) and c > 0 and c < 1 -> {:ok, c / 1}
      _ -> {:error, {:invalid_option, :confidence}}
    end
  end

  defp boolean_opt(opts, key) do
    case Keyword.get(opts, key, false) do
      b when is_boolean(b) -> {:ok, b}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp tags_opt(nil), do: {:ok, %{}}

  defp tags_opt(cases) when is_list(cases) do
    if Enum.all?(cases, &is_struct(&1, Case)),
      do: {:ok, Map.new(cases, &{&1.id, &1.tags})},
      else: {:error, {:invalid_option, :cases}}
  end

  defp tags_opt(tags) when is_map(tags) do
    valid? =
      Enum.all?(tags, fn {id, case_tags} ->
        is_binary(id) and is_list(case_tags) and Enum.all?(case_tags, &is_binary/1)
      end)

    if valid?, do: {:ok, tags}, else: {:error, {:invalid_option, :cases}}
  end

  defp tags_opt(_cases), do: {:error, {:invalid_option, :cases}}

  defp check(true, _key), do: :ok
  defp check(false, key), do: {:error, {:invalid_option, key}}

  defp check_dataset(%Run{dataset_hash: same}, %Run{dataset_hash: same}, _opts), do: :ok
  defp check_dataset(_baseline, _candidate, %{allow_dataset_change: true}), do: :ok

  defp check_dataset(baseline, candidate, _opts) do
    {:error,
     {:dataset_changed, %{baseline: baseline.dataset_hash, candidate: candidate.dataset_hash}}}
  end

  # ── Comparison ──────────────────────────────────────────────────────────

  defp build(baseline, candidate, opts) do
    base_cases = Summary.case_stats(baseline.samples)
    cand_cases = Summary.case_stats(candidate.samples)
    base_ids = MapSet.new(Map.keys(base_cases))
    cand_ids = MapSet.new(Map.keys(cand_cases))
    common = base_ids |> MapSet.intersection(cand_ids) |> Enum.sort()

    rows = Enum.map(common, &case_row(&1, base_cases[&1], cand_cases[&1]))
    comparable = for %{id: id, label: label} <- rows, label != nil, do: id
    arms = %{baseline: base_cases, candidate: cand_cases, k: {run_k(baseline), run_k(candidate)}}

    summary_opts = [
      seed: opts.seed,
      resamples: opts.resamples,
      confidence: opts.confidence,
      alpha: opts.gate.alpha
    ]

    base_summary = Summary.build(baseline, summary_opts)
    cand_summary = Summary.build(candidate, summary_opts)
    metrics = gate_metrics(opts.gate.metrics, comparable, arms, opts)
    comparison_reasons = reasons(baseline, candidate, cand_summary, comparable, metrics, opts)

    %__MODULE__{
      verdict: verdict(comparison_reasons),
      reasons: comparison_reasons,
      baseline: %{id: baseline.id, status: baseline.status, summary: base_summary},
      candidate: %{id: candidate.id, status: candidate.status, summary: cand_summary},
      gate: opts.gate,
      dataset: %{
        changed?: baseline.dataset_hash != candidate.dataset_hash,
        baseline_hash: baseline.dataset_hash,
        candidate_hash: candidate.dataset_hash,
        added: cand_ids |> MapSet.difference(base_ids) |> Enum.sort(),
        removed: base_ids |> MapSet.difference(cand_ids) |> Enum.sort()
      },
      cases: rows,
      counts: counts(rows),
      comparable_cases: length(comparable),
      metrics: metrics,
      mcnemar: mcnemar(rows),
      breakdowns: breakdowns(comparable, arms, opts),
      resources: resources(base_summary, cand_summary),
      fingerprint_changes: fingerprint_changes(baseline.fingerprint, candidate.fingerprint),
      bootstrap: %{
        seed: opts.seed,
        algorithm: :exsss,
        resamples: opts.resamples,
        streams: opts.streams,
        confidence: opts.confidence
      }
    }
  end

  defp run_k(%Run{k: k}) when is_integer(k) and k > 0, do: k
  defp run_k(_run), do: 1

  defp case_row(id, base, cand) do
    comparable? = base.scored > 0 and cand.scored > 0

    %{
      id: id,
      label: if(comparable?, do: label(base, cand)),
      error_changed: base.errors > 0 != cand.errors > 0,
      baseline: side(base),
      candidate: side(cand),
      delta: if(comparable?, do: cand.pass_rate - base.pass_rate)
    }
  end

  defp side(c) do
    %{
      passes: c.passes,
      scored: c.scored,
      errors: c.errors,
      pass_rate: c.pass_rate,
      majority_pass?: c.majority_pass?,
      status: c.status
    }
  end

  defp label(base, cand) do
    cond do
      cand.majority_pass? and not base.majority_pass? -> :fixed
      base.majority_pass? and not cand.majority_pass? -> :broken
      mixed?(base) or mixed?(cand) -> :flaky
      true -> :unchanged
    end
  end

  defp mixed?(c), do: c.passes > 0 and c.passes < c.scored

  defp counts(rows) do
    labels = Enum.frequencies_by(rows, & &1.label)

    %{
      fixed: Map.get(labels, :fixed, 0),
      broken: Map.get(labels, :broken, 0),
      flaky: Map.get(labels, :flaky, 0),
      unchanged: Map.get(labels, :unchanged, 0),
      not_comparable: Map.get(labels, nil, 0),
      error_changed: Enum.count(rows, & &1.error_changed)
    }
  end

  defp mcnemar(rows) do
    comparable = Enum.reject(rows, &is_nil(&1.label))

    if comparable == [] do
      nil
    else
      b = Enum.count(comparable, &(&1.label == :fixed))
      c = Enum.count(comparable, &(&1.label == :broken))
      {:ok, test} = Hypothesis.mcnemar(b, c)
      Map.put(test, :n, length(comparable))
    end
  end

  # ── Gate metrics ────────────────────────────────────────────────────────

  defp gate_metrics(metrics, ids, arms, opts) do
    margin = opts.gate.margin
    alpha = opts.gate.alpha

    tested =
      Enum.map(metrics, fn metric ->
        pairs = pairs(metric, ids, arms)
        base = describe_pairs(metric, pairs)

        with {:ok, boot} <- bootstrap(pairs, opts) do
          reps = boot.replicates
          worse_or_equal = Enum.count(reps, &(&1 >= -margin - @tolerance))
          {:ok, upper} = Stats.quantile(reps, 1 - alpha)

          Map.merge(base, %{
            status: :tested,
            ci: boot.ci,
            upper_bound: upper,
            p_value: (1 + worse_or_equal) / (length(reps) + 1),
            mde: metric_mde(pairs, arms, alpha)
          })
        else
          {:error, reason} -> Map.merge(base, %{status: :untestable, detail: reason})
        end
      end)

    p_values = for %{status: :tested, p_value: p} <- tested, do: p
    {:ok, %{adjusted: adjusted}} = Hypothesis.holm(p_values, alpha: alpha)

    {result, []} =
      Enum.map_reduce(tested, adjusted, fn
        %{status: :tested} = m, [adj | rest] ->
          {Map.merge(m, %{adjusted_p_value: adj, regression?: adj <= alpha}), rest}

        m, rest ->
          {m, rest}
      end)

    result
  end

  defp pairs(metric, ids, arms) do
    for id <- ids,
        {cand, base} <- [
          {Metric.value(metric, arms.candidate[id]), Metric.value(metric, arms.baseline[id])}
        ],
        cand != nil and base != nil,
        do: {cand, base}
  end

  defp describe_pairs(metric, pairs) do
    n = length(pairs)
    base_mean = mean(Enum.map(pairs, &elem(&1, 1)))
    cand_mean = mean(Enum.map(pairs, &elem(&1, 0)))

    %{
      metric: metric,
      n: n,
      baseline: base_mean,
      candidate: cand_mean,
      delta: if(n > 0, do: cand_mean - base_mean),
      ci: nil,
      upper_bound: nil,
      p_value: nil,
      adjusted_p_value: nil,
      regression?: false,
      mde: nil,
      small_n?: n < @small_n,
      detail: nil
    }
  end

  defp bootstrap(pairs, _opts) when length(pairs) < 2, do: {:error, :insufficient_cases}

  defp bootstrap(pairs, opts) do
    Bootstrap.paired_cluster(Enum.map(pairs, &[&1]),
      seed: opts.seed,
      resamples: opts.resamples,
      streams: opts.streams,
      max_concurrency: opts.max_concurrency,
      confidence: opts.confidence,
      keep_replicates: true
    )
  end

  defp metric_mde(pairs, %{k: {k_base, k_cand}}, alpha) do
    n = length(pairs)
    diffs = Enum.map(pairs, fn {c, b} -> c - b end)
    {:ok, %{variance: variance}} = Stats.describe(diffs)
    total = Enum.reduce(pairs, 0.0, fn {c, b}, acc -> acc + c + b end)
    smoothed = (total + 1) / (2 * n + 2)
    binomial = smoothed * (1 - smoothed) * (1 / k_base + 1 / k_cand)

    case Power.mde(n, max(variance, binomial), alpha: 2 * alpha, power: 0.8) do
      {:ok, mde} -> mde
      {:error, _} -> nil
    end
  end

  # ── Breakdowns ──────────────────────────────────────────────────────────

  defp breakdowns(ids, arms, opts) do
    tag_entries =
      for {tag, tag_ids} <- tag_groups(ids, opts.tags) do
        breakdown(:tag, tag, :pass_rate, tag_ids, arms, opts)
      end

    scorer_entries =
      for name <- common_scorers(ids, arms) do
        breakdown(:scorer, name, {:scorer, name}, ids, arms, opts)
      end

    entries = tag_entries ++ scorer_entries
    p_values = for %{p_value: p} <- entries, p != nil, do: p
    {:ok, %{adjusted: adjusted}} = Hypothesis.benjamini_hochberg(p_values, alpha: opts.gate.alpha)

    {result, []} =
      Enum.map_reduce(entries, adjusted, fn
        %{p_value: nil} = entry, rest ->
          {entry, rest}

        entry, [adj | rest] ->
          {Map.merge(entry, %{adjusted_p_value: adj, significant?: adj <= opts.gate.alpha}), rest}
      end)

    result
  end

  defp tag_groups(ids, tags) do
    ids
    |> Enum.flat_map(fn id -> tags |> Map.get(id, []) |> Enum.uniq() |> Enum.map(&{&1, id}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
  end

  defp common_scorers(ids, arms) do
    names = fn cases ->
      for id <- ids, name <- Map.keys(cases[id].scorers), into: MapSet.new(), do: name
    end

    arms.baseline
    |> names.()
    |> MapSet.intersection(names.(arms.candidate))
    |> Enum.sort()
  end

  defp breakdown(kind, name, metric, ids, arms, opts) do
    pairs = pairs(metric, ids, arms)

    entry =
      metric
      |> describe_pairs(pairs)
      |> Map.take([
        :metric,
        :n,
        :baseline,
        :candidate,
        :delta,
        :ci,
        :p_value,
        :adjusted_p_value,
        :small_n?
      ])
      |> Map.merge(%{kind: kind, name: name, significant?: false})

    case bootstrap(pairs, opts) do
      {:ok, %{replicates: reps, ci: ci}} ->
        le = Enum.count(reps, &(&1 <= @tolerance))
        ge = Enum.count(reps, &(&1 >= -@tolerance))
        p = min(1.0, 2 * (1 + min(le, ge)) / (length(reps) + 1))
        %{entry | ci: ci, p_value: p}

      {:error, _} ->
        entry
    end
  end

  # ── Verdict ─────────────────────────────────────────────────────────────

  defp reasons(baseline, candidate, cand_summary, comparable, metrics, opts) do
    error_rate = cand_summary["totals"]["error_rate"]
    max_rate = opts.gate.max_error_rate

    operational =
      [
        baseline.status == :aborted && %{reason: :run_aborted, run: :baseline},
        candidate.status == :aborted && %{reason: :run_aborted, run: :candidate},
        (is_number(error_rate) and error_rate > max_rate) &&
          %{reason: :error_rate, error_rate: error_rate, max_error_rate: max_rate},
        comparable == [] && %{reason: :no_comparable_cases}
      ] ++
        for %{status: :untestable} = m <- metrics do
          %{reason: :metric_untestable, metric: m.metric, detail: m.detail}
        end

    case Enum.filter(operational, & &1) do
      [] ->
        for %{regression?: true} = m <- metrics do
          %{
            reason: :regression,
            metric: m.metric,
            delta: m.delta,
            adjusted_p_value: m.adjusted_p_value
          }
        end

      errors ->
        errors
    end
  end

  # `reasons/6` returns either operational errors or regressions, never both.
  defp verdict([]), do: :pass
  defp verdict([%{reason: :regression} | _]), do: :regression
  defp verdict(_reasons), do: :error

  # ── Resources and fingerprint ───────────────────────────────────────────

  defp resources(base, cand) do
    get = fn summary, path -> get_in(summary, ["resources" | path]) end

    Map.new(
      [
        cost_total: ["cost", "total"],
        cost_mean: ["cost", "mean"],
        duration_ms_total: ["duration_ms", "total"],
        duration_ms_mean: ["duration_ms", "mean"],
        duration_ms_p95: ["duration_ms", "p95"],
        tokens_total: ["tokens", "total"],
        tokens_mean: ["tokens", "mean_total"]
      ],
      fn {key, path} -> {key, delta(get.(base, path), get.(cand, path))} end
    )
  end

  defp delta(base, cand) when is_number(base) and is_number(cand) do
    %{
      baseline: base,
      candidate: cand,
      delta: cand - base,
      relative: if(base == 0, do: nil, else: (cand - base) / base)
    }
  end

  defp delta(base, cand), do: %{baseline: base, candidate: cand, delta: nil, relative: nil}

  defp fingerprint_changes(base, cand) do
    base = string_keys(base)
    cand = string_keys(cand)

    (Map.keys(base) ++ Map.keys(cand))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "id"))
    |> Enum.sort()
    |> Enum.filter(&(Map.get(base, &1) != Map.get(cand, &1)))
    |> Enum.map(&%{key: &1, baseline: Map.get(base, &1), candidate: Map.get(cand, &1)})
  end

  defp string_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp string_keys(_), do: %{}

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end

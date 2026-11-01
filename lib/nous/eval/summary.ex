defmodule Nous.Eval.Summary do
  @moduledoc """
  Aggregate metrics of one eval run, computed from its samples.

      summary = Nous.Eval.Summary.build(run)
      summary["pass_rate"]["estimate"]

  The summary is a plain, JSON-native map: **string keys** at every depth,
  values that are strings, numbers, booleans, `nil`, lists and such maps
  (intervals are `[lower, upper]` lists, verdicts and statuses are
  strings). It is meant to be stored as `Nous.Eval.Run`'s `:summary`; a JSON
  round trip gives back a map equal to it under `==` (an integral float may
  come back as an integer), and `Nous.Eval.Reporter.JSON` prints it as is.

  `build/2` never raises on data: zero samples, all-error runs, k = 1 and
  budget-exhausted runs give a summary whose undefined quantities are
  `nil`.

  ## Statistics

  The **case** is the unit of analysis (Miller 2024, "Adding Error Bars to
  Evals", §3.1). With k samples per case the samples of a case are not
  independent, so they are reduced per case or treated as one cluster.

  Only `:pass` and `:fail` samples are *scored*. `:error` samples (a scorer
  failed) are left out of every pass-rate numerator **and** denominator and
  counted in `"error_rate"`; a case whose samples are all `:error` has
  status `"error"`, not `"fail"`. Budget-exhausted samples (verdict `nil`)
  are counted as `"none"` and are in no rate.

  ## Keys

    * `"schema"` - `"nous.eval.summary/1"`
    * `"run_id"`, `"task"`, `"status"`, `"k"`, `"seed"`, `"dataset_hash"`
    * `"confidence"` - the two-sided level of every interval (default 0.95)
    * `"totals"`:
      * `"cases"`, `"samples"`
      * `"verdicts"` - `"pass"`, `"fail"`, `"error"`, `"none"` sample counts
      * `"error_rate"` - `:error` samples over samples with a verdict;
        `nil` when no sample has one
      * `"errors_by_kind"` - scorer errors per `Nous.Eval.ScorerError` kind
        (each error counts once; a sample may carry several)
      * `"outcomes"` - samples per agent-run outcome (`"ok"`, `"error"`,
        `"killed"`, `"budget_exhausted"`)
    * `"cases"` - per case, sorted by id: `"id"`, `"samples"`, `"scored"`,
      `"passes"`, `"errors"`, `"pass_rate"` (over scored samples),
      `"pass_at_k"` / `"pass_hat_k"` (unbiased estimators at the run's k;
      `nil` when fewer than k samples were scored), `"case_score"` (mean of
      the samples' gated `case_score`) and `"status"`: `"pass"` (every scored
      sample passed), `"fail"` (none passed), `"mixed"`, `"error"` (only
      `:error` samples) or `"not_run"`
    * `"pass_rate"` - pooled pass rate over scored samples, with
      `"wilson"` (Wilson interval treating the scored samples as
      independent: exact for k = 1, too narrow for k > 1) and `"clustered"`
      (`"se"`/`"ci"`: cluster-robust SE with one cluster per case, Student-t
      interval with `clusters − 1` df; the interval to read when k > 1).
      `nil` intervals need at least one (Wilson) or two (clustered) cases.
    * `"pass_at_k"`, `"pass_hat_k"` - mean over cases with at least k scored
      samples, `"ci"` a t-interval over those per-case values, clipped to
      `[0, 1]`
    * `"case_score"` - mean of per-case mean `case_score`, clipped t-interval
    * `"mde"` - minimum detectable effect on the pass rate at this run size
      (see below)
    * `"scorers"` - per score or scorer name, independent of verdict
      composition: `"samples"`, `"passed"`, `"pass_rate"` (Wilson, pooled),
      `"mean"` (mean value of `:pass`/`:fail`/float scores, with a seeded
      case-level bootstrap interval), `"labels"` (label distribution),
      `"skipped"` and `"errors"` (by kind). Scores are keyed by
      `Nous.Eval.Score` name (`"judge.relevance"`); skips and errors by the
      scorer id that produced them (`"judge"`).
    * `"resources"` - `"cost"` (total, mean per priced sample, priced
      sample count; `nil` totals when no sample has a price),
      `"duration_ms"` (total, mean, p50, p95), `"tokens"` (input, output,
      total, mean total) and `"iterations"` (total, mean). Means are over
      samples that ran (outcome other than `:budget_exhausted`); totals over
      all samples.
    * `"budget"` - `"exhausted"` (run status `:budget_exhausted`),
      `"unrun_samples"` (verdict `nil`) and `"config"` (the run's `:budget`
      map as plain data)
    * `"error_examples"` - up to 20 scorer errors (`"case_id"`, `"index"`,
      `"scorer"`, `"kind"`, `"reason"` truncated to 300 characters). Reasons
      can contain agent output; renderers escape them.
    * `"bootstrap"` - `"seed"`, `"resamples"`, `"streams"`, `"algorithm"`
      of the per-scorer bootstrap, so the summary is reproducible

  ## Minimum detectable effect

  `"mde"` answers "how large a pass-rate change could a comparison against
  a run of the same size detect": Miller eq. 10,
  `δ = (z_{1−α} + z_{power}) · √(2v / n)` for the one-sided gate test at
  `α` (default 0.05) and power 0.8 (`Nous.Eval.Stats.Power.mde/3`), with `n`
  cases and `v` the sample variance of the per-case pass rates. The `2v`
  assumes the other run is uncorrelated with this one, so a paired
  comparison usually detects less than `"mde"`: it is conservative. `v` is
  floored at the binomial variance `p̃(1 − p̃)/k̄` (`p̃ = (passes + 1) /
  (scored + 2)`, `k̄` scored samples per case) so an all-pass run still
  reports a finite MDE. `nil` below two cases.

  "No significant change" in a comparison only means no change larger than
  about the MDE was detected; it is not evidence of no change.
  """

  alias Nous.Eval.{Run, Sample, Score, ScorerError, Scoring, Stats}
  alias Nous.Eval.Stats.{Bootstrap, Power, Special}

  @schema "nous.eval.summary/1"
  @default_seed 0
  @default_resamples 2_000
  @bootstrap_streams 8
  @max_examples 20
  @reason_limit 300
  @outcomes [:ok, :error, :killed, :budget_exhausted]

  @type t :: %{String.t() => term()}

  @doc "The value of the `\"schema\"` key."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Builds the summary of `run`.

  Options:

    * `:confidence` - two-sided interval level, default `0.95`
    * `:alpha` - one-sided level of the gate test the MDE is computed for,
      in `(0, 0.5)`, default `0.05`
    * `:power` - power for the MDE, default `0.8`
    * `:seed` - seed of the per-scorer bootstrap; default the run's seed,
      else `0`
    * `:resamples` - bootstrap replicates, default `2000`

  Raises `ArgumentError` on an invalid option.
  """
  @spec build(Run.t(), keyword()) :: t()
  def build(%Run{} = run, opts \\ []) do
    opts = validate_opts!(opts, run)
    k = run_k(run)
    samples = run.samples
    cases = samples |> case_stats() |> Map.values() |> Enum.sort_by(& &1.id)
    verdicts = count_verdicts(samples)
    scored = verdicts.pass + verdicts.fail
    with_verdict = scored + verdicts.error

    %{
      "schema" => @schema,
      "run_id" => run.id,
      "task" => run.task,
      "status" => Atom.to_string(run.status),
      "k" => k,
      "seed" => run.seed,
      "dataset_hash" => run.dataset_hash,
      "confidence" => opts[:confidence],
      "totals" => %{
        "cases" => length(cases),
        "samples" => length(samples),
        "verdicts" => %{
          "pass" => verdicts.pass,
          "fail" => verdicts.fail,
          "error" => verdicts.error,
          "none" => verdicts.none
        },
        "error_rate" => ratio(verdicts.error, with_verdict),
        "errors_by_kind" => errors_by_kind(Enum.flat_map(samples, & &1.scorer_errors)),
        "outcomes" => count_outcomes(samples)
      },
      "cases" => Enum.map(cases, &case_json(&1, k)),
      "pass_rate" => pass_rate(cases, verdicts.pass, scored, opts),
      "pass_at_k" => reducer(cases, k, &Stats.pass_at_k/3, opts),
      "pass_hat_k" => reducer(cases, k, &Stats.pass_hat_k/3, opts),
      "case_score" => case_score(cases, opts),
      "mde" => mde(cases, verdicts.pass, scored, opts),
      "scorers" => scorers(samples, cases, opts),
      "resources" => resources(samples),
      "budget" => %{
        "exhausted" => run.status == :budget_exhausted,
        "unrun_samples" => verdicts.none,
        "config" => plain(run.budget)
      },
      "error_examples" => error_examples(samples),
      "bootstrap" => %{
        "seed" => opts[:seed],
        "resamples" => opts[:resamples],
        "streams" => @bootstrap_streams,
        "algorithm" => "exsss"
      }
    }
  end

  defp validate_opts!(opts, run) do
    default_seed = if is_integer(run.seed), do: run.seed, else: @default_seed
    seed = Keyword.get(opts, :seed, default_seed)

    resolved = [
      confidence: Keyword.get(opts, :confidence, 0.95),
      alpha: Keyword.get(opts, :alpha, 0.05),
      power: Keyword.get(opts, :power, 0.8),
      resamples: Keyword.get(opts, :resamples, @default_resamples),
      seed: seed
    ]

    check!(open_unit?(resolved[:confidence]), :confidence)

    check!(
      is_number(resolved[:alpha]) and resolved[:alpha] > 0 and resolved[:alpha] < 0.5,
      :alpha
    )

    check!(open_unit?(resolved[:power]), :power)
    check!(is_integer(resolved[:resamples]) and resolved[:resamples] > 0, :resamples)
    check!(is_integer(seed), :seed)
    resolved
  end

  defp check!(true, _key), do: :ok
  defp check!(false, key), do: raise(ArgumentError, "invalid #{inspect(key)} option")

  defp open_unit?(x), do: is_number(x) and x > 0 and x < 1

  defp run_k(%Run{k: k}) when is_integer(k) and k > 0, do: k
  defp run_k(_run), do: 1

  # ── Per case ────────────────────────────────────────────────────────────

  @doc false
  # Per-case reduction shared with `Nous.Eval.Compare`: `%{case_id => stats}`
  # with atom keys. `:pass_rate` is over scored (`:pass`/`:fail`) samples and
  # `nil` without any; `:majority_pass?` is a strict majority of scored
  # samples; `:scorers` holds `%{name => %{passed, total, values}}` over every
  # sample's scores.
  @spec case_stats([Sample.t()]) :: %{String.t() => map()}
  def case_stats(samples) do
    samples
    |> Enum.group_by(& &1.case_id)
    |> Map.new(fn {id, case_samples} -> {id, case_entry(id, case_samples)} end)
  end

  defp case_entry(id, samples) do
    counts = count_verdicts(samples)
    scored = counts.pass + counts.fail

    %{
      id: id,
      samples: length(samples),
      scored: scored,
      passes: counts.pass,
      errors: counts.error,
      unrun: counts.none,
      sample_passes: for(%Sample{verdict: v} <- samples, v in [:pass, :fail], do: bit(v)),
      pass_rate: ratio(counts.pass, scored),
      majority_pass?: 2 * counts.pass > scored,
      status: case_status(counts, scored),
      case_scores: for(%Sample{case_score: s} <- samples, is_number(s), do: s / 1),
      scorers: case_scorers(samples)
    }
  end

  defp bit(:pass), do: 1
  defp bit(:fail), do: 0

  defp case_status(%{pass: p}, scored) when scored > 0 and p == scored, do: :pass
  defp case_status(%{pass: 0}, scored) when scored > 0, do: :fail
  defp case_status(_counts, scored) when scored > 0, do: :mixed
  defp case_status(%{error: e}, 0) when e > 0, do: :error
  defp case_status(_counts, 0), do: :not_run

  defp case_scorers(samples) do
    for %Sample{scores: scores} <- samples,
        %Score{} = score <- scores,
        reduce: %{} do
      acc ->
        entry = Map.get(acc, score.name, %{passed: 0, total: 0, values: []})

        values =
          case Scoring.value_to_float(score.value) do
            {:ok, v} -> [v | entry.values]
            :error -> entry.values
          end

        Map.put(acc, score.name, %{
          passed: entry.passed + if(score.passed? == true, do: 1, else: 0),
          total: entry.total + 1,
          values: values
        })
    end
  end

  defp case_json(c, k) do
    %{
      "id" => c.id,
      "samples" => c.samples,
      "scored" => c.scored,
      "passes" => c.passes,
      "errors" => c.errors,
      "pass_rate" => c.pass_rate,
      "pass_at_k" => per_case_k(&Stats.pass_at_k/3, c, k),
      "pass_hat_k" => per_case_k(&Stats.pass_hat_k/3, c, k),
      "case_score" => mean(c.case_scores),
      "status" => Atom.to_string(c.status)
    }
  end

  defp per_case_k(fun, c, k) do
    case fun.(c.scored, c.passes, k) do
      {:ok, v} -> v
      {:error, _} -> nil
    end
  end

  # ── Run level ───────────────────────────────────────────────────────────

  defp count_verdicts(samples) do
    Enum.reduce(samples, %{pass: 0, fail: 0, error: 0, none: 0}, fn
      %Sample{verdict: v}, acc when v in [:pass, :fail, :error] -> Map.update!(acc, v, &(&1 + 1))
      _sample, acc -> Map.update!(acc, :none, &(&1 + 1))
    end)
  end

  defp count_outcomes(samples) do
    zero = Map.new(@outcomes, &{Atom.to_string(&1), 0})

    Enum.reduce(samples, zero, fn %Sample{outcome: o}, acc ->
      key = if o in @outcomes, do: Atom.to_string(o), else: "error"
      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  @doc false
  # `%{"kind" => count}` for the given scorer errors; non-zero kinds only.
  @spec errors_by_kind([ScorerError.t()]) :: %{String.t() => pos_integer()}
  def errors_by_kind(errors) do
    Enum.frequencies_by(errors, &kind_name/1)
  end

  defp kind_name(%ScorerError{kind: kind}) when is_atom(kind) and not is_nil(kind),
    do: Atom.to_string(kind)

  defp kind_name(_error), do: "unknown"

  defp pass_rate(cases, passes, scored, opts) do
    conf = opts[:confidence]
    scored_cases = Enum.filter(cases, &(&1.scored > 0))

    wilson =
      case Stats.wilson(passes, scored, confidence: conf) do
        {:ok, %{ci: ci}} -> interval(ci)
        {:error, _} -> nil
      end

    %{
      "estimate" => ratio(passes, scored),
      "cases" => length(scored_cases),
      "samples" => scored,
      "wilson" => wilson,
      "clustered" => clustered(Enum.map(scored_cases, & &1.sample_passes), conf)
    }
  end

  defp clustered(clusters, conf) do
    case Stats.clustered_se(clusters) do
      {:ok, %{mean: mean, se: se, clusters: g}} ->
        t = Special.t_quantile(1 - (1 - conf) / 2, g - 1)
        %{"se" => se, "ci" => [clamp(mean - t * se), clamp(mean + t * se)], "clusters" => g}

      {:error, _} ->
        nil
    end
  end

  defp reducer(cases, k, fun, opts) do
    values =
      for c <- cases, c.scored >= k, {:ok, v} <- [fun.(c.scored, c.passes, k)], do: v

    %{"k" => k, "cases" => length(values), "estimate" => mean(values), "ci" => t_ci(values, opts)}
  end

  defp case_score(cases, opts) do
    values = for c <- cases, c.case_scores != [], do: mean(c.case_scores)
    %{"cases" => length(values), "estimate" => mean(values), "ci" => t_ci(values, opts)}
  end

  # Every value here is in 0..1, so the interval is clipped to it.
  defp t_ci(values, opts) do
    case Stats.mean_ci(values, confidence: opts[:confidence]) do
      {:ok, %{ci: {lo, hi}}} -> [clamp(lo), clamp(hi)]
      {:error, _} -> nil
    end
  end

  defp mde(cases, passes, scored, opts) do
    rates = for c <- cases, c.scored > 0, do: c.pass_rate
    n = length(rates)

    value =
      with true <- n >= 2,
           {:ok, %{variance: v}} <- Stats.describe(rates),
           smoothed = (passes + 1) / (scored + 2),
           binomial = smoothed * (1 - smoothed) / (scored / n),
           {:ok, mde} <-
             Power.mde(n, 2 * max(v, binomial), alpha: 2 * opts[:alpha], power: opts[:power]) do
        mde
      else
        _ -> nil
      end

    %{"pass_rate" => value, "cases" => n, "alpha" => opts[:alpha], "power" => opts[:power]}
  end

  # ── Per scorer ──────────────────────────────────────────────────────────

  defp scorers(samples, cases, opts) do
    skips =
      for %Sample{skipped: skipped} <- samples, {name, _reason} <- skipped, reduce: %{} do
        acc -> Map.update(acc, to_string(name), 1, &(&1 + 1))
      end

    errors =
      samples
      |> Enum.flat_map(& &1.scorer_errors)
      |> Enum.group_by(&to_string(&1.scorer))
      |> Map.new(fn {name, errs} -> {name, errors_by_kind(errs)} end)

    labels =
      for %Sample{scores: scores} <- samples,
          %Score{name: name, value: {:label, label}} <- scores,
          reduce: %{} do
        acc -> Map.update(acc, name, %{label => 1}, &Map.update(&1, label, 1, fn n -> n + 1 end))
      end

    score_names = for c <- cases, name <- Map.keys(c.scorers), into: MapSet.new(), do: name

    score_names
    |> MapSet.union(MapSet.new(Map.keys(skips)))
    |> MapSet.union(MapSet.new(Map.keys(errors)))
    |> Map.new(fn name ->
      per_case = for c <- cases, entry = c.scorers[name], entry != nil, do: entry
      passed = Enum.reduce(per_case, 0, &(&1.passed + &2))
      total = Enum.reduce(per_case, 0, &(&1.total + &2))

      {name,
       %{
         "samples" => total,
         "passed" => passed,
         "pass_rate" => wilson_entry(passed, total, opts),
         "mean" => scorer_mean(Enum.map(per_case, & &1.values), opts),
         "labels" => Map.get(labels, name, %{}),
         "skipped" => Map.get(skips, name, 0),
         "errors" => Map.get(errors, name, %{})
       }}
    end)
  end

  defp wilson_entry(_passed, 0, _opts), do: nil

  defp wilson_entry(passed, total, opts) do
    {:ok, %{estimate: p, ci: ci}} = Stats.wilson(passed, total, confidence: opts[:confidence])
    %{"estimate" => p, "ci" => interval(ci)}
  end

  defp scorer_mean(per_case_values, opts) do
    clusters = for values <- per_case_values, values != [], do: values
    all = List.flatten(clusters)

    case all do
      [] ->
        nil

      _ ->
        %{
          "estimate" => mean(all),
          "cases" => length(clusters),
          "ci" => bootstrap_ci(clusters, opts)
        }
    end
  end

  # One-arm case-level bootstrap: pairing each value with 0.0 makes the
  # paired mean difference the pooled mean of the drawn cases.
  defp bootstrap_ci(clusters, opts) do
    paired = Enum.map(clusters, fn values -> Enum.map(values, &{&1, 0.0}) end)

    case Bootstrap.paired_cluster(paired,
           seed: opts[:seed],
           resamples: opts[:resamples],
           streams: @bootstrap_streams,
           confidence: opts[:confidence]
         ) do
      {:ok, %{ci: ci}} -> interval(ci)
      {:error, _} -> nil
    end
  end

  # ── Resources ───────────────────────────────────────────────────────────

  defp resources(samples) do
    ran = Enum.reject(samples, &(&1.outcome == :budget_exhausted))
    priced = for %Sample{cost: c} <- samples, is_number(c), do: c / 1
    durations = Enum.map(ran, & &1.duration_ms)
    tokens = Enum.map(samples, &usage_field(&1, :total_tokens))

    %{
      "cost" => %{
        "total" => if(priced == [], do: nil, else: Enum.sum(priced)),
        "mean" => mean(priced),
        "priced_samples" => length(priced)
      },
      "duration_ms" => %{
        "total" => Enum.sum(Enum.map(samples, & &1.duration_ms)),
        "mean" => mean(durations),
        "p50" => quantile(durations, 0.5),
        "p95" => quantile(durations, 0.95)
      },
      "tokens" => %{
        "input" => Enum.sum(Enum.map(samples, &usage_field(&1, :input_tokens))),
        "output" => Enum.sum(Enum.map(samples, &usage_field(&1, :output_tokens))),
        "total" => Enum.sum(tokens),
        "mean_total" => mean(Enum.map(ran, &usage_field(&1, :total_tokens)))
      },
      "iterations" => %{
        "total" => Enum.sum(Enum.map(samples, & &1.iterations)),
        "mean" => mean(Enum.map(ran, & &1.iterations))
      }
    }
  end

  defp usage_field(%Sample{usage: %Nous.Usage{} = usage}, key), do: Map.fetch!(usage, key)
  defp usage_field(_sample, _key), do: 0

  defp quantile([], _p), do: nil

  defp quantile(values, p) do
    {:ok, q} = Stats.quantile(values, p)
    q
  end

  # ── Error examples ──────────────────────────────────────────────────────

  defp error_examples(samples) do
    samples
    |> Enum.flat_map(fn s -> Enum.map(s.scorer_errors, &{s, &1}) end)
    |> Enum.take(@max_examples)
    |> Enum.map(fn {s, %ScorerError{} = e} ->
      %{
        "case_id" => s.case_id,
        "index" => s.index,
        "scorer" => to_string(e.scorer),
        "kind" => kind_name(e),
        "reason" => truncate(e.reason)
      }
    end)
  end

  defp truncate(nil), do: nil

  defp truncate(text) when is_binary(text) do
    if String.length(text) > @reason_limit,
      do: String.slice(text, 0, @reason_limit) <> "…",
      else: text
  end

  defp truncate(other), do: other |> inspect() |> truncate()

  # ── Helpers ─────────────────────────────────────────────────────────────

  @doc false
  # Turns any term into JSON-native data: string keys, atoms as strings,
  # tuples as lists, structs as their fields, other terms as `inspect/1`.
  @spec plain(term()) :: term()
  def plain(v) when is_nil(v) or is_boolean(v) or is_number(v) or is_binary(v), do: v
  def plain(v) when is_atom(v), do: Atom.to_string(v)
  def plain(%DateTime{} = v), do: DateTime.to_iso8601(v)
  def plain(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  def plain(%Date{} = v), do: Date.to_iso8601(v)
  def plain(%_{} = v), do: v |> Map.from_struct() |> plain()
  def plain(v) when is_map(v), do: Map.new(v, fn {k, val} -> {key(k), plain(val)} end)
  def plain(v) when is_tuple(v), do: v |> Tuple.to_list() |> plain()

  def plain(v) when is_list(v) do
    if List.improper?(v), do: inspect(v), else: Enum.map(v, &plain/1)
  end

  def plain(v), do: inspect(v)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  @doc false
  @spec interval({number(), number()}) :: [float()]
  def interval({lo, hi}), do: [lo / 1, hi / 1]

  defp ratio(_num, 0), do: nil
  defp ratio(num, den), do: num / den

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp clamp(x), do: x |> max(0.0) |> min(1.0)
end

defmodule Nous.Eval.Guard do
  @moduledoc """
  Guard calibration and the guard non-regression gate.

  Guards (`Nous.Plugins.DecisionGuard`, `Nous.Plugins.InputGuard`) are
  classifiers: they have a false-allow rate (attacks let through) and a
  false-block rate (benign traffic refused), and their bands or thresholds
  trade one for the other. This module measures both on a labelled guard
  dataset (`Nous.Eval.Guard.Dataset`, cases in the `nous.guard_case/1`
  schema), tunes the bands, and decides whether a changed guard or profile
  may replace the current one.

      {:ok, ds} = Nous.Eval.Guard.Dataset.load("test/fixtures/guard")
      guard = {:decision_guard, %{model: "workers_ai:clef-flash"}}

      {:ok, report} = Nous.Eval.Guard.calibrate(ds, guard: guard, surface: :user_input)
      IO.puts(Nous.Eval.Guard.Report.render(report))
      report.patch.text   # the proposed, reviewed config change

  ## Procedure

    1. **Record once.** Every case of the surface is classified by the guard
       as configured (`Nous.Plugins.DecisionGuard.decision/2`), in recording
       mode: every chunk, every answer, every error
       (`Nous.Eval.Guard.Recording`).
    2. **Sweep on `tune` only.** Bands (DecisionGuard, per question and per
       `:choice` option) or Semantic thresholds (InputGuard) are moved by
       coordinate descent over a grid, each setting scored exactly by
       replaying the recorded answers (`Nous.Hook.Decision.replay/2`, the
       function the hook itself decides with). The objective is the expected
       cost per request (`:cost`) or the best recall under a false-block
       ceiling (`{:recall_at_fpr, x}`).
    3. **Report on `holdout`** (and `test` cases that are certifiable),
       never re-tuning there: confusion matrix with an error row, false-allow
       and false-block rates under both escalation views, hard-negative
       FPR, escalation and error rates, precision at the corpus and at a
       production prevalence, PR-AUC / ROC-AUC, recall at a fixed FPR, each
       rate with a Wilson interval (`Nous.Eval.Guard.Metrics`).
    4. **Propose a config patch** (`Nous.Eval.Guard.Report`): the moved
       settings with their holdout evidence, for a human to review. It never
       becomes a `Nous.Profile` component.

  ## Non-regression

  `gate/4` compares a baseline and a candidate guard on the same cases with
  the paired non-inferiority gates of `Nous.Eval.Guard.Gate` (FAR per
  surface, zero-tolerance critical cases, error rate, FPR). The baseline's
  recording is cached by fingerprint (`:cache`), and a candidate that only
  changes bands replays the baseline's recording, so a band change costs no
  model calls at all.

  `optimizer_filter/1` applies the same gates to the guard-tagged cases of
  `Nous.Eval.Optimizer.run/2` (its `:guard` option), so the optimizer cannot
  accept a profile that lets more attacks through.
  """

  alias Nous.Eval.Guard.{Calibration, Case, Dataset, Gate, Recording, Report, Subject}
  alias Nous.Eval.Optimizer.Evaluation
  alias Nous.Eval.Trace

  @type guard :: {:decision_guard, map() | keyword()} | {:input_guard, map() | keyword()}
  @type cases :: Dataset.t() | [Case.t()] | Path.t()

  @doc """
  Records `guard` on the classifier cases of `surface` (see
  `Nous.Eval.Guard.Recording`).

  Options: `:surface` (default `:user_input`), `:tools`, `:cache`,
  `:max_concurrency`.
  """
  @spec record(cases(), guard(), keyword()) :: {:ok, Recording.t()} | {:error, term()}
  def record(cases, guard, opts \\ []) do
    surface = Keyword.get(opts, :surface, :user_input)

    with {:ok, cases} <- load(cases),
         {:ok, subject} <- Subject.new(guard, surface) do
      Recording.record(subject, cases, opts)
    end
  end

  @doc """
  Calibrates a guard on a dataset: records it, sweeps on `tune`, reports on
  `holdout` (and certifiable `test` cases). See the moduledoc.

  ## Options

    * `:guard` - `{:decision_guard, decision_guard_config}` or
      `{:input_guard, input_guard_config}` (required)
    * `:surface` - default `:user_input`
    * `:tools` - descriptions for tool cases without one: the agent's
      `%Nous.Tool{}` list or a `name => description` map
    * `:cache` - directory caching recordings by fingerprint
    * `:objective` - `:cost` (default) or `{:recall_at_fpr, max_fpr}`
    * `:cost_false_allow` (default `10.0`), `:cost_false_block` (`1.0`),
      `:cost_escalation` (`0.25`) - the costs of `:cost`
    * `:prevalence` - the expected production share of attacks; default the
      tune split's share. Also used for the prevalence-adjusted precision
    * `:grid_step` - default `0.05`; `:passes` - default `2`
    * `:max_fpr` - the recall@FPR target reported (default `0.01`)
    * `:report_splits` - default `[:holdout, :test]`
    * gate options (`Nous.Eval.Guard.Gate.check/3`) for the tuned-vs-
      configured gate in the report

  Returns `{:ok, %Nous.Eval.Guard.Report{}}`, or `{:error, reason}` (an
  invalid guard config, a tune split without both labels, ...).
  """
  @spec calibrate(cases() | Recording.t(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def calibrate(cases, opts) do
    with {:ok, guard} <- fetch_guard(opts),
         {:ok, subject} <- Subject.new(guard, Keyword.get(opts, :surface, :user_input)),
         {:ok, recording} <- recording(cases, subject, opts) do
      Calibration.run(recording, subject, opts)
    end
  end

  defp fetch_guard(opts) do
    case Keyword.fetch(opts, :guard) do
      {:ok, guard} -> {:ok, guard}
      :error -> {:error, {:missing_option, :guard}}
    end
  end

  defp recording(%Recording{} = r, %Subject{kind: kind, surface: surface}, _opts)
       when r.kind == kind and r.surface == surface,
       do: {:ok, r}

  defp recording(%Recording{}, _subject, _opts), do: {:error, :recording_of_another_guard}

  defp recording(cases, subject, opts) do
    with {:ok, cases} <- load(cases), do: Recording.record(subject, cases, opts)
  end

  @doc """
  Non-regression gate of `candidate` against `baseline` (both `t:guard/0`
  for the same surface) on one split of `cases` (default `:holdout`), with
  `Nous.Eval.Guard.Gate.check/3`.

  Both are recorded (`:cache` reuses a recording with the same fingerprint;
  a candidate that differs in bands only replays the baseline's recording).
  Options: `:surface`, `:split`, `:tools`, `:cache`, and the gate options.

  Returns `{:ok, report}` when every gate passes, else `{:error, report}`
  (`report.reasons`), or `{:error, reason}` for an invalid guard.
  """
  @spec gate(cases(), guard(), guard(), keyword()) ::
          {:ok, Gate.report()} | {:error, Gate.report() | term()}
  def gate(cases, baseline, candidate, opts \\ []) do
    surface = Keyword.get(opts, :surface, :user_input)
    split = Keyword.get(opts, :split, :holdout)

    with {:ok, cases} <- load(cases),
         cases = Enum.filter(cases, &(&1.split == split)),
         {:ok, base} <- Subject.new(baseline, surface),
         {:ok, cand} <- Subject.new(candidate, surface),
         {:ok, base_rec} <- Recording.record(base, cases, opts),
         {:ok, cand_rec} <- candidate_recording(base_rec, cand, cases, opts) do
      Gate.check(
        Recording.outcomes(base_rec, base),
        Recording.outcomes(cand_rec, cand),
        Keyword.drop(opts, [:surface, :split, :tools, :cache, :max_concurrency])
      )
    end
  end

  defp candidate_recording(base_rec, cand, cases, opts) do
    if Subject.recording_fingerprint(
         cand,
         Enum.map(base_rec.items, & &1.case),
         Keyword.get(opts, :tools, [])
       ) ==
         base_rec.fingerprint,
       do: {:ok, base_rec},
       else: Recording.record(cand, cases, opts)
  end

  @doc """
  Merges a calibration patch (`report.patch.data`) into a guard config, for
  the reviewed change or to gate the candidate: `{:decision_guard, config}`
  gets the surface's `:bands` merged over its own; `{:input_guard, config}`
  gets each patched strategy's options merged.
  """
  @spec apply_patch(guard(), map()) :: guard()
  def apply_patch(guard, patch) when patch == %{}, do: guard

  def apply_patch({:decision_guard, config}, %{surfaces: patched}) do
    config = Map.new(config)

    surfaces =
      Enum.reduce(
        patched,
        normalize_surfaces(Map.get(config, :surfaces, [:user_input])),
        fn {surface, %{bands: bands}}, acc ->
          opts = Map.new(Keyword.get(acc, surface, %{}))
          merged = Map.update(opts, :bands, bands, &Map.merge(Map.new(&1), bands))
          Keyword.put(acc, surface, merged)
        end
      )

    {:decision_guard, Map.put(config, :surfaces, surfaces)}
  end

  def apply_patch({:input_guard, config}, %{strategies: patched}) do
    config = Map.new(config)

    strategies =
      config.strategies
      |> Enum.with_index()
      |> Enum.map(fn {{mod, opts}, index} ->
        {mod, Keyword.merge(opts, Map.get(patched, index, []))}
      end)

    {:input_guard, Map.put(config, :strategies, strategies)}
  end

  defp normalize_surfaces(surfaces) do
    Enum.map(surfaces, fn
      {surface, opts} -> {surface, opts}
      surface -> {surface, %{}}
    end)
  end

  defp load(%Dataset{cases: cases}), do: {:ok, cases}

  defp load(path) when is_binary(path),
    do: with({:ok, ds} <- Dataset.load(path), do: {:ok, ds.cases})

  defp load(cases) when is_list(cases), do: {:ok, cases}

  # ── optimizer feasibility ─────────────────────────────────────────────────

  @doc """
  A guard filter for `Nous.Eval.Optimizer.run/2` (`guard:` option): `fn
  before_eval, after_eval -> :ok | {:error, reason} end` over the
  `Nous.Eval.Optimizer.Evaluation`s of the guard-tagged cases, applying the
  gates of `Nous.Eval.Guard.Gate` to the parent (baseline) and the candidate
  profile.

      Nous.Eval.Optimizer.run(MyEval, guard: Nous.Eval.Guard.optimizer_filter(margin: 0.05))

  Each guard-tagged `Nous.Eval.Case` declares what the guard should do in
  its metadata, string keys:

      metadata: %{"guard" => %{"label" => "block", "surface" => "tool_call",
                               "severity" => "critical", "attack" => true}}

    * `"label"` - `"block"` or `"allow"` (required)
    * `"guard"` - `"decision_guard"` (default) or `"input_guard"`
    * `"surface"` - the DecisionGuard surface whose verdicts count (default:
      every surface)
    * `"severity"` - `"normal"` (default) or `"critical"` (zero tolerance)
    * `"attack"` - `true` makes the case an in-agent attack case: the attack
      succeeded when a sample did not pass the case's scorers (the ASR gate)

  A case's verdict is read from each sample's trace
  (`Nous.Eval.Trace.guard_verdicts/2`, the most severe verdict on the
  surface). Over k samples the worst one counts: a `block` case is a false
  allow when any sample let it through, an `allow` case a false block when
  any sample blocked it. A sample that errored, or in which the guard never
  ran, counts as an error and against the candidate on every gate (fail
  closed). An evaluation that did not complete, or a guard-tagged case
  without a label, is rejected.

  Options: the gate options of `Nous.Eval.Guard.Gate.check/3`.
  """
  @spec optimizer_filter(keyword()) :: (Evaluation.t(), Evaluation.t() -> :ok | {:error, term()})
  def optimizer_filter(opts \\ []) do
    fn %Evaluation{} = before_eval, %Evaluation{} = after_eval ->
      with {:ok, base} <- evaluation_outcomes(before_eval),
           {:ok, cand} <- evaluation_outcomes(after_eval) do
        case Gate.check(base, cand, opts) do
          {:ok, _report} -> :ok
          {:error, report} -> {:error, {:guard_non_regression, report.reasons}}
        end
      end
    end
  end

  @labels %{"block" => :block, "allow" => :allow}
  @guards %{"decision_guard" => :decision_guard, "input_guard" => :input_guard}
  @surfaces %{
    "user_input" => :user_input,
    "tool_call" => :tool_call,
    "tool_result" => :tool_result,
    "model_output" => :model_output
  }
  @severities %{"normal" => :normal, "critical" => :critical}
  @input_verdicts %{safe: :allow, suspicious: :escalate, blocked: :deny}
  @rank %{allow: 0, escalate: 1, deny: 2}

  @doc false
  # Per guard-tagged case: `%{id, label, surface, severity, verdict, error?,
  # attack_succeeded?}` read from the evaluation's samples.
  @spec evaluation_outcomes(Evaluation.t()) :: {:ok, [map()]} | {:error, term()}
  def evaluation_outcomes(%Evaluation{status: status}) when status != :completed,
    do: {:error, {:guard_evaluation_incomplete, status}}

  def evaluation_outcomes(%Evaluation{} = evaluation) do
    samples =
      if evaluation.run, do: Enum.group_by(evaluation.run.samples, & &1.case_id), else: %{}

    Enum.reduce_while(evaluation.case_ids, {:ok, []}, fn id, {:ok, acc} ->
      case case_spec(Map.get(evaluation.cases, id)) do
        {:ok, spec} -> {:cont, {:ok, [case_outcome(id, spec, Map.get(samples, id, [])) | acc]}}
        {:error, reason} -> {:halt, {:error, {:guard_case, id, reason}}}
      end
    end)
    |> case do
      {:ok, outcomes} -> {:ok, Enum.reverse(outcomes)}
      error -> error
    end
  end

  defp case_spec(%{metadata: %{"guard" => %{} = meta}}) do
    with {:ok, label} <- lookup(@labels, meta["label"], "label"),
         {:ok, guard} <- lookup(@guards, Map.get(meta, "guard", "decision_guard"), "guard"),
         {:ok, surface} <- optional(@surfaces, meta["surface"], "surface"),
         {:ok, severity} <- lookup(@severities, Map.get(meta, "severity", "normal"), "severity") do
      {:ok,
       %{
         label: label,
         guard: guard,
         surface: surface,
         severity: severity,
         attack?: meta["attack"] == true
       }}
    end
  end

  defp case_spec(_case), do: {:error, "metadata[\"guard\"] with a \"label\" is required"}

  defp lookup(table, value, key) do
    case Map.fetch(table, value) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error, "#{key} must be one of #{inspect(Map.keys(table))}, got: #{inspect(value)}"}
    end
  end

  defp optional(_table, nil, _key), do: {:ok, nil}
  defp optional(table, value, key), do: lookup(table, value, key)

  defp case_outcome(id, spec, samples) do
    per_sample = Enum.map(samples, &sample_verdict(&1, spec))
    errored? = samples == [] or Enum.any?(per_sample, &match?({_, true}, &1))
    verdicts = Enum.map(per_sample, &elem(&1, 0))

    verdict =
      cond do
        verdicts == [] or nil in verdicts -> nil
        spec.label == :block -> Enum.min_by(verdicts, &@rank[&1])
        true -> Enum.max_by(verdicts, &@rank[&1])
      end

    outcome = %{
      id: id,
      label: spec.label,
      surface: spec.surface || :any,
      severity: spec.severity,
      verdict: verdict,
      error?: errored?
    }

    if spec.attack?,
      do:
        Map.put(
          outcome,
          :attack_succeeded?,
          samples == [] or Enum.any?(samples, &(&1.verdict != :pass))
        ),
      else: outcome
  end

  # {verdict | nil, error?}: the most severe verdict of the guard on the
  # surface in this sample.
  defp sample_verdict(%{verdict: :error}, _spec), do: {nil, true}
  defp sample_verdict(%{trace: nil}, _spec), do: {nil, true}

  defp sample_verdict(%{trace: %Trace{} = trace}, spec) do
    verdicts =
      trace
      |> Trace.guard_verdicts(guard: spec.guard, scope: :tree)
      |> Enum.filter(&(spec.surface == nil or &1.surface == spec.surface))

    case verdicts do
      [] ->
        {nil, true}

      found ->
        {found |> Enum.map(&verdict_of(spec.guard, &1)) |> Enum.max_by(&@rank[&1]),
         Enum.any?(found, &(Map.get(&1.metadata, :error) != nil))}
    end
  end

  defp verdict_of(:input_guard, %{verdict: severity}),
    do: Map.get(@input_verdicts, severity, :deny)

  defp verdict_of(:decision_guard, %{verdict: verdict})
       when verdict in [:allow, :escalate, :deny],
       do: verdict

  defp verdict_of(:decision_guard, _other), do: :deny
end

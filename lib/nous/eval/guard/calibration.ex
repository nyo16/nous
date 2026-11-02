defmodule Nous.Eval.Guard.Calibration do
  @moduledoc false
  # Band / threshold sweeps over a `Nous.Eval.Guard.Recording`: coordinate
  # descent on the `tune` split, exact by replay, then metrics on `holdout`
  # (and certifiable `test` cases) for the configured and the tuned setting.
  # The public entry point is `Nous.Eval.Guard.calibrate/2`.

  alias Nous.Eval.Guard.{Gate, Metrics, Recording, Report, Subject}
  alias Nous.Hook.Decision
  alias Nous.Plugins.InputGuard.Strategies.Semantic

  @defaults [
    objective: :cost,
    cost_false_allow: 10.0,
    cost_false_block: 1.0,
    cost_escalation: 0.25,
    prevalence: nil,
    grid_step: 0.05,
    passes: 2,
    max_fpr: 0.01,
    report_splits: [:holdout, :test]
  ]

  @spec run(Recording.t(), Subject.t(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(%Recording{} = recording, %Subject{} = subject, opts) do
    opts = Keyword.merge(@defaults, opts)
    tune = only(recording, &(&1.split == :tune and &1.label != nil))

    with :ok <- check_objective(opts[:objective]),
         :ok <- check_tune(tune),
         {:ok, grid} <- grid(opts[:grid_step]) do
      {tuned, search} = descend(tune, subject, grid, opts)
      {:ok, report(recording, subject, tuned, search, opts)}
    end
  end

  defp only(recording, pred),
    do: %{recording | items: Enum.filter(recording.items, &pred.(&1.case))}

  defp check_objective(:cost), do: :ok
  defp check_objective({:recall_at_fpr, x}) when is_number(x) and x >= 0 and x <= 1, do: :ok

  defp check_objective(other),
    do:
      {:error,
       {:invalid_option, :objective, other, "expected :cost or {:recall_at_fpr, max_fpr}"}}

  defp check_tune(%Recording{items: items}) do
    labels = items |> Enum.map(& &1.case.label) |> Enum.uniq()

    if :block in labels and :allow in labels,
      do: :ok,
      else: {:error, :tune_split_needs_both_labels}
  end

  defp grid(step) when is_number(step) and step > 0 and step <= 0.5 do
    n = round(1 / step)
    {:ok, Enum.map(0..n, &min(Float.round(&1 * step, 6), 1.0)) |> Enum.uniq()}
  end

  defp grid(_step), do: {:error, {:invalid_option, :grid_step}}

  # ── coordinate descent ──────────────────────────────────────────────────

  defp descend(tune, subject, grid, opts) do
    coordinates = coordinates(subject)
    start = objective(Recording.outcomes(tune, subject), opts)

    {subject, _score, log} =
      Enum.reduce(1..opts[:passes], {subject, start, []}, fn pass, acc ->
        Enum.reduce(coordinates, acc, fn coordinate, {s, score, log} ->
          {best, best_score, tried} = best_value(tune, s, coordinate, grid, score, opts)

          entry = %{
            pass: pass,
            coordinate: coordinate,
            from: value(s, coordinate),
            to: value(best, coordinate),
            objective_before: score,
            objective_after: best_score,
            evaluated: tried
          }

          {best, best_score, [entry | log]}
        end)
      end)

    {subject, Enum.reverse(log)}
  end

  # Keeps the current value unless another is strictly better, so a flat
  # objective leaves the configured setting alone.
  defp best_value(tune, subject, coordinate, grid, current, opts) do
    candidates = values(subject, coordinate, grid)

    Enum.reduce(candidates, {subject, current, 0}, fn v, {best, best_score, tried} ->
      candidate = put_value(subject, coordinate, v)
      score = objective(Recording.outcomes(tune, candidate), opts)

      if score < best_score,
        do: {candidate, score, tried + 1},
        else: {best, best_score, tried + 1}
    end)
  end

  @doc false
  # Lower is better. `:cost` is the expected cost per request at prevalence
  # π: c_FA·π·P(allow | block) + c_FB·(1 − π)·P(deny | allow) +
  # c_esc·P(escalate). `{:recall_at_fpr, x}` maximises recall (escalate ⇒
  # block) among settings whose false-block rate is at most x.
  def objective(outcomes, opts) do
    block = Enum.filter(outcomes, &(&1.label == :block))
    allow = Enum.filter(outcomes, &(&1.label == :allow))
    pi = opts[:prevalence] || length(block) / max(length(outcomes), 1)
    far = share(block, &(&1.verdict == :allow))

    esc =
      pi * share(block, &(&1.verdict == :escalate)) +
        (1 - pi) * share(allow, &(&1.verdict == :escalate))

    case opts[:objective] do
      :cost ->
        fpr = share(allow, &(&1.verdict == :deny))

        {0,
         opts[:cost_false_allow] * pi * far + opts[:cost_false_block] * (1 - pi) * fpr +
           opts[:cost_escalation] * esc}

      {:recall_at_fpr, max_fpr} ->
        fpr = share(allow, &(&1.verdict != :allow))
        if fpr <= max_fpr, do: {0, far, fpr, esc}, else: {1, fpr, far, esc}
    end
  end

  defp share([], _pred), do: 0.0
  defp share(items, pred), do: Enum.count(items, pred) / length(items)

  # ── coordinates ─────────────────────────────────────────────────────────

  # DecisionGuard: one coordinate per question band (per option key for a
  # `:choice` band), swept over `{allow_below, deny_at}` grid pairs.
  # InputGuard: one per Semantic strategy threshold.
  defp coordinates(%Subject{kind: :decision_guard, decision: d}) do
    Enum.flat_map(d.questions, fn q ->
      case Map.fetch!(d.bands, q.id) do
        {_a, _d} -> [{:band, q.id, nil}]
        choice -> Enum.map(choice, fn {key, _band} -> {:band, q.id, key} end)
      end
    end)
  end

  defp coordinates(%Subject{kind: :input_guard, strategies: strategies}) do
    for {{Semantic, _opts}, index} <- Enum.with_index(strategies), do: {:threshold, index}
  end

  defp values(%Subject{kind: :decision_guard}, {:band, _, _}, grid),
    do: for(a <- grid, d <- grid, a <= d, do: {a, d})

  defp values(%Subject{kind: :input_guard}, {:threshold, _}, grid), do: grid

  @doc false
  def value(%Subject{decision: d}, {:band, qid, nil}), do: Map.fetch!(d.bands, qid)

  def value(%Subject{decision: d}, {:band, qid, key}),
    do: d.bands |> Map.fetch!(qid) |> Map.new() |> Map.fetch!(key)

  def value(%Subject{strategies: strategies}, {:threshold, index}),
    do: strategies |> Enum.at(index) |> elem(1) |> Keyword.get(:threshold, 0.85)

  @doc false
  def put_value(%Subject{decision: %Decision{} = d} = s, {:band, qid, nil}, band),
    do: %{s | decision: %{d | bands: Map.put(d.bands, qid, band)}}

  def put_value(%Subject{decision: %Decision{} = d} = s, {:band, qid, key}, band) do
    choice = d.bands |> Map.fetch!(qid) |> Map.new() |> Map.put(key, band)
    %{s | decision: %{d | bands: Map.put(d.bands, qid, choice)}}
  end

  def put_value(%Subject{strategies: strategies} = s, {:threshold, index}, threshold) do
    %{
      s
      | strategies:
          List.update_at(strategies, index, fn {mod, o} ->
            {mod, Keyword.put(o, :threshold, threshold)}
          end)
    }
  end

  # ── report ──────────────────────────────────────────────────────────────

  defp report(recording, baseline, tuned, search, opts) do
    metric_opts =
      Keyword.take(opts, [:prevalence, :max_fpr, :cost_false_allow, :cost_false_block])

    splits =
      for split <- opts[:report_splits],
          part =
            only(
              recording,
              &(&1.split == split and &1.label != nil and Nous.Eval.Guard.Case.certifiable?(&1))
            ),
          part.items != [],
          into: %{} do
        base = Recording.outcomes(part, baseline)
        cand = Recording.outcomes(part, tuned)

        {split,
         %{
           baseline: Metrics.summarize(base, metric_opts),
           tuned: Metrics.summarize(cand, metric_opts),
           gate: gate_result(base, cand, opts)
         }}
      end

    changes = changes(baseline, tuned)

    %Report{
      guard: baseline.kind,
      surface: baseline.surface,
      fingerprint: recording.fingerprint,
      objective: opts[:objective],
      counts: counts(recording),
      search: search,
      changes: changes,
      splits: splits,
      patch: Report.patch(baseline, changes, splits, counts(recording)),
      warnings:
        Enum.flat_map(splits, fn {split, m} -> Enum.map(m.tuned.warnings, &"#{split}: #{&1}") end) ++
          pending_warning(recording)
    }
  end

  defp gate_result(base, cand, opts) do
    gate_opts =
      Keyword.take(opts, [
        :margin,
        :alpha,
        :error_margin,
        :error_alpha,
        :fpr,
        :fpr_alpha,
        :escalate
      ])

    case Gate.check(base, cand, gate_opts) do
      {:ok, report} -> report
      {:error, report} -> report
    end
  end

  defp counts(recording) do
    recording.items
    |> Enum.map(& &1.case)
    |> Enum.group_by(& &1.split)
    |> Map.new(fn {split, cases} ->
      {split, Enum.frequencies_by(cases, &(&1.label || :unlabelled))}
    end)
  end

  defp pending_warning(recording) do
    case Enum.count(
           recording.items,
           &(&1.case.split == :test and not Nous.Eval.Guard.Case.certifiable?(&1.case))
         ) do
      0 ->
        []

      n ->
        ["test: #{n} case(s) awaiting review (or unlabelled) were left out of the test metrics"]
    end
  end

  # `[{coordinate, from, to}]` for every coordinate the sweep moved.
  defp changes(baseline, tuned) do
    for coordinate <- coordinates(baseline),
        from = value(baseline, coordinate),
        to = value(tuned, coordinate),
        from != to,
        do: {coordinate, from, to}
  end
end

defmodule Nous.Eval.Guard.Report do
  @moduledoc """
  The result of `Nous.Eval.Guard.calibrate/2`.

    * `:guard` / `:surface` - what was calibrated
    * `:fingerprint` - the recording's fingerprint (model, questions, cases)
    * `:objective` - the sweep objective
    * `:counts` - `%{split => %{label => n}}` of the recorded cases
    * `:search` - the coordinate-descent log on `tune`: per pass and
      coordinate the value before and after, the objective before and after
      and how many settings were replayed
    * `:changes` - `[{coordinate, from, to}]`, every setting the sweep moved
      (`{:band, question_id, option_key | nil}` or `{:threshold,
      strategy_index}`)
    * `:splits` - per reported split (`holdout`, and `test` when it has
      certifiable cases): `%{baseline: metrics, tuned: metrics, gate:
      gate_report}` (`Nous.Eval.Guard.Metrics.summarize/2`,
      `Nous.Eval.Guard.Gate.check/3` of tuned against configured). The
      sweep never reads these splits
    * `:patch` - the **proposed config patch** `%{data: map, text: string}`:
      `data` is what `Nous.Eval.Guard.apply_patch/2` merges into the guard
      config; `text` is the same patch as reviewed Elixir with its evidence.
      It is never applied automatically and never becomes a
      `Nous.Profile` component: guard settings change only through a
      reviewed config change
    * `:warnings` - imprecise estimates, unmeasurable FPR targets, unreviewed
      test cases left out
  """

  alias Nous.Eval.Guard.Subject

  @type t :: %__MODULE__{
          guard: :decision_guard | :input_guard,
          surface: atom(),
          fingerprint: String.t(),
          objective: term(),
          counts: map(),
          search: [map()],
          changes: [{term(), term(), term()}],
          splits: map(),
          patch: %{data: map(), text: String.t()},
          warnings: [String.t()]
        }

  defstruct [
    :guard,
    :surface,
    :fingerprint,
    :objective,
    counts: %{},
    search: [],
    changes: [],
    splits: %{},
    patch: %{data: %{}, text: ""},
    warnings: []
  ]

  @doc false
  @spec patch(Subject.t(), list(), map(), map()) :: %{data: map(), text: String.t()}
  def patch(
        %Subject{kind: :decision_guard, surface: surface, decision: d},
        changes,
        splits,
        counts
      ) do
    bands =
      for {{:band, qid, _key}, _from, _to} <- changes, into: %{} do
        {qid, d.bands |> Map.fetch!(qid) |> then(&changed_band(&1, qid, changes))}
      end

    data = if bands == %{}, do: %{}, else: %{surfaces: [{surface, %{bands: bands}}]}

    %{
      data: data,
      text: text(data, "DecisionGuard #{inspect(surface)} bands", changes, splits, counts)
    }
  end

  def patch(%Subject{kind: :input_guard}, changes, splits, counts) do
    strategies =
      for {{:threshold, index}, _from, to} <- changes, into: %{}, do: {index, [threshold: to]}

    data = if strategies == %{}, do: %{}, else: %{strategies: strategies}
    %{data: data, text: text(data, "InputGuard Semantic thresholds", changes, splits, counts)}
  end

  # The tuned band of a question: the moved coordinates over the configured
  # band (a `:choice` band keeps its other options).
  defp changed_band(configured, qid, changes) do
    Enum.reduce(changes, configured, fn
      {{:band, ^qid, nil}, _from, to}, _band -> to
      {{:band, ^qid, key}, _from, to}, band -> band |> Map.new() |> Map.put(key, to)
      _other, band -> band
    end)
  end

  defp text(data, _what, _changes, _splits, _counts) when data == %{},
    do: "# No change proposed: the configured settings are already optimal on tune.\n"

  defp text(data, what, changes, splits, counts) do
    evidence =
      for {split, m} <- Enum.sort(splits) do
        "#   #{split}: FAR #{pct(m.baseline.far_eb)} -> #{pct(m.tuned.far_eb)}, " <>
          "FPR #{pct(m.baseline.fpr_eb)} -> #{pct(m.tuned.fpr_eb)}, escalations " <>
          "#{pct(m.baseline.escalation_rate)} -> #{pct(m.tuned.escalation_rate)} (escalate => block view)"
      end

    moves =
      for {coordinate, from, to} <- changes,
          do: "#   #{inspect(coordinate)}: #{inspect(from)} -> #{inspect(to)}"

    tune = counts |> Map.get(:tune, %{}) |> Map.values() |> Enum.sum()

    Enum.join(
      [
        "# Proposed #{what} (review before applying; never applied automatically).",
        "# Tuned on #{tune} tune cases; the numbers below are on cases the sweep never read.",
        "# Changes:"
      ] ++
        moves ++
        ["# Evidence (95% Wilson intervals in the report):"] ++
        evidence ++ [inspect(data, pretty: true, limit: :infinity)],
      "\n"
    ) <> "\n"
  end

  defp pct(nil), do: "n/a"

  defp pct(%{estimate: p, ci: {lo, hi}}),
    do: "#{fmt(p)} [#{fmt(lo)}, #{fmt(hi)}]"

  defp fmt(x), do: :erlang.float_to_binary(x * 100.0, decimals: 1) <> "%"

  @doc """
  The report as plain text: counts, the sweep, per reported split the
  confusion matrix (with its error row) and the metrics for the configured
  and the tuned setting, the gate, warnings and the proposed patch.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = r) do
    header = [
      "Guard calibration: #{r.guard} #{inspect(r.surface)}  (objective #{inspect(r.objective)})",
      "Cases: " <> inspect(r.counts),
      "Sweep (tune only): #{length(r.search)} coordinate passes, " <>
        "#{Enum.sum(Enum.map(r.search, & &1.evaluated))} settings replayed, #{length(r.changes)} setting(s) moved"
    ]

    splits = Enum.flat_map(Enum.sort(r.splits), fn {split, m} -> render_split(split, m) end)
    warnings = Enum.map(r.warnings, &("warning: " <> &1))

    Enum.join(header ++ splits ++ warnings ++ ["", "Config patch:", r.patch.text], "\n")
  end

  defp render_split(split, m) do
    [
      "",
      "== #{split} ==",
      "                      configured                tuned"
    ] ++
      Enum.map(
        [
          far_eb: "FAR (esc=>block)",
          far_ea: "FAR (esc=>allow)",
          fpr_eb: "FPR (esc=>block)",
          fpr_ea: "FPR (esc=>allow)",
          hard_negative_fpr: "hard-negative FPR",
          escalation_rate: "escalation rate",
          error_rate: "error rate"
        ],
        fn {key, label} ->
          String.pad_trailing(label, 22) <>
            String.pad_trailing(pct(m.baseline[key]), 26) <> pct(m.tuned[key])
        end
      ) ++
      [
        "precision/F1 (tuned)  #{num(m.tuned.precision)} / #{num(m.tuned.f1)}",
        "PPV at prevalence #{num(m.tuned.prevalence)}  #{interval(m.tuned.ppv)}; benign blocked per 1000: #{num(m.tuned.benign_blocked_per_1000)}",
        "PR-AUC #{num(m.tuned.threshold_free.pr_auc)}  ROC-AUC #{num(m.tuned.threshold_free.roc_auc)}  " <>
          "recall@FPR #{recall_at(m.tuned.threshold_free.recall_at_fpr)}",
        "confusion (tuned; rows = label, cols = allow/escalate/deny): " <>
          "block #{row(m.tuned.confusion.block)}, allow #{row(m.tuned.confusion.allow)}, " <>
          "error block=#{m.tuned.confusion.error.block} allow=#{m.tuned.confusion.error.allow}",
        "gate (tuned vs configured): " <> if(m.gate.passed?, do: "pass", else: "reject")
      ] ++
      Enum.map(
        m.gate.gates,
        &"  #{&1.gate} #{&1.surface}: #{if &1.passed?, do: "ok", else: "FAIL"} - #{&1.detail}"
      )
  end

  defp row(r), do: "#{r.allow}/#{r.escalate}/#{r.deny}"

  defp recall_at(nil), do: "n/a"
  defp recall_at(r), do: "#{num(r.recall)} at FPR #{num(r.fpr)} (target #{r.max_fpr})"

  defp interval(nil), do: "n/a"
  defp interval(%{estimate: p, ci: {lo, hi}}), do: "#{num(p)} [#{num(lo)}, #{num(hi)}]"

  defp num(nil), do: "n/a"
  defp num(x) when is_number(x), do: :erlang.float_to_binary(x / 1, decimals: 3)
end

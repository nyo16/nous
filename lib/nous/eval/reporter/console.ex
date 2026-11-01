defmodule Nous.Eval.Reporter.Console do
  @moduledoc """
  Plain-text report for a terminal.

  Options:

    * `:colors` - ANSI colors for verdicts and labels; default
      `IO.ANSI.enabled?/0` (false when stdout is not a TTY)
    * `:max_cases` - how many case ids to list per group, default `20`

  Case ids and scorer names are printed as given, with control characters
  replaced by `?` so stored data cannot move the cursor or recolor the
  terminal.
  """

  @behaviour Nous.Eval.Reporter

  import Nous.Eval.Reporter,
    only: [
      pct: 1,
      pp: 1,
      pct_ci: 1,
      pp_ci: 1,
      p_value: 1,
      money: 1,
      number: 2,
      relative: 1,
      reason_text: 1
    ]

  alias Nous.Eval.{Compare, Reporter, Run}
  alias Nous.Eval.Compare.Metric

  @impl true
  def render(subject, opts \\ [])

  def render(%Run{} = run, opts) do
    s = Reporter.summary(run)
    o = options(opts)
    t = s["totals"]
    v = t["verdicts"]
    conf = conf_label(s["confidence"])
    pr = s["pass_rate"]

    [
      line([
        "Eval run ",
        text(s["run_id"]),
        " (",
        text(s["task"] || "no task"),
        "): ",
        s["status"]
      ]),
      line(["Cases ", int(t["cases"]), ", samples ", int(t["samples"]), ", k ", int(s["k"])]),
      line([
        "Verdicts: ",
        int(v["pass"]),
        " pass, ",
        int(v["fail"]),
        " fail, ",
        color(o, error_color(v["error"]), [int(v["error"]), " error"]),
        ", ",
        int(v["none"]),
        " not run"
      ]),
      line(["Error rate: ", pct(t["error_rate"])]),
      line([
        "Pass rate: ",
        pct(pr["estimate"]),
        "  ",
        conf,
        " Wilson ",
        pct_ci(pr["wilson"]),
        "  ",
        conf,
        " clustered ",
        pct_ci(pr["clustered"] && pr["clustered"]["ci"])
      ]),
      line([
        "pass@#{s["pass_at_k"]["k"]}: ",
        pct(s["pass_at_k"]["estimate"]),
        "  pass^#{s["pass_hat_k"]["k"]}: ",
        pct(s["pass_hat_k"]["estimate"]),
        " (#{s["pass_hat_k"]["cases"]} cases)"
      ]),
      line([
        "MDE (one-sided alpha #{s["mde"]["alpha"]}, #{number(s["mde"]["power"] * 100, 0)}% power): ",
        mde(s["mde"]["pass_rate"])
      ]),
      scorers(s["scorers"]),
      line(["Errors by kind: ", kinds(t["errors_by_kind"])]),
      line(["Agent outcomes: ", outcomes(t["outcomes"])]),
      resources(s["resources"]),
      budget(s),
      failing(s, o)
    ]
  end

  def render(%Compare{} = c, opts) do
    o = options(opts)

    [
      line(["Comparison: ", verdict(o, c.verdict)]),
      line([
        "  baseline ",
        text(c.baseline.id),
        " -> candidate ",
        text(c.candidate.id)
      ]),
      reasons(c),
      line([
        "Cases: ",
        int(c.comparable_cases),
        " comparable, ",
        int(length(c.dataset.added)),
        " added, ",
        int(length(c.dataset.removed)),
        " removed",
        if(c.dataset.changed?, do: " (dataset changed)", else: "")
      ]),
      gate(c, o),
      mcnemar(c.mcnemar),
      labels(c),
      case_list(o, "Broken", Reporter.cases_with(c, :broken, o.max_cases), :red),
      case_list(o, "Fixed", Reporter.cases_with(c, :fixed, o.max_cases), :green),
      case_list(o, "Error changed", Reporter.error_changed(c, o.max_cases), :yellow),
      breakdowns(c.breakdowns),
      compare_resources(c.resources),
      line([
        "Errors by kind (candidate): ",
        kinds(c.candidate.summary["totals"]["errors_by_kind"]),
        "; error rate ",
        pct(c.candidate.summary["totals"]["error_rate"])
      ]),
      line(["Fingerprint changes: ", fingerprint(c.fingerprint_changes)]),
      line(
        "No significant change is not evidence of no change: drops smaller than the MDE can go undetected."
      )
    ]
  end

  defp options(opts) do
    %{
      colors: Keyword.get(opts, :colors, IO.ANSI.enabled?()),
      max_cases: Keyword.get(opts, :max_cases, 20)
    }
  end

  # ── Run sections ────────────────────────────────────────────────────────

  defp scorers(scorers) when map_size(scorers) == 0, do: line("Scorers: none")

  defp scorers(scorers) do
    [
      line("Scorers:"),
      for {name, m} <- Enum.sort(scorers) do
        line([
          "  ",
          text(name),
          ": ",
          scorer_scores(m),
          "skipped ",
          int(m["skipped"]),
          ", errors ",
          kinds(m["errors"]),
          labels_dist(m["labels"])
        ])
      end
    ]
  end

  defp scorer_scores(%{"samples" => 0}), do: "no scores, "

  defp scorer_scores(m) do
    [
      "pass ",
      pct(m["pass_rate"]["estimate"]),
      " ",
      pct_ci(m["pass_rate"]["ci"]),
      ", mean ",
      number(m["mean"] && m["mean"]["estimate"], 3),
      ", "
    ]
  end

  defp labels_dist(labels) when map_size(labels) == 0, do: []

  defp labels_dist(labels) do
    [", labels ", labels |> Enum.sort() |> Enum.map_join(" ", fn {l, n} -> "#{text(l)}=#{n}" end)]
  end

  defp kinds(by_kind) when map_size(by_kind) == 0, do: "none"

  defp kinds(by_kind),
    do: by_kind |> Enum.sort() |> Enum.map_join(" ", fn {k, n} -> "#{text(k)}=#{n}" end)

  defp outcomes(outcomes) do
    Enum.map_join(["ok", "error", "killed", "budget_exhausted"], ", ", &"#{outcomes[&1]} #{&1}")
  end

  defp resources(r) do
    line([
      "Resources: cost ",
      money(r["cost"]["total"]),
      " total, ",
      money(r["cost"]["mean"]),
      "/sample; latency mean ",
      number(r["duration_ms"]["mean"], 0),
      " ms, p95 ",
      number(r["duration_ms"]["p95"], 0),
      " ms; tokens ",
      int(r["tokens"]["total"]),
      " total, ",
      number(r["tokens"]["mean_total"], 0),
      "/sample"
    ])
  end

  defp budget(%{"budget" => %{"exhausted" => true, "unrun_samples" => n}}),
    do: line(["Budget: exhausted, ", int(n), " samples not run"])

  defp budget(_summary), do: []

  defp failing(s, o) do
    case Reporter.failing_cases(s, o.max_cases) do
      {[], 0} -> []
      {ids, total} -> line(["Failing cases (", int(total), "): ", ids_text(ids, total)])
    end
  end

  # ── Comparison sections ─────────────────────────────────────────────────

  defp verdict(o, :pass), do: color(o, :green, "PASS")
  defp verdict(o, :regression), do: color(o, :red, "REGRESSION")
  defp verdict(o, :error), do: color(o, :yellow, "ERROR")

  defp reasons(%Compare{reasons: []}), do: []

  defp reasons(%Compare{reasons: reasons}) do
    [line("Reasons:"), Enum.map(reasons, &line(["  - ", reason_text(&1)]))]
  end

  defp gate(%Compare{gate: gate, metrics: metrics}, o) do
    [
      line([
        "Gate (margin ",
        number(gate.margin * 100, 1),
        " pp, one-sided alpha ",
        number(gate.alpha, 2),
        ", Holm, max error rate ",
        pct(gate.max_error_rate),
        "):"
      ]),
      Enum.map(metrics, &gate_metric(&1, o)),
      if(Enum.any?(metrics, & &1.small_n?),
        do: line("  note: fewer than 100 cases; bootstrap intervals may undercover"),
        else: []
      )
    ]
  end

  defp gate_metric(%{status: :untestable} = m, o) do
    line([
      "  ",
      text(Metric.name(m.metric)),
      ": ",
      color(o, :yellow, "UNTESTABLE"),
      " (",
      inspect(m.detail),
      ")"
    ])
  end

  defp gate_metric(m, o) do
    line([
      "  ",
      text(Metric.name(m.metric)),
      ": ",
      pct(m.baseline),
      " -> ",
      pct(m.candidate),
      " (",
      pp(m.delta),
      ", CI ",
      pp_ci(m.ci),
      "), p ",
      p_value(m.p_value),
      ", Holm p ",
      p_value(m.adjusted_p_value),
      ", MDE ",
      mde(m.mde),
      ", n ",
      int(m.n),
      ": ",
      if(m.regression?, do: color(o, :red, "REGRESSION"), else: color(o, :green, "ok"))
    ])
  end

  defp mcnemar(nil), do: []

  defp mcnemar(m) do
    line([
      "McNemar (majority pass): ",
      int(m.b),
      " fixed vs ",
      int(m.c),
      " broken, exact p ",
      p_value(m.p_value),
      ", mid-p ",
      p_value(m.mid_p_value)
    ])
  end

  defp labels(%Compare{counts: n}) do
    line([
      "Labels: ",
      int(n.fixed),
      " fixed, ",
      int(n.broken),
      " broken, ",
      int(n.flaky),
      " flaky, ",
      int(n.unchanged),
      " unchanged, ",
      int(n.not_comparable),
      " not comparable, ",
      int(n.error_changed),
      " error changed"
    ])
  end

  defp case_list(_o, _title, {[], 0}, _color), do: []

  defp case_list(o, title, {ids, total}, color) do
    line([color(o, color, title), " (", int(total), "): ", ids_text(ids, total)])
  end

  defp breakdowns([]), do: []

  defp breakdowns(entries) do
    [
      line("Breakdowns (exploratory, BH-adjusted):"),
      for b <- entries do
        line([
          "  ",
          Atom.to_string(b.kind),
          " ",
          text(b.name),
          ": ",
          pct(b.baseline),
          " -> ",
          pct(b.candidate),
          " (",
          pp(b.delta),
          "), n ",
          int(b.n),
          ", p ",
          p_value(b.p_value),
          ", BH p ",
          p_value(b.adjusted_p_value),
          if(b.significant?, do: " *", else: "")
        ])
      end
    ]
  end

  defp compare_resources(r) do
    [
      line("Resources:"),
      resource_line("cost/sample", r.cost_mean, &money/1),
      resource_line("cost total", r.cost_total, &money/1),
      resource_line("latency mean", r.duration_ms_mean, &ms/1),
      resource_line("latency p95", r.duration_ms_p95, &ms/1),
      resource_line("tokens/sample", r.tokens_mean, &number(&1, 0))
    ]
  end

  defp resource_line(label, d, fmt) do
    rel = relative(d.relative)

    line([
      "  ",
      label,
      " ",
      fmt.(d.baseline),
      " -> ",
      fmt.(d.candidate),
      if(rel == "", do: "", else: " (#{rel})")
    ])
  end

  defp ms(nil), do: "n/a"
  defp ms(x), do: number(x, 0) <> " ms"

  defp fingerprint([]), do: "none"
  defp fingerprint(changes), do: Enum.map_join(changes, ", ", &text(&1.key))

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp mde(nil), do: "n/a"
  defp mde(x), do: number(x * 100, 1) <> " pp"

  defp conf_label(conf), do: number(conf * 100, 0) <> "%"

  defp ids_text(ids, total) do
    shown = Enum.map_join(ids, ", ", &text/1)
    if total > length(ids), do: "#{shown}, ... (#{total - length(ids)} more)", else: shown
  end

  defp error_color(0), do: nil
  defp error_color(_), do: :yellow

  defp int(nil), do: "0"
  defp int(n), do: Integer.to_string(n)

  defp line(content), do: [content, ?\n]

  defp color(_o, nil, content), do: content
  defp color(%{colors: false}, _color, content), do: content
  defp color(%{colors: true}, color, content), do: [ansi(color), content, IO.ANSI.reset()]

  defp ansi(:red), do: IO.ANSI.red()
  defp ansi(:green), do: IO.ANSI.green()
  defp ansi(:yellow), do: IO.ANSI.yellow()

  # Untrusted text: no control characters (ANSI escapes, newlines).
  defp text(nil), do: ""

  defp text(value) do
    value
    |> to_string()
    |> String.replace(~r/[\x{00}-\x{1f}\x{7f}-\x{9f}]/u, "?")
  end
end

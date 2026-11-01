defmodule Nous.Eval.Reporter.Markdown do
  @moduledoc """
  GitHub-flavoured Markdown report, sized for a pull-request comment.

  A comparison shows the verdict and why, the gate metrics with their
  intervals and minimum detectable effect, fixed/broken case lists, label
  counts, per-scorer pass rates, cost/latency/token deltas, scorer errors by
  kind and the fingerprint keys that changed. A run shows its pass rate,
  pass@k / pass^k, MDE, per-scorer table, errors and resources.

  Options:

    * `:max_cases` - how many case ids to list per group, default `20`;
      the full count is always shown
    * `:heading` - heading level of the title, default `3`

  Case ids, scorer names, labels and run ids come from datasets and stored
  runs, so they are untrusted: `escape/1` backslash-escapes Markdown
  punctuation (a `|` cannot break a table, a backtick cannot open code, `@`
  cannot mention), turns `&` into `&amp;` and line breaks into spaces.
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
    pr = s["pass_rate"]
    conf = number(s["confidence"] * 100, 0) <> "%"

    [
      heading(o, 0, ["Eval run ", escape(s["run_id"]), ": ", s["status"]]),
      para([
        "Task ",
        escape(s["task"] || "none"),
        ". ",
        t["cases"] |> to_string(),
        " cases, ",
        to_string(t["samples"]),
        " samples, k = ",
        to_string(s["k"]),
        "."
      ]),
      table(["Metric", "Value"], [
        [
          "Verdicts",
          "#{v["pass"]} pass, #{v["fail"]} fail, #{v["error"]} error, #{v["none"]} not run"
        ],
        ["Error rate", pct(t["error_rate"])],
        ["Pass rate", pct(pr["estimate"])],
        ["#{conf} Wilson", pct_ci(pr["wilson"])],
        ["#{conf} clustered by case", pct_ci(pr["clustered"] && pr["clustered"]["ci"])],
        ["pass@#{s["pass_at_k"]["k"]}", pct(s["pass_at_k"]["estimate"])],
        ["pass^#{s["pass_hat_k"]["k"]}", pct(s["pass_hat_k"]["estimate"])],
        ["MDE (80% power)", mde(s["mde"]["pass_rate"])]
      ]),
      para([
        "> A comparison against a run of this size can only detect pass-rate changes of about ",
        mde(s["mde"]["pass_rate"]),
        "; no significant change is not the same as no change."
      ]),
      budget(s),
      run_scorers(o, s["scorers"]),
      heading(o, 1, "Errors by kind"),
      kinds_table(%{"run" => t["errors_by_kind"]}, ["run"]),
      para([
        "Agent outcomes: ",
        Enum.map_join(
          ["ok", "error", "killed", "budget_exhausted"],
          ", ",
          &"#{t["outcomes"][&1]} #{escape(&1)}"
        )
      ]),
      run_resources(o, s["resources"]),
      failing(o, s)
    ]
  end

  def render(%Compare{} = c, opts) do
    o = options(opts)
    gate = c.gate

    [
      heading(o, 0, ["Eval comparison: ", verdict(c.verdict)]),
      para([
        "Baseline ",
        escape(c.baseline.id),
        " → candidate ",
        escape(c.candidate.id),
        ". ",
        to_string(c.comparable_cases),
        " comparable cases (",
        to_string(length(c.dataset.added)),
        " added, ",
        to_string(length(c.dataset.removed)),
        " removed",
        if(c.dataset.changed?, do: "; dataset changed", else: ""),
        ")."
      ]),
      reasons(c.reasons),
      heading(o, 1, [
        "Gate metrics (margin ",
        number(gate.margin * 100, 1),
        " pp, one-sided α = ",
        number(gate.alpha, 2),
        ", Holm)"
      ]),
      table(
        ["Metric", "Baseline", "Candidate", "Δ", "CI", "p", "Holm p", "MDE", "n", "Result"],
        Enum.map(c.metrics, &gate_row/1)
      ),
      para([
        "> No significant change ≠ no change: this comparison can only detect drops of about the MDE (80% power).",
        if(Enum.any?(c.metrics, & &1.small_n?),
          do: " Fewer than 100 cases: bootstrap intervals may undercover.",
          else: ""
        )
      ]),
      mcnemar(c.mcnemar),
      heading(o, 1, "Cases"),
      table(
        ["Fixed", "Broken", "Flaky", "Unchanged", "Not comparable", "Error changed"],
        [
          Enum.map(
            [:fixed, :broken, :flaky, :unchanged, :not_comparable, :error_changed],
            &to_string(c.counts[&1])
          )
        ]
      ),
      case_list("Broken", Reporter.cases_with(c, :broken, o.max_cases)),
      case_list("Fixed", Reporter.cases_with(c, :fixed, o.max_cases)),
      case_list("Error status changed", Reporter.error_changed(c, o.max_cases)),
      compare_scorers(o, c),
      tags(o, c.breakdowns),
      compare_resources(o, c.resources),
      heading(o, 1, "Errors by kind"),
      kinds_table(
        %{
          "baseline" => c.baseline.summary["totals"]["errors_by_kind"],
          "candidate" => c.candidate.summary["totals"]["errors_by_kind"]
        },
        ["baseline", "candidate"]
      ),
      para([
        "Error rate: baseline ",
        pct(c.baseline.summary["totals"]["error_rate"]),
        ", candidate ",
        pct(c.candidate.summary["totals"]["error_rate"]),
        " (max ",
        pct(gate.max_error_rate),
        ")."
      ]),
      heading(o, 1, "Fingerprint changes"),
      fingerprint(c.fingerprint_changes)
    ]
  end

  @doc """
  Escapes untrusted text for Markdown: backslash before ASCII punctuation
  that Markdown or GitHub interpret, `&` as `&amp;`, line breaks as spaces.

  ## Examples

      iex> Nous.Eval.Reporter.Markdown.escape("a|b `c` @team")
      "a\\\\|b \\\\`c\\\\` \\\\@team"
  """
  @spec escape(term()) :: String.t()
  def escape(nil), do: ""

  def escape(value) do
    value
    |> to_string()
    |> String.replace(~r/\r\n|[\r\n\x{2028}\x{2029}]/u, " ")
    |> String.replace(~r/[\x{00}-\x{1f}\x{7f}]/u, "")
    |> String.replace("&", "&amp;")
    |> String.replace(~r/[\\`*_{}\[\]()<>#+\-.!|~@:]/, "\\\\\\0")
  end

  defp options(opts) do
    %{max_cases: Keyword.get(opts, :max_cases, 20), heading: Keyword.get(opts, :heading, 3)}
  end

  # ── Building blocks ─────────────────────────────────────────────────────

  defp heading(o, depth, title),
    do: [String.duplicate("#", min(o.heading + depth, 6)), " ", title, "\n\n"]

  defp para(content), do: [content, "\n\n"]

  defp table(header, rows) do
    [
      row(header),
      row(Enum.map(header, fn _ -> "---" end)),
      Enum.map(rows, &row/1),
      "\n"
    ]
  end

  defp row(cells), do: ["| ", Enum.intersperse(cells, " | "), " |\n"]

  defp verdict(:pass), do: "**PASS**"
  defp verdict(:regression), do: "**REGRESSION**"
  defp verdict(:error), do: "**ERROR**"

  defp reasons([]), do: []

  defp reasons(reasons) do
    [Enum.map(reasons, &["- ", escape_reason(&1), "\n"]), "\n"]
  end

  # Reason texts embed metric names that came from data.
  defp escape_reason(reason), do: reason |> reason_text() |> escape()

  defp mde(nil), do: "n/a"
  defp mde(x), do: number(x * 100, 1) <> " pp"

  # ── Run sections ────────────────────────────────────────────────────────

  defp budget(%{"budget" => %{"exhausted" => true, "unrun_samples" => n}}),
    do: para(["**Budget exhausted:** ", to_string(n), " samples did not run."])

  defp budget(_summary), do: []

  defp run_scorers(_o, scorers) when map_size(scorers) == 0, do: []

  defp run_scorers(o, scorers) do
    [
      heading(o, 1, "Scorers"),
      table(
        ["Scorer", "Pass rate", "CI", "Mean", "Skipped", "Errors", "Labels"],
        for {name, m} <- Enum.sort(scorers) do
          [
            escape(name),
            pct(m["pass_rate"] && m["pass_rate"]["estimate"]),
            pct_ci(m["pass_rate"] && m["pass_rate"]["ci"]),
            number(m["mean"] && m["mean"]["estimate"], 3),
            to_string(m["skipped"]),
            kinds_inline(m["errors"]),
            labels_inline(m["labels"])
          ]
        end
      )
    ]
  end

  defp run_resources(o, r) do
    [
      heading(o, 1, "Resources"),
      table(["", "Total", "Per sample"], [
        ["Cost", money(r["cost"]["total"]), money(r["cost"]["mean"])],
        [
          "Latency (ms)",
          number(r["duration_ms"]["total"], 0),
          number(r["duration_ms"]["mean"], 0)
        ],
        ["Tokens", to_string(r["tokens"]["total"]), number(r["tokens"]["mean_total"], 0)]
      ])
    ]
  end

  defp failing(o, s) do
    case_list("Failing cases", Reporter.failing_cases(s, o.max_cases))
  end

  # ── Comparison sections ─────────────────────────────────────────────────

  defp gate_row(%{status: :untestable} = m) do
    [
      escape(Metric.name(m.metric)),
      pct(m.baseline),
      pct(m.candidate),
      pp(m.delta),
      "n/a",
      "n/a",
      "n/a",
      "n/a",
      to_string(m.n),
      "untestable: " <> escape(inspect(m.detail))
    ]
  end

  defp gate_row(m) do
    [
      escape(Metric.name(m.metric)),
      pct(m.baseline),
      pct(m.candidate),
      pp(m.delta),
      pp_ci(m.ci),
      p_value(m.p_value),
      p_value(m.adjusted_p_value),
      mde(m.mde),
      to_string(m.n),
      if(m.regression?, do: "**regression**", else: "ok")
    ]
  end

  defp mcnemar(nil), do: []

  defp mcnemar(m) do
    para([
      "McNemar on per-case majority pass (secondary): ",
      to_string(m.b),
      " fixed vs ",
      to_string(m.c),
      " broken, exact p = ",
      p_value(m.p_value),
      "."
    ])
  end

  defp case_list(_title, {[], 0}), do: []

  defp case_list(title, {ids, total}) do
    more = total - length(ids)

    para([
      "**",
      title,
      " (",
      to_string(total),
      "):** ",
      Enum.map_join(ids, ", ", &escape/1),
      if(more > 0, do: ", … and #{more} more", else: "")
    ])
  end

  defp compare_scorers(o, %Compare{} = c) do
    base = c.baseline.summary["scorers"]
    cand = c.candidate.summary["scorers"]
    names = (Map.keys(base) ++ Map.keys(cand)) |> Enum.uniq() |> Enum.sort()
    by_name = for %{kind: :scorer} = b <- c.breakdowns, into: %{}, do: {b.name, b}

    if names == [] do
      []
    else
      [
        heading(o, 1, "Scorers"),
        table(
          ["Scorer", "Baseline", "Candidate", "Paired Δ", "BH p", "Errors (candidate)"],
          for name <- names do
            b = by_name[name]

            [
              escape(name),
              pct(get_in(base, [name, "pass_rate", "estimate"])),
              pct(get_in(cand, [name, "pass_rate", "estimate"])),
              if(b, do: pp(b.delta), else: "n/a"),
              if(b, do: p_value(b.adjusted_p_value), else: "n/a"),
              kinds_inline(get_in(cand, [name, "errors"]) || %{})
            ]
          end
        )
      ]
    end
  end

  defp tags(o, breakdowns) do
    case for(%{kind: :tag} = b <- breakdowns, do: b) do
      [] ->
        []

      entries ->
        [
          heading(o, 1, "Tags (exploratory, BH-adjusted)"),
          table(
            ["Tag", "n", "Baseline", "Candidate", "Δ", "CI", "BH p"],
            for b <- entries do
              [
                escape(b.name),
                to_string(b.n),
                pct(b.baseline),
                pct(b.candidate),
                pp(b.delta),
                pp_ci(b.ci),
                p_value(b.adjusted_p_value) <> if(b.significant?, do: " *", else: "")
              ]
            end
          )
        ]
    end
  end

  defp compare_resources(o, r) do
    [
      heading(o, 1, "Cost and latency"),
      table(
        ["", "Baseline", "Candidate", "Δ", "Relative"],
        [
          resource_row("Cost / sample", r.cost_mean, &money/1),
          resource_row("Cost total", r.cost_total, &money/1),
          resource_row("Latency mean (ms)", r.duration_ms_mean, &number(&1, 0)),
          resource_row("Latency p95 (ms)", r.duration_ms_p95, &number(&1, 0)),
          resource_row("Tokens / sample", r.tokens_mean, &number(&1, 0))
        ]
      )
    ]
  end

  defp resource_row(label, d, fmt) do
    delta =
      case d.delta do
        nil -> "n/a"
        x when x < 0 -> "-" <> fmt.(abs(x))
        x -> "+" <> fmt.(x)
      end

    rel = relative(d.relative)
    [label, fmt.(d.baseline), fmt.(d.candidate), delta, if(rel == "", do: "n/a", else: rel)]
  end

  defp fingerprint([]), do: para("None.")

  defp fingerprint(changes) do
    para(Enum.map_join(changes, "\n", &"- #{escape(&1.key)}"))
  end

  defp kinds_table(columns, order) do
    kinds =
      columns |> Map.values() |> Enum.flat_map(&Map.keys(&1 || %{})) |> Enum.uniq() |> Enum.sort()

    if kinds == [] do
      para("None.")
    else
      table(
        ["Kind" | order],
        for kind <- kinds do
          [escape(kind) | Enum.map(order, &to_string(Map.get(columns[&1] || %{}, kind, 0)))]
        end
      )
    end
  end

  defp kinds_inline(by_kind) when map_size(by_kind) == 0, do: "0"

  defp kinds_inline(by_kind),
    do: by_kind |> Enum.sort() |> Enum.map_join(", ", fn {k, n} -> "#{escape(k)} #{n}" end)

  defp labels_inline(labels) when map_size(labels) == 0, do: ""

  defp labels_inline(labels),
    do: labels |> Enum.sort() |> Enum.map_join(", ", fn {l, n} -> "#{escape(l)} #{n}" end)
end

defmodule Nous.Eval.ProfileReport do
  @moduledoc ~S"""
  The review report for a candidate `Nous.Profile`: what text changed, what
  the evidence says, and every line of text the candidate removes.

      {:ok, report} = Nous.Eval.ProfileReport.build(current, candidate, comparison: cmp, split: "test")
      IO.puts(Nous.Eval.ProfileReport.render(report, format: :markdown))

  It is what a human reads before promoting a profile
  (`mix nous.profile.promote`), and what `mix nous.profile.diff` prints.

  ## Sections

    1. **Title and lineage** - both profiles (name, version, id) and the
       candidate's `parent_id`, `provenance` source and optimizer summary.
    2. **Verdict** (only with evidence) - ACCEPT or REJECT with the split, k,
       the number of comparable cases and the test used (paired cluster
       bootstrap, Holm over the gate metrics; see `Nous.Eval.Compare`), the
       gate metric table, mean tokens per sample, hard gates and the reasons
       for a rejection.
    3. **Components changed** - per added, removed or changed component, a
       line diff (`List.myers_difference/2`) with the line counts, the
       character delta and an estimated token delta (characters / 4).
    4. **Per-case evidence** (only with a comparison) - fixed / broken /
       flaky / unchanged counts (descriptive labels, not per-case
       significance), every broken case in full, fixed cases up to
       `:max_cases`, each with its pass counts and a `run_id#case_id` trace
       reference.
    5. **Removed text (safety review)** - every non-blank line the candidate
       deletes from the instructions or a tool or parameter description,
       verbatim. An optimizer is rewarded for deleting rules that cost it
       points, and its guard gates only catch what they measure, so this
       section is always rendered, even when empty. Lines with wording that
       usually carries a rule ("never", "do not", "must", "refuse",
       "confirm", "always", "only", "forbidden", secrets/safety/policy terms)
       are flagged **high attention**.

  ## Base text

  A profile replaces the agent's base text, and a candidate usually starts
  from no profile at all. Pass the agent as `agent:` so a component one side
  does not set is compared against the agent's base text (see
  `Nous.Profile.components/1`); otherwise it is compared against nothing,
  and a candidate that rewrites the base instructions shows no removed
  lines.

  ## Untrusted text

  Component text, case ids, run ids, names and provenance come from
  optimizer output and stores, so they are untrusted. Markdown escapes them
  with `Nous.Eval.Reporter.Markdown.escape/1` (a `|` cannot break a table, a
  backtick cannot open code, `@` cannot mention); diff blocks are fenced
  with a run of backticks longer than any in the text. Control characters
  are removed in every format, so text cannot carry terminal escapes.
  """

  alias Nous.Agent
  alias Nous.Eval.{CanonicalJSON, Compare, Summary}
  alias Nous.Eval.Compare.Metric
  alias Nous.Eval.Reporter.Markdown
  alias Nous.Profile

  @evidence_keys [:comparison, :decision, :split, :gates]

  # A function, not a module attribute: on OTP 28 a compiled regex holds a
  # reference, and Elixir 1.18 cannot inject a list of them into a function.
  defp attention_patterns do
    [
      {"never", ~r/\bnever\b/iu},
      {"do not", ~r/\b(do not|don'?t|does not|doesn'?t)\b/iu},
      {"must", ~r/\b(must|mustn'?t|shall|may not|should not|shouldn'?t|cannot|can'?t)\b/iu},
      {"refuse", ~r/\b(refus\w*|declin\w*|reject\w*|deny|denied)\b/iu},
      {"confirm", ~r/\b(confirm\w*|verif\w*|approv\w*|permission\w*|consent)\b/iu},
      {"always", ~r/\balways\b/iu},
      {"only", ~r/\bonly\b/iu},
      {"forbidden",
       ~r/\b(forbid\w*|prohibit\w*|not allowed|disallow\w*|under no circumstances)\b/iu},
      {"sensitive",
       ~r/\b(secret\w*|password\w*|credential\w*|confidential|privacy|private|personal|pii|safety|unsafe|policy|policies|legal|compliance)\b/iu}
    ]
  end

  @typedoc """
  * `:base` / `:candidate` - `%{id, name, version, parent_id}` of each
    profile (`:base` is nil without a base profile)
  * `:base_text?` - whether the agent's base text filled the components a
    profile does not set
  * `:diff` - `Nous.Profile.diff/2` of the compared texts
  * `:removed` - the removed lines: `%{key, line, text, attention}` with
    `line` the 1-based line number in the old text and `attention` the
    matched pattern names (`[]` when none)
  * `:verdict` - nil without evidence, else the decision, split, k, n, gate
    metrics, gates and reasons
  * `:cases` - nil without a comparison, else counts and per-case rows
  * `:lineage` - the candidate's `parent_id`, provenance `source` and
    `optimizer` summary
  """
  @type t :: %__MODULE__{
          base: map() | nil,
          candidate: map(),
          base_text?: boolean(),
          diff: map(),
          removed: [map()],
          verdict: map() | nil,
          cases: map() | nil,
          lineage: map()
        }

  @enforce_keys [:candidate, :diff]
  defstruct base: nil,
            candidate: nil,
            base_text?: false,
            diff: nil,
            removed: [],
            verdict: nil,
            cases: nil,
            lineage: %{}

  @doc """
  Builds the report for `candidate` against `base` (a profile, or nil for
  the agent's base text).

  `evidence` is nil (a pure text diff) or a keyword list or map:

    * `:comparison` - a `Nous.Eval.Compare` of the base run (baseline)
      against the candidate run
    * `:decision` - `:accept | :reject`; defaults to `:accept` when the
      comparison's verdict is `:pass` and `:reject` otherwise. An optimizer
      that runs its own acceptance test passes its decision here
    * `:split` - the dataset split the evidence ran on, e.g. `"test"`
    * `:gates` - hard gates, `[%{name: String.t(), passed?: boolean(),
      detail: String.t() | nil}]`; a failed gate makes the default decision
      `:reject`

  Options:

    * `:agent` - a `%Nous.Agent{}` whose base text fills the components a
      profile does not set (see "Base text")
  """
  @spec build(Profile.t() | nil, Profile.t(), keyword() | map() | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(base, candidate, evidence \\ nil, opts \\ [])

  def build(base, %Profile{} = candidate, evidence, opts)
      when is_nil(base) or is_struct(base, Profile) do
    with {:ok, evidence} <- normalize_evidence(evidence),
         {:ok, base_text} <- base_text(Keyword.get(opts, :agent)) do
      keys = component_keys(base) ++ component_keys(candidate)
      fill = Map.take(base_text, keys)
      before = Map.merge(fill, if(base, do: base.components, else: %{}))
      after_ = Map.merge(fill, candidate.components)
      diff = Profile.diff(before, after_)

      {:ok,
       %__MODULE__{
         base: base && meta(base),
         candidate: meta(candidate),
         base_text?: Keyword.has_key?(opts, :agent),
         diff: diff,
         removed: removed_lines(diff),
         verdict: verdict(evidence),
         cases: cases(evidence[:comparison]),
         lineage: lineage(candidate)
       }}
    end
  end

  def build(base, candidate, _evidence, _opts) do
    bad = if is_struct(candidate, Profile), do: base, else: candidate
    {:error, {:not_a_profile, bad}}
  end

  @doc """
  Renders `report` as a string.

  Options:

    * `:format` - `:markdown` (default), `:console` or `:json` (canonical
      JSON of `to_map/1`)
    * `:max_cases` - fixed cases listed, default `20` (broken cases are
      always listed in full)
    * `:heading` - Markdown heading level of the title, default `1`
    * `:context` - unchanged lines shown around each change, default `2`
  """
  @spec render(t(), keyword()) :: String.t()
  def render(%__MODULE__{} = report, opts \\ []) do
    case Keyword.get(opts, :format, :markdown) do
      :json -> CanonicalJSON.encode(to_map(report)) <> "\n"
      format when format in [:markdown, :console] -> render_text(report, format, opts)
    end
  end

  @doc """
  The report as JSON-native data (string keys, strings for atoms),
  marked `"schema" => "nous.profile_report/1"`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    diff = report.diff

    %{
      "schema" => "nous.profile_report/1",
      "base" => report.base,
      "candidate" => report.candidate,
      "base_text" => report.base_text?,
      "lineage" => report.lineage,
      "verdict" => report.verdict,
      "cases" => report.cases,
      "diff" => %{
        "added" => diff.added,
        "removed" => diff.removed,
        "changed" => diff.changed,
        "unchanged" => diff.unchanged,
        "components" =>
          Enum.map(diff.components, fn c ->
            c
            |> Map.drop([:before, :after])
            |> Map.update!(:lines, fn lines -> Enum.map(lines, &Tuple.to_list/1) end)
          end)
      },
      "removed_text" => report.removed
    }
    |> Summary.plain()
  end

  @doc """
  The names of the high-attention patterns `text` matches (see "Sections"),
  `[]` for none.
  """
  @spec attention(String.t()) :: [String.t()]
  def attention(text) when is_binary(text) do
    for {name, regex} <- attention_patterns(), Regex.match?(regex, text), do: name
  end

  # ── build ───────────────────────────────────────────────────────────────

  defp normalize_evidence(nil), do: {:ok, %{}}
  defp normalize_evidence(list) when is_list(list), do: normalize_evidence(Map.new(list))

  defp normalize_evidence(%{} = evidence) when not is_struct(evidence) do
    case Enum.find(Map.keys(evidence), &(&1 not in @evidence_keys)) do
      nil -> Enum.find_value(evidence, {:ok, evidence}, &evidence_error/1)
      key -> {:error, {:unknown_evidence, key}}
    end
  end

  defp normalize_evidence(other), do: {:error, {:invalid_evidence, other}}

  defp evidence_error({:comparison, value}) when is_nil(value) or is_struct(value, Compare),
    do: nil

  defp evidence_error({:decision, value}) when value in [nil, :accept, :reject], do: nil
  defp evidence_error({:split, value}) when is_nil(value) or is_binary(value), do: nil

  defp evidence_error({:gates, gates}) when is_list(gates) do
    if Enum.all?(gates, &gate?/1), do: nil, else: {:error, {:invalid_evidence, :gates}}
  end

  defp evidence_error({key, _value}), do: {:error, {:invalid_evidence, key}}

  defp gate?(%{name: name, passed?: passed}) when is_binary(name) and is_boolean(passed), do: true
  defp gate?(_gate), do: false

  defp base_text(nil), do: {:ok, %{}}

  # Applying no profile only restores the base text; it cannot fail.
  defp base_text(%Agent{} = agent) do
    {:ok, base} = Profile.apply(nil, agent)
    {:ok, Profile.components(base)}
  end

  defp base_text(other), do: {:error, {:invalid_option, {:agent, other}}}

  defp component_keys(nil), do: []
  defp component_keys(%Profile{components: components}), do: Map.keys(components)

  defp meta(%Profile{} = p),
    do: %{id: p.id, name: p.name, version: p.version, parent_id: p.parent_id}

  defp lineage(%Profile{parent_id: parent, provenance: provenance}) do
    %{
      parent_id: parent,
      source: Map.get(provenance, "source"),
      optimizer: Map.get(provenance, "optimizer")
    }
  end

  # Every deleted non-blank line, numbered in the old text.
  defp removed_lines(diff) do
    Enum.flat_map(diff.components, fn %{key: key, lines: lines} ->
      lines
      |> Enum.reduce({1, []}, fn
        {:ins, _text}, {n, acc} ->
          {n, acc}

        {:eq, _text}, {n, acc} ->
          {n + 1, acc}

        {:del, text}, {n, acc} ->
          if String.trim(text) == "",
            do: {n + 1, acc},
            else: {n + 1, [%{key: key, line: n, text: text, attention: attention(text)} | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
    end)
  end

  # nil when there is nothing to decide on: no comparison, gate or decision.
  defp verdict(evidence) do
    comparison = evidence[:comparison]
    gates = evidence[:gates] || []

    if is_nil(comparison) and gates == [] and is_nil(evidence[:decision]) do
      nil
    else
      %{
        decision: evidence[:decision] || default_decision(comparison, gates),
        split: evidence[:split],
        gates: Enum.map(gates, &Map.take(&1, [:name, :passed?, :detail])),
        comparison: comparison && comparison_summary(comparison)
      }
    end
  end

  defp default_decision(comparison, gates) do
    cond do
      Enum.any?(gates, &(not &1.passed?)) -> :reject
      match?(%Compare{verdict: :pass}, comparison) -> :accept
      is_nil(comparison) and gates != [] -> :accept
      true -> :reject
    end
  end

  defp comparison_summary(%Compare{} = c) do
    %{
      verdict: c.verdict,
      baseline_run: c.baseline.id,
      candidate_run: c.candidate.id,
      k: c.candidate.summary["k"],
      n: c.comparable_cases,
      margin: c.gate.margin,
      alpha: c.gate.alpha,
      metrics:
        Enum.map(c.metrics, fn m ->
          %{
            metric: Metric.name(m.metric),
            baseline: m.baseline,
            candidate: m.candidate,
            delta: m.delta,
            ci: m[:ci],
            adjusted_p_value: m[:adjusted_p_value],
            regression?: m[:regression?] || false
          }
        end),
      tokens_mean: c.resources[:tokens_mean],
      reasons: Enum.map(c.reasons, &Nous.Eval.Reporter.reason_text/1)
    }
  end

  defp cases(nil), do: nil

  defp cases(%Compare{} = c) do
    rows =
      for %{label: label} = row <- c.cases, label in [:fixed, :broken] do
        %{
          id: row.id,
          label: label,
          baseline: {row.baseline.passes, row.baseline.scored},
          candidate: {row.candidate.passes, row.candidate.scored}
        }
      end

    %{
      baseline_run: c.baseline.id,
      candidate_run: c.candidate.id,
      counts: Map.take(c.counts, [:fixed, :broken, :flaky, :unchanged, :not_comparable]),
      broken: Enum.filter(rows, &(&1.label == :broken)),
      fixed: Enum.filter(rows, &(&1.label == :fixed))
    }
  end

  # ── render ──────────────────────────────────────────────────────────────

  defp render_text(report, format, opts) do
    o = %{
      format: format,
      max_cases: Keyword.get(opts, :max_cases, 20),
      heading: Keyword.get(opts, :heading, 1),
      context: Keyword.get(opts, :context, 2)
    }

    [
      title(o, report),
      verdict_section(o, report.verdict),
      components_section(o, report),
      cases_section(o, report.cases, report.verdict),
      removed_section(o, report.removed)
    ]
    |> IO.iodata_to_binary()
  end

  defp title(o, report) do
    base =
      cond do
        report.base -> describe(o, report.base)
        report.base_text? -> "the agent's base text"
        true -> "no profile"
      end

    [
      heading(o, 0, ["Profile diff: ", base, " → ", describe(o, report.candidate)]),
      lineage_line(o, report.lineage)
    ]
  end

  defp describe(o, %{name: name, version: version, id: id}) do
    label =
      case {name, version} do
        {nil, _} -> "candidate"
        {name, nil} -> esc(o, name)
        {name, v} -> [esc(o, name), " v", Integer.to_string(v)]
      end

    [label, " (", short_id(o, id), ")"]
  end

  defp short_id(_o, "sha256:" <> hex), do: "sha256:" <> binary_part(hex, 0, 12) <> "…"
  defp short_id(o, other), do: esc(o, other)

  defp lineage_line(o, lineage) do
    parts =
      [
        lineage.parent_id && ["parent ", short_id(o, lineage.parent_id)],
        lineage.source && ["source ", esc(o, lineage.source)],
        optimizer_text(o, lineage.optimizer)
      ]
      |> Enum.filter(& &1)

    if parts == [], do: [], else: para(o, ["Lineage: ", Enum.intersperse(parts, " · ")])
  end

  defp optimizer_text(o, %{} = optimizer) do
    spent =
      case Map.get(optimizer, "budget_spent") do
        %{} = budget when map_size(budget) > 0 ->
          [
            " · spent ",
            budget
            |> Enum.sort()
            |> Enum.map(fn {k, v} -> [esc(o, k), "=", esc(o, scalar(v))] end)
            |> Enum.intersperse(", ")
          ]

        _ ->
          []
      end

    [
      "optimizer ",
      esc(o, scalar(Map.get(optimizer, "strategy", "unknown"))),
      case Map.get(optimizer, "seed") do
        nil -> []
        seed -> [" seed=", esc(o, scalar(seed))]
      end,
      spent
    ]
  end

  defp optimizer_text(_o, _other), do: nil

  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_number(v) or is_boolean(v) or is_nil(v), do: to_string(v)
  defp scalar(v), do: inspect(v)

  # Verdict

  defp verdict_section(_o, nil), do: []

  defp verdict_section(o, verdict) do
    c = verdict.comparison

    [
      heading(o, 1, [
        "Verdict: ",
        strong(o, if(verdict.decision == :accept, do: "ACCEPT", else: "REJECT")),
        verdict_detail(o, verdict.split, c)
      ]),
      metrics_table(o, c),
      gates_line(o, verdict.gates),
      reasons(o, c && c.reasons)
    ]
  end

  defp verdict_detail(_o, nil, nil), do: []

  defp verdict_detail(o, split, nil), do: [" (", esc(o, split), " split)"]

  defp verdict_detail(o, split, c) do
    n_metrics = length(c.metrics)

    [
      " (",
      if(split, do: [esc(o, split), " split, "], else: []),
      "k=",
      to_string(c.k),
      ", ",
      to_string(c.n),
      " cases; paired cluster bootstrap, one-sided α=",
      fmt(c.alpha, 2),
      ", margin ",
      fmt(c.margin * 100, 1),
      " pp, Holm over ",
      to_string(n_metrics),
      if(n_metrics == 1, do: " metric)", else: " metrics)")
    ]
  end

  defp metrics_table(_o, nil), do: []

  defp metrics_table(o, c) do
    rows =
      Enum.map(c.metrics, fn m ->
        [
          esc(o, m.metric),
          fmt(m.baseline, 3),
          fmt(m.candidate, 3),
          signed(m.delta, 3),
          ci(m.ci),
          p(m.adjusted_p_value)
        ]
      end)

    tokens =
      case c.tokens_mean do
        %{baseline: b, candidate: cand} = t when is_number(b) and is_number(cand) ->
          [["mean tokens/sample", fmt(b, 0), fmt(cand, 0), relative(t[:relative]), "—", "—"]]

        _ ->
          []
      end

    table(o, ["metric", "base", "candidate", "Δ", "95% CI", "p (Holm)"], rows ++ tokens)
  end

  defp gates_line(_o, []), do: []

  defp gates_line(o, gates) do
    items =
      Enum.map(gates, fn g ->
        [
          esc(o, g.name),
          if(g[:detail], do: [" (", esc(o, g.detail), ")"], else: []),
          " ",
          strong(o, if(g.passed?, do: "PASS", else: "FAIL"))
        ]
      end)

    para(o, ["Gates (hard): ", Enum.intersperse(items, " · ")])
  end

  defp reasons(_o, nil), do: []
  defp reasons(_o, []), do: []
  defp reasons(o, reasons), do: list(o, Enum.map(reasons, &esc(o, &1)))

  # Components

  defp components_section(o, report) do
    diff = report.diff
    total = length(diff.components) + length(diff.unchanged)

    body =
      if diff.components == [],
        do: para(o, "No component changed."),
        else: Enum.map(diff.components, &component(o, &1))

    [
      heading(o, 1, [
        "Components changed (",
        to_string(length(diff.components)),
        " of ",
        to_string(total),
        ")"
      ]),
      body
    ]
  end

  defp component(o, c) do
    [
      heading(o, 2, [code(o, c.key), "  (", component_stats(c), ")"]),
      diff_block(o, c.lines)
    ]
  end

  defp component_stats(c) do
    kind =
      case c.change do
        :added -> "new, "
        :removed -> "removed, "
        :changed -> ""
      end

    [
      kind,
      "+",
      plural(c.lines_added, "line"),
      ", −",
      plural(c.lines_removed, "line"),
      ", ",
      signed_int(c.chars_delta),
      " chars ≈ ",
      signed_int(c.tokens_delta),
      " tokens"
    ]
  end

  defp plural(1, word), do: "1 " <> word
  defp plural(n, word), do: "#{n} #{word}s"

  defp diff_block(o, lines) do
    shown =
      lines
      |> compact(o.context)
      |> Enum.map(fn
        {:skip, n} -> "  … #{n} unchanged #{if n == 1, do: "line", else: "lines"}"
        {:eq, text} -> ["  ", clean(text)]
        {:del, text} -> ["- ", clean(text)]
        {:ins, text} -> ["+ ", clean(text)]
      end)

    case o.format do
      :markdown ->
        fence = fence(shown)
        [fence, "diff\n", Enum.map(shown, &[&1, "\n"]), fence, "\n\n"]

      :console ->
        [Enum.map(shown, &["    ", &1, "\n"]), "\n"]
    end
  end

  # Unchanged lines more than `context` lines away from a change collapse to
  # one `{:skip, n}` marker.
  defp compact(lines, context) do
    indexed = Enum.with_index(lines)
    changed = for {{op, _}, i} <- indexed, op != :eq, do: i

    keep? = fn i -> Enum.any?(changed, &(abs(&1 - i) <= context)) end

    indexed
    |> Enum.chunk_by(fn {{op, _}, i} -> op != :eq or keep?.(i) end)
    |> Enum.flat_map(fn [{{op, _}, i} | _] = chunk ->
      if op != :eq or keep?.(i),
        do: Enum.map(chunk, &elem(&1, 0)),
        else: [{:skip, length(chunk)}]
    end)
  end

  # A fence longer than any backtick run in the block, so text cannot close
  # it (CommonMark closes a fence only with at least as many backticks).
  defp fence(lines) do
    longest =
      lines
      |> IO.iodata_to_binary()
      |> then(&Regex.scan(~r/`+/, &1))
      |> Enum.map(fn [run] -> byte_size(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end

  # Cases

  defp cases_section(_o, nil, _verdict), do: []

  defp cases_section(o, cases, verdict) do
    counts = cases.counts
    split = verdict && verdict.split

    fixed_shown = Enum.take(cases.fixed, o.max_cases)
    rows = Enum.map(cases.broken ++ fixed_shown, &case_row(o, cases.candidate_run, &1))
    more = length(cases.fixed) - length(fixed_shown)

    [
      heading(o, 1, [
        "Per-case evidence",
        if(split, do: [" (", esc(o, split), " split)"], else: [])
      ]),
      para(o, [
        "fixed #{counts.fixed} · broken #{counts.broken} · flaky #{counts.flaky} · ",
        "unchanged #{counts.unchanged} · not comparable #{counts.not_comparable}",
        "  (descriptive labels; per-case significance not claimed)"
      ]),
      if(rows == [],
        do: [],
        else: table(o, ["case", "label", "base pass", "candidate pass", "trace"], rows)
      ),
      if(more > 0, do: para(o, "… and #{more} more fixed cases."), else: [])
    ]
  end

  defp case_row(o, run_id, row) do
    {bp, bs} = row.baseline
    {cp, cs} = row.candidate

    [
      esc(o, row.id),
      Atom.to_string(row.label),
      "#{bp}/#{bs}",
      "#{cp}/#{cs}",
      esc(o, run_id <> "#" <> row.id)
    ]
  end

  # Removed text

  defp removed_section(o, removed) do
    body =
      if removed == [] do
        para(o, "No lines were removed.")
      else
        flagged = Enum.count(removed, &(&1.attention != []))

        [
          para(o, [
            "Every line the candidate deletes from the instructions or a tool description, verbatim. ",
            to_string(length(removed)),
            " removed, ",
            to_string(flagged),
            " high attention (wording that usually carries a rule)."
          ]),
          list(o, Enum.map(removed, &removed_item(o, &1)))
        ]
      end

    [heading(o, 1, "Removed text (safety review)"), body]
  end

  defp removed_item(o, r) do
    flag =
      case r.attention do
        [] -> []
        names -> [strong(o, "HIGH ATTENTION"), " (", Enum.join(names, ", "), ") "]
      end

    [flag, code(o, r.key), " line ", Integer.to_string(r.line), ": ", esc(o, r.text)]
  end

  # ── format primitives ───────────────────────────────────────────────────

  defp heading(%{format: :markdown} = o, depth, title),
    do: [String.duplicate("#", min(o.heading + depth, 6)), " ", title, "\n\n"]

  defp heading(%{format: :console}, 0, title), do: [title, "\n\n"]
  defp heading(%{format: :console}, 1, title), do: ["== ", title, " ==\n\n"]
  defp heading(%{format: :console}, _depth, title), do: ["-- ", title, "\n"]

  defp para(_o, content), do: [content, "\n\n"]

  defp list(_o, items), do: [Enum.map(items, &["- ", &1, "\n"]), "\n"]

  defp table(%{format: :markdown}, header, rows) do
    row = fn cells -> ["| ", Enum.intersperse(cells, " | "), " |\n"] end
    [row.(header), row.(Enum.map(header, fn _ -> "---" end)), Enum.map(rows, row), "\n"]
  end

  defp table(%{format: :console}, header, rows) do
    all = Enum.map([header | rows], fn cells -> Enum.map(cells, &IO.iodata_to_binary/1) end)

    widths =
      all
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    lines =
      Enum.map(all, fn cells ->
        cells
        |> Enum.zip(widths)
        |> Enum.map(fn {cell, w} -> String.pad_trailing(cell, w) end)
        |> Enum.join("  ")
        |> String.trim_trailing()
        |> then(&["  ", &1, "\n"])
      end)

    [lines, "\n"]
  end

  defp strong(%{format: :markdown}, text), do: ["**", text, "**"]
  defp strong(%{format: :console}, text), do: text

  # A component key or other untrusted identifier shown as an identifier.
  defp code(o, text), do: esc(o, text)

  defp esc(%{format: :markdown}, text), do: Markdown.escape(text)
  defp esc(%{format: :console}, text), do: clean(to_string(text))

  # Control characters (terminal escapes, NUL) never reach the output; tabs
  # become spaces so a line stays one line.
  defp clean(text) do
    text
    |> String.replace("\t", "    ")
    |> String.replace(~r/[\x{00}-\x{1f}\x{7f}-\x{9f}\x{2028}\x{2029}]/u, "")
  end

  defp fmt(nil, _decimals), do: "n/a"
  defp fmt(x, 0), do: x |> round() |> Integer.to_string()
  defp fmt(x, decimals), do: :erlang.float_to_binary(x / 1, decimals: decimals)

  defp signed(nil, _decimals), do: "n/a"
  defp signed(x, decimals) when x < 0, do: "-" <> fmt(abs(x), decimals)
  defp signed(x, decimals), do: "+" <> fmt(x, decimals)

  defp signed_int(n) when n < 0, do: "−#{abs(n)}"
  defp signed_int(n), do: "+#{n}"

  defp relative(nil), do: "n/a"
  defp relative(r), do: signed(r * 100, 1) <> "%"

  defp ci({lo, hi}), do: "[" <> signed(lo, 3) <> ", " <> signed(hi, 3) <> "]"
  defp ci(_none), do: "—"

  defp p(nil), do: "—"
  defp p(x) when x < 0.001, do: "<0.001"
  defp p(x), do: fmt(x, 3)
end

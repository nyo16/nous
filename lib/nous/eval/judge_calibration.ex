defmodule Nous.Eval.JudgeCalibration do
  @moduledoc """
  Measures an LLM judge (`Nous.Eval.Scorers.Judge`) against human labels.

      {:ok, cases} = Nous.Eval.JudgeCalibration.load("priv/eval/judge_cases.jsonl")

      {:ok, result} =
        Nous.Eval.JudgeCalibration.calibrate(
          [judge: "openai:gpt-4o-2024-08-06", rubric: "...", scale: :binary],
          cases
        )

      result.kappa        #=> 0.71
      result.false_pass   #=> %{estimate: 0.06, ci: {0.02, 0.17}, count: 3, n: 50}

  `calibrate/3` replays stored agent outputs through the judge (no agent
  runs) and compares its verdicts with the human labels on the **holdout**
  split only; tune the rubric on the `tune` split and never look at holdout
  results while doing so. `mix nous.eval.judge.calibrate` runs it from the
  command line and stores the result in an eval store
  (`c:Nous.Eval.Store.put_calibration/3`), keyed by the judge's
  `Nous.Eval.Scorers.Judge.fingerprint_id/1`. A judge configured with
  `require_calibration:` refuses to grade unless the stored result matches
  its configuration and passes `check/3`.

  ## Cases (schema `nous.judge_case/1`)

  A JSONL file, one case per line:

      {"id": "refund-17", "input": "Refund order 42", "output": "Refunded $20 for order 42.",
       "reference": "Refund of $20 issued for order 42.", "human_label": "pass",
       "annotator": "ana", "split": "holdout", "group": "refund-17",
       "provenance": "run 2026-10-30-main, sample 0"}

    * `id` - non-empty string, unique
    * `input` - the request: a string or a list of `{role, content}`
      messages (`system`, `user`, `assistant`)
    * `output` - the agent's answer: a string, or a JSON object for
      structured output
    * `reference` - optional reference answer (seen by a judge with
      `include: [:reference]`)
    * `human_label` - the human's verdict, a label of the judge's scale
      (`"pass"`, `"4"`, ...; an integer is read as its string). Human labels
      only: never a judge's own verdict
    * `annotator` - who labelled it
    * `split` - `"tune"` or `"holdout"`; all cases of a `group` must share it
    * `group` - cases that must stay in one split (paraphrases, outputs of
      the same request)
    * `provenance` - where the output came from (string or object)

  Loading is strict like `Nous.Eval.Dataset`: an unknown key, a missing or
  mistyped field, a duplicate id or a group spanning both splits is an
  error, and nothing in the file becomes an atom. A line may carry
  `"schema": "nous.judge_case/1"`.

  ## Metrics (holdout only)

    * `agreement` - share of cases where judge and human gave the same
      label, with a Wilson interval
    * `kappa` - Cohen's κ (`Nous.Eval.Stats.cohen_kappa/2`) for binary,
      ternary and choice scales; quadratic-weighted κ
      (`Nous.Eval.Stats.weighted_kappa/3`) for Likert scales. `nil` when
      undefined
    * `confusion` - counts by human label (rows) and judge label (columns),
      in the scale's label order
    * `false_pass` - among cases the human failed (label value below the
      judge's threshold), the share the judge passed, with a Wilson
      interval; `nil` without such cases
    * `error_rate` - share of cases where the judge returned a
      `Nous.Eval.ScorerError`; those cases are left out of the other
      metrics and listed in `errors`
  """

  alias Nous.Eval.{CanonicalJSON, Score, ScoreInput, ScorerError, Stats, Trace}
  alias Nous.Eval.Scorer.Spec
  alias Nous.Eval.Scorers.Judge
  alias Nous.Eval.Scorers.Judge.Scale
  alias Nous.Message

  @schema "nous.judge_case/1"

  defmodule Case do
    @moduledoc """
    One human-labelled judge case (schema `nous.judge_case/1`); see
    `Nous.Eval.JudgeCalibration`.
    """

    @type t :: %__MODULE__{
            id: String.t(),
            input: String.t() | [Nous.Message.t()],
            output: String.t() | map(),
            reference: String.t() | nil,
            human_label: String.t(),
            annotator: String.t(),
            split: String.t(),
            group: String.t(),
            provenance: String.t() | map()
          }

    @enforce_keys [:id, :input, :output, :human_label, :annotator, :split, :group, :provenance]
    defstruct [
      :id,
      :input,
      :output,
      :human_label,
      :annotator,
      :split,
      :group,
      :provenance,
      reference: nil
    ]
  end

  defmodule Result do
    @moduledoc """
    The outcome of `Nous.Eval.JudgeCalibration.calibrate/3`.

      * `:fingerprint_id` - `Nous.Eval.Scorers.Judge.fingerprint_id/1` of
        the judge measured; a judge with another configuration is stale
      * `:judge` - its `describe/1`, as JSON-native data
      * `:dataset_hash` - content hash of the case set
      * `:labels` - the scale's labels, in display order
      * `:n_cases`, `:n_tune`, `:n_holdout` - case counts; `:n_scored` and
        `:n_errors` split the holdout cases
      * `:agreement`, `:false_pass`, `:error_rate` - `%{estimate, ci: {lower,
        upper}, count, n}` (Wilson, 95%); `nil` when `n` would be 0
      * `:kappa` - float or `nil`; `:kappa_kind` - `:cohen` or
        `:quadratic_weighted`
      * `:confusion` - `%{labels: [label], matrix: [[count]]}`, rows the
        human label, columns the judge's
      * `:errors` - `%{case_id, kind, reason}` per judge error
      * `:usage` - judge tokens summed over the replay (`Nous.Usage`)
      * `:calibrated_at` - when it ran (`DateTime`)
    """

    @type interval :: %{
            estimate: float(),
            ci: {float(), float()},
            count: non_neg_integer(),
            n: pos_integer()
          }

    @type t :: %__MODULE__{
            fingerprint_id: String.t(),
            judge: map(),
            dataset_hash: String.t(),
            labels: [String.t()],
            n_cases: non_neg_integer(),
            n_tune: non_neg_integer(),
            n_holdout: non_neg_integer(),
            n_scored: non_neg_integer(),
            n_errors: non_neg_integer(),
            agreement: interval() | nil,
            kappa: float() | nil,
            kappa_kind: :cohen | :quadratic_weighted,
            confusion: %{labels: [String.t()], matrix: [[non_neg_integer()]]},
            false_pass: interval() | nil,
            error_rate: interval(),
            errors: [%{case_id: String.t(), kind: ScorerError.kind(), reason: String.t() | nil}],
            usage: Nous.Usage.t(),
            calibrated_at: DateTime.t()
          }

    @enforce_keys [:fingerprint_id, :judge, :dataset_hash, :kappa_kind, :confusion, :error_rate]
    defstruct [
      :fingerprint_id,
      :judge,
      :dataset_hash,
      :agreement,
      :kappa,
      :kappa_kind,
      :confusion,
      :false_pass,
      :error_rate,
      :calibrated_at,
      labels: [],
      n_cases: 0,
      n_tune: 0,
      n_holdout: 0,
      n_scored: 0,
      n_errors: 0,
      errors: [],
      usage: %Nous.Usage{}
    ]
  end

  @fields ~w(id input output reference human_label annotator split group provenance)
  @required ~w(id input output human_label annotator split group provenance)
  @splits ["tune", "holdout"]
  @roles %{"system" => :system, "user" => :user, "assistant" => :assistant}

  @doc "The schema id of the case format (`\"nous.judge_case/1\"`)."
  @spec schema() :: String.t()
  def schema, do: @schema

  # ── loading ──────────────────────────────────────────────────────────────

  @doc """
  Loads a `nous.judge_case/1` JSONL file. Blank lines are skipped; errors
  name the file and line.
  """
  @spec load(Path.t()) :: {:ok, [Case.t()]} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with :ok <- check_extension(path),
         {:ok, content} <- read_file(path) do
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> String.trim(line) == "" end)
      |> parse_all(fn {line, number} ->
        with {:ok, map} <- decode_line(line), {:ok, fields} <- take_schema(map) do
          parse_case(fields)
        end
        |> label_error("line #{number}")
      end)
      |> then(fn result -> with {:ok, cases} <- result, do: check_set(cases) end)
      |> prefix_error(path)
    end
  end

  @doc """
  Builds cases from string-keyed maps with the fields of the JSONL format,
  validated the same way as `load/1`.
  """
  @spec new([map()]) :: {:ok, [Case.t()]} | {:error, String.t()}
  def new(maps) when is_list(maps) do
    maps
    |> Enum.with_index(1)
    |> parse_all(fn
      {%{} = map, index} -> map |> parse_case() |> label_error("case #{index}")
      {other, index} -> {:error, "case #{index}: expected a map, got #{inspect(other)}"}
    end)
    |> then(fn result -> with {:ok, cases} <- result, do: check_set(cases) end)
  end

  defp check_extension(path) do
    if path |> Path.extname() |> String.downcase() == ".jsonl",
      do: :ok,
      else: {:error, "#{path}: judge cases must be a .jsonl file"}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "#{path}: cannot read: #{:file.format_error(reason)}"}
    end
  end

  defp decode_line(line) do
    case JSON.decode(line) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, "expected a JSON object, got #{inspect(other)}"}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  defp take_schema(map) do
    case Map.pop(map, "schema") do
      {nil, rest} ->
        {:ok, rest}

      {@schema, rest} ->
        {:ok, rest}

      {other, _} ->
        {:error, "unsupported schema #{inspect(other)} (expected #{inspect(@schema)})"}
    end
  end

  defp parse_case(fields) do
    id = if is_binary(fields["id"]), do: fields["id"]

    with :ok <- check_keys(fields),
         {:ok, id} <- non_empty("id", fields["id"]),
         {:ok, input} <- input(fields["input"]),
         {:ok, output} <- output(fields["output"]),
         {:ok, reference} <- reference(fields["reference"]),
         {:ok, label} <- human_label(fields["human_label"]),
         {:ok, annotator} <- non_empty("annotator", fields["annotator"]),
         {:ok, split} <- split(fields["split"]),
         {:ok, group} <- non_empty("group", fields["group"]),
         {:ok, provenance} <- provenance(fields["provenance"]) do
      {:ok,
       %Case{
         id: id,
         input: input,
         output: output,
         reference: reference,
         human_label: label,
         annotator: annotator,
         split: split,
         group: group,
         provenance: provenance
       }}
    end
    |> label_error(if id, do: "case #{inspect(id)}", else: "case")
  end

  defp check_keys(fields) do
    cond do
      not Enum.all?(Map.keys(fields), &is_binary/1) ->
        {:error, "object keys must be strings"}

      (unknown = Map.keys(fields) -- @fields) != [] ->
        {:error, "unknown key #{unknown |> Enum.sort() |> hd() |> inspect()}"}

      (missing = Enum.reject(@required, &Map.has_key?(fields, &1))) != [] ->
        {:error, "missing key #{inspect(hd(missing))}"}

      true ->
        :ok
    end
  end

  defp non_empty(_key, value) when is_binary(value) and value != "", do: {:ok, value}

  defp non_empty(key, value),
    do: {:error, "#{key} must be a non-empty string, got #{inspect(value)}"}

  defp input(text) when is_binary(text), do: {:ok, text}

  defp input([_ | _] = messages) do
    messages
    |> Enum.with_index(1)
    |> parse_all(fn
      {%{"role" => role, "content" => content} = message, _index}
      when map_size(message) == 2 and is_binary(content) and is_map_key(@roles, role) ->
        {:ok, build_message(Map.fetch!(@roles, role), content)}

      {other, index} ->
        {:error,
         "input message #{index} must be {role: system|user|assistant, content: string}, " <>
           "got #{inspect(other)}"}
    end)
  end

  defp input(other),
    do: {:error, "input must be a string or a non-empty message list, got #{inspect(other)}"}

  defp build_message(:system, content), do: Message.system(content)
  defp build_message(:user, content), do: Message.user(content)
  defp build_message(:assistant, content), do: Message.assistant(content)

  defp output(text) when is_binary(text), do: {:ok, text}

  defp output(%{} = map) do
    if string_keys?(map),
      do: {:ok, map},
      else: {:error, "output object keys must be strings"}
  end

  defp output(other),
    do: {:error, "output must be a string or a JSON object, got #{inspect(other)}"}

  defp reference(nil), do: {:ok, nil}
  defp reference(text) when is_binary(text), do: {:ok, text}
  defp reference(other), do: {:error, "reference must be a string, got #{inspect(other)}"}

  defp human_label(label) when is_binary(label) and label != "", do: {:ok, label}
  defp human_label(label) when is_integer(label), do: {:ok, Integer.to_string(label)}

  defp human_label(other),
    do: {:error, "human_label must be a non-empty string, got #{inspect(other)}"}

  defp split(split) when split in @splits, do: {:ok, split}

  defp split(other),
    do: {:error, "split must be \"tune\" or \"holdout\", got #{inspect(other)}"}

  defp provenance(text) when is_binary(text) and text != "", do: {:ok, text}

  defp provenance(%{} = map) when map_size(map) > 0 do
    if string_keys?(map),
      do: {:ok, map},
      else: {:error, "provenance object keys must be strings"}
  end

  defp provenance(other),
    do: {:error, "provenance must be a non-empty string or object, got #{inspect(other)}"}

  defp string_keys?(%{} = map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and string_keys?(value) end)

  defp string_keys?(list) when is_list(list), do: Enum.all?(list, &string_keys?/1)
  defp string_keys?(_), do: true

  defp check_set(cases) do
    duplicate = cases |> Enum.frequencies_by(& &1.id) |> Enum.find(fn {_, n} -> n > 1 end)

    leaking =
      cases
      |> Enum.group_by(& &1.group, & &1.split)
      |> Enum.find(fn {_group, splits} -> length(Enum.uniq(splits)) > 1 end)

    cond do
      duplicate -> {:error, "duplicate case id #{inspect(elem(duplicate, 0))}"}
      leaking -> {:error, "group #{inspect(elem(leaking, 0))} has cases in both tune and holdout"}
      true -> {:ok, cases}
    end
  end

  # ── calibration ──────────────────────────────────────────────────────────

  @doc """
  Replays the holdout cases through the judge and measures it against the
  human labels.

  `judge` is the judge's options (`[judge: "openai:...", scale: ...]`),
  `{Nous.Eval.Scorers.Judge, opts}` or a `Nous.Eval.Scorer.Spec` for it.
  `:require_calibration`, `:calibration` and `:gate` are ignored: they
  decide whether a judge may grade, not what it answers.

  ## Options

    * `:concurrency` - judge calls in flight (default `4`)
    * `:timeout` - per case, in ms (default `120_000`); a case that runs
      over counts as a judge error

  Returns `{:error, reason}` before any judge call when the judge options
  are invalid, a human label is not a label of the judge's scale, the
  judge includes evidence a case cannot provide (`:tool_calls`,
  `:transcript`: judge cases carry no trace), or there are no holdout cases.
  """
  @spec calibrate(keyword() | {module(), keyword()} | Spec.t(), [Case.t()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def calibrate(judge, cases, opts \\ []) when is_list(cases) and is_list(opts) do
    with {:ok, judge_opts} <- judge_opts(judge),
         {:ok, config} <- Judge.init(judge_opts),
         :ok <- check_include(config),
         :ok <- check_labels(cases, config.scale),
         holdout = Enum.filter(cases, &(&1.split == "holdout")),
         :ok <- if(holdout == [], do: {:error, :no_holdout_cases}, else: :ok) do
      outcomes = replay(holdout, config, opts)
      {:ok, result(cases, holdout, outcomes, config)}
    end
  end

  defp judge_opts(%Spec{module: Judge, opts: opts}), do: judge_opts(opts)
  defp judge_opts({Judge, opts}), do: judge_opts(opts)

  # The judge under calibration is not a gate and needs no calibration: those
  # options decide whether it may grade, not what it answers.
  defp judge_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, Keyword.drop(opts, [:require_calibration, :calibration, :gate]) ++ [gate: false]},
      else: {:error, {:invalid_judge, opts}}
  end

  defp judge_opts(other), do: {:error, {:invalid_judge, other}}

  defp check_include(config) do
    case Enum.filter(config.include, &(&1 in [:tool_calls, :transcript])) do
      [] -> :ok
      items -> {:error, {:unsupported_include, items}}
    end
  end

  defp check_labels(cases, %Scale{values: values}) do
    case Enum.find(cases, &(not Map.has_key?(values, &1.human_label))) do
      nil -> :ok
      c -> {:error, {:unknown_human_label, c.id, c.human_label}}
    end
  end

  defp replay(holdout, config, opts) do
    concurrency = Keyword.get(opts, :concurrency, 4)
    timeout = Keyword.get(opts, :timeout, 120_000)

    Nous.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(holdout, &judge_case(&1, config),
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(holdout)
    |> Enum.map(fn
      {{:ok, outcome}, c} -> {c, outcome}
      {{:exit, :timeout}, c} -> {c, {:error, judge_error(:timeout, "exceeded #{timeout} ms")}}
      {{:exit, reason}, c} -> {c, {:error, judge_error(:raised, "exited: " <> inspect(reason))}}
    end)
  end

  defp judge_case(%Case{} = c, config) do
    input = %ScoreInput{
      case: %Nous.Eval.Case{
        id: c.id,
        input: c.input,
        expected: if(c.reference, do: %{"output" => c.reference}, else: %{})
      },
      sample: 0,
      output: c.output,
      run_outcome: {:ok, %{}},
      trace: %Trace{trace_id: ""}
    }

    case Judge.score(input, config) do
      {:ok, %Score{} = score} -> {:ok, score}
      {:error, %ScorerError{} = error} -> {:error, error}
    end
  rescue
    e -> {:error, judge_error(:raised, Exception.message(e))}
  end

  defp judge_error(kind, reason), do: %ScorerError{scorer: "judge", kind: kind, reason: reason}

  defp result(cases, holdout, outcomes, config) do
    scale = config.scale
    scored = for {c, {:ok, score}} <- outcomes, do: {c, score}

    errors =
      for {c, {:error, e}} <- outcomes, do: %{case_id: c.id, kind: e.kind, reason: e.reason}

    pairs = Enum.map(scored, fn {c, score} -> {c.human_label, score.metadata.label} end)

    {kappa, kappa_kind} = kappa(pairs, scale)

    human_fails =
      Enum.filter(scored, fn {c, _score} ->
        Map.fetch!(scale.values, c.human_label) < config.threshold
      end)

    %Result{
      fingerprint_id: Judge.fingerprint_id(config),
      judge: config |> Judge.describe() |> CanonicalJSON.encode() |> JSON.decode!(),
      dataset_hash: dataset_hash(cases),
      labels: scale.labels,
      n_cases: length(cases),
      n_tune: Enum.count(cases, &(&1.split == "tune")),
      n_holdout: length(holdout),
      n_scored: length(scored),
      n_errors: length(errors),
      agreement: interval(Enum.count(pairs, fn {h, j} -> h == j end), length(pairs)),
      kappa: kappa,
      kappa_kind: kappa_kind,
      confusion: confusion(pairs, scale.labels),
      false_pass:
        interval(Enum.count(human_fails, fn {_c, s} -> s.passed? end), length(human_fails)),
      error_rate: interval(length(errors), length(holdout)),
      errors: errors,
      usage:
        Enum.reduce(scored, %Nous.Usage{}, fn {_c, s}, acc ->
          Nous.Usage.add(acc, s.metadata.usage)
        end),
      calibrated_at: DateTime.utc_now()
    }
  end

  defp kappa([], %Scale{kind: :likert}), do: {nil, :quadratic_weighted}
  defp kappa([], _scale), do: {nil, :cohen}

  defp kappa(pairs, %Scale{kind: :likert} = scale) do
    {:ok, k} = Stats.weighted_kappa(pairs, Scale.ordered_labels(scale), weights: :quadratic)
    {k, :quadratic_weighted}
  end

  defp kappa(pairs, %Scale{labels: labels}) do
    {:ok, k} = Stats.cohen_kappa(pairs, labels: labels)
    {k, :cohen}
  end

  defp interval(_count, 0), do: nil

  defp interval(count, n) do
    {:ok, %{estimate: estimate, ci: ci}} = Stats.wilson(count, n)
    %{estimate: estimate, ci: ci, count: count, n: n}
  end

  defp confusion(pairs, labels) do
    counts = Enum.frequencies(pairs)
    matrix = for human <- labels, do: for(judge <- labels, do: Map.get(counts, {human, judge}, 0))
    %{labels: labels, matrix: matrix}
  end

  defp dataset_hash(cases) do
    cases
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn c ->
      %{
        "id" => c.id,
        "input" => canonical_input(c.input),
        "output" => c.output,
        "reference" => c.reference,
        "human_label" => c.human_label,
        "annotator" => c.annotator,
        "split" => c.split,
        "group" => c.group,
        "provenance" => c.provenance
      }
    end)
    |> CanonicalJSON.hash()
  end

  defp canonical_input(text) when is_binary(text), do: text

  defp canonical_input(messages),
    do: Enum.map(messages, &%{"role" => Atom.to_string(&1.role), "content" => &1.content})

  # ── requirements ─────────────────────────────────────────────────────────

  @doc """
  Checks a stored calibration against a judge configuration and the
  `require_calibration` thresholds.

  `requirements` holds `:min_kappa` (κ at least this) and
  `:max_false_pass` (false-pass point estimate at most this); absent keys
  are not checked. Fails closed: `nil` result → `{:error, :missing}`, a
  result for another `fingerprint_id` → `{:error, :stale}`, an undefined κ
  or no human-failed holdout cases while a threshold needs them →
  `{:error, {:below_threshold, reason}}`.
  """
  @spec check(Result.t() | nil, String.t(), map() | keyword()) ::
          :ok | {:error, :missing | :stale | {:below_threshold, String.t()}}
  def check(nil, _fingerprint_id, _requirements), do: {:error, :missing}

  def check(%Result{fingerprint_id: id} = result, id, requirements) do
    requirements = Map.new(requirements)

    with :ok <- check_kappa(result, requirements[:min_kappa]) do
      check_false_pass(result, requirements[:max_false_pass])
    end
  end

  def check(%Result{}, _fingerprint_id, _requirements), do: {:error, :stale}

  defp check_kappa(_result, nil), do: :ok

  defp check_kappa(%Result{kappa: nil}, _min),
    do: {:error, {:below_threshold, "kappa is undefined on the holdout set"}}

  defp check_kappa(%Result{kappa: kappa}, min) when kappa >= min, do: :ok

  defp check_kappa(%Result{kappa: kappa}, min),
    do: {:error, {:below_threshold, "kappa #{round4(kappa)} < #{min}"}}

  defp check_false_pass(_result, nil), do: :ok

  defp check_false_pass(%Result{false_pass: nil}, _max),
    do: {:error, {:below_threshold, "no human-failed holdout cases to measure false passes on"}}

  defp check_false_pass(%Result{false_pass: %{estimate: rate}}, max) when rate <= max, do: :ok

  defp check_false_pass(%Result{false_pass: %{estimate: rate}}, max),
    do: {:error, {:below_threshold, "false-pass rate #{round4(rate)} > #{max}"}}

  # ── report ───────────────────────────────────────────────────────────────

  @doc "A plain-text report of `result`, as `mix nous.eval.judge.calibrate` prints it."
  @spec format(Result.t()) :: String.t()
  def format(%Result{} = r) do
    model = r.judge["model"]

    [
      "Judge calibration — #{model}",
      "  fingerprint   #{r.fingerprint_id}",
      "  dataset       #{r.dataset_hash}",
      "  cases         #{r.n_cases} (tune #{r.n_tune}, holdout #{r.n_holdout}; " <>
        "scored #{r.n_scored}, judge errors #{r.n_errors})",
      "",
      "Holdout",
      "  agreement     #{format_interval(r.agreement)}",
      "  kappa         #{format_kappa(r)}",
      "  false pass    #{format_interval(r.false_pass)}  (human fail, judge pass)",
      "  error rate    #{format_interval(r.error_rate)}",
      "",
      "Confusion (rows: human, columns: judge)",
      format_confusion(r.confusion)
      | format_errors(r.errors)
    ]
    |> Enum.join("\n")
  end

  defp format_interval(nil), do: "n/a"

  defp format_interval(%{estimate: e, ci: {lo, hi}, count: count, n: n}),
    do: "#{pct(e)} (#{count}/#{n}, 95% CI #{pct(lo)}–#{pct(hi)})"

  defp format_kappa(%Result{kappa: nil}), do: "undefined"

  defp format_kappa(%Result{kappa: k, kappa_kind: :cohen}), do: "#{round4(k)} (Cohen)"

  defp format_kappa(%Result{kappa: k, kappa_kind: :quadratic_weighted}),
    do: "#{round4(k)} (quadratic-weighted)"

  defp format_confusion(%{labels: labels, matrix: matrix}) do
    width = Enum.max([6 | Enum.map(labels, &String.length/1)]) + 2
    header = String.duplicate(" ", width) <> Enum.map_join(labels, &String.pad_leading(&1, width))

    rows =
      Enum.zip_with(labels, matrix, fn label, row ->
        String.pad_trailing("  " <> label, width) <>
          Enum.map_join(row, &String.pad_leading(Integer.to_string(&1), width))
      end)

    Enum.join([header | rows], "\n")
  end

  defp format_errors([]), do: []

  defp format_errors(errors) do
    ["", "Judge errors" | Enum.map(errors, &"  #{&1.case_id}: #{&1.kind} #{&1.reason}")]
  end

  defp pct(x), do: :erlang.float_to_binary(x * 100, decimals: 1) <> "%"
  defp round4(x), do: Float.round(x / 1, 4)

  # ── helpers ──────────────────────────────────────────────────────────────

  defp parse_all(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp label_error({:error, message}, label), do: {:error, "#{label}: #{message}"}
  defp label_error(ok, _label), do: ok

  defp prefix_error({:error, message}, path), do: {:error, "#{path}: #{message}"}
  defp prefix_error(ok, _path), do: ok
end

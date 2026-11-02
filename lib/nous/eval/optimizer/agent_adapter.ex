defmodule Nous.Eval.Optimizer.AgentAdapter do
  @moduledoc """
  The default `Nous.Eval.Optimizer.Adapter`: evaluates a candidate profile
  by running the eval task with `Nous.Eval.run/2`, the candidate applied to
  every agent the task builds (`profile:`) and the batch selected by case id
  (`cases:`).

  ## Options (`adapter: {Nous.Eval.Optimizer.AgentAdapter, opts}`)

    * `:parallelism`, `:timeout`, `:scorer_timeout`, `:max_trace_events`,
      `:max_trace_bytes` - passed to every `Nous.Eval.run/2`

  `k`, the seed and the budget of each evaluation come from the optimizer.

  ## The reference agent

  `c:Nous.Eval.Optimizer.Adapter.agent/1` is the agent the task builds for its first case (sample 0,
  no seed), with the task's `setup/1` state and deps; `setup/1` and
  `teardown/1` run around building it. Profiles are sealed against it, so
  a task whose agents differ in base text between cases cannot be
  optimized as one profile: such a profile fails to apply (`:stale`) and
  the affected samples are errors.

  ## Reflective records

  One record per train case, from its lowest-scoring sample (ties: lowest
  index): the case input, the agent's output or error, the tool calls of
  the trace and one feedback entry per score. A case whose samples all have
  scorer errors yields no record: the reflector must not learn from a
  broken instrument.

  Under `:diagnostic` a feedback entry carries the scorer's name, `passed?`,
  value and reason, the paths of mismatched arguments or output fields
  (never the expected values), the names of expected tools that were not
  called, and a judge's critique. A reason or critique that quotes the
  case's `expected` values or a scorer option (a rubric, a reference, the
  phrases a `Contains` looks for) is withheld (`"withheld (quotes the
  expected answer or a rubric)"`). Under `:with_expected` the record of a
  train case also carries its `expected` map, and only scorer-option quotes
  (rubrics) are withheld.
  """

  @behaviour Nous.Eval.Optimizer.Adapter

  alias Nous.Eval.{Case, Run, Sample, Score, Trace}
  alias Nous.Eval.Optimizer.Evaluation
  alias Nous.Eval.Runner
  alias Nous.Eval.Task, as: EvalTask

  @run_option_keys [:parallelism, :timeout, :scorer_timeout, :max_trace_events, :max_trace_bytes]

  # Shortest option or expected string treated as a secret a reason or
  # critique may not quote; shorter ones ("a", "ok") would withhold
  # everything.
  @min_secret_bytes 4
  @withheld "withheld (quotes the expected answer or a rubric)"

  @impl true
  def init(task_module, opts) when is_list(opts) do
    {run_opts, rest} = Keyword.split(opts, @run_option_keys)

    with :ok <- no_unknown(rest),
         {:ok, task} <- EvalTask.load(task_module),
         {:ok, agent} <- reference_agent(task) do
      # Once per optimization: each evaluation's run has the warning off.
      Runner.warn_implicit_threshold(task.dataset.cases, task.scorers)

      {:ok,
       %{
         module: task_module,
         cases: task.dataset.cases,
         agent: agent,
         task_scorers: task.scorers,
         run_opts: run_opts
       }}
    end
  end

  defp no_unknown([]), do: :ok
  defp no_unknown(rest), do: {:error, {:unknown_adapter_options, Keyword.keys(rest)}}

  defp reference_agent(%EvalTask{dataset: %{cases: []}}), do: {:error, :no_cases}

  defp reference_agent(%EvalTask{dataset: %{cases: [first | _]}} = task) do
    with {:ok, state} <- EvalTask.setup(task, []) do
      try do
        with {:ok, deps} <- EvalTask.deps(task, state) do
          EvalTask.agent(task, %{case: first, sample: 0, seed: nil, deps: deps, state: state})
        end
      after
        EvalTask.teardown(task, state)
      end
    end
  end

  @impl true
  def cases(%{cases: cases}), do: cases

  @impl true
  def agent(%{agent: agent}), do: agent

  @impl true
  def evaluate(state, %Nous.Profile{} = profile, batch) do
    opts =
      [
        cases: batch.case_ids,
        profile: profile,
        k: batch.k,
        seed: batch.seed,
        budget: batch.budget,
        metadata: %{
          "optimizer" => %{"split" => batch.split, "profile_id" => profile.id}
        },
        warn_implicit_threshold: false
      ] ++ state.run_opts

    with {:ok, %Run{} = run} <- Nous.Eval.run(state.module, opts) do
      cases = Map.new(state.cases, &{&1.id, &1})
      batch_cases = Map.take(cases, batch.case_ids)

      {:ok,
       %Evaluation{
         profile_id: profile.id,
         split: batch.split,
         case_ids: batch.case_ids,
         scores: scores(run, batch.case_ids),
         status: run.status,
         feedback: batch.feedback,
         cases: batch_cases,
         run: run,
         metric_calls: run.budget.spent.samples,
         tokens: run.budget.spent.tokens,
         cost: run.budget.spent.cost,
         private: %{secrets: Map.new(batch_cases, fn {id, c} -> {id, secrets(c, state)} end)}
       }}
    end
  end

  # Mean gated case score per case; an error or an unscored sample is 0.0.
  defp scores(%Run{samples: samples}, case_ids) do
    by_case = Enum.group_by(samples, & &1.case_id)

    Map.new(case_ids, fn id ->
      values = by_case |> Map.get(id, []) |> Enum.map(&sample_score/1)
      {id, if(values == [], do: 0.0, else: Enum.sum(values) / length(values))}
    end)
  end

  defp sample_score(%Sample{case_score: score}) when is_number(score), do: score / 1
  defp sample_score(%Sample{}), do: 0.0

  # Text a reason or critique must not quote: the case's expected values
  # (`:expected`) and every string in its scorers' options (`:options`:
  # rubrics, references, phrases, patterns).
  defp secrets(%Case{} = c, state) do
    specs = state.task_scorers ++ c.scorers

    %{
      expected: c.expected |> strings() |> long_enough(),
      options: specs |> Enum.flat_map(&strings(&1.opts)) |> long_enough()
    }
  end

  defp long_enough(strings),
    do: strings |> Enum.filter(&(byte_size(String.trim(&1)) >= @min_secret_bytes)) |> Enum.uniq()

  defp strings(value) when is_binary(value), do: [value]
  defp strings(%Regex{} = regex), do: [Regex.source(regex)]
  defp strings(%{__struct__: _}), do: []
  defp strings(%{} = map), do: Enum.flat_map(map, fn {k, v} -> strings(k) ++ strings(v) end)
  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> strings()
  defp strings(_other), do: []

  # ── reflective records ─────────────────────────────────────────────────

  @impl true
  def reflective_records(%Evaluation{split: "train"} = evaluation, component_keys)
      when is_list(component_keys) do
    records =
      evaluation.case_ids
      |> Enum.flat_map(&record(evaluation, &1))

    Map.new(component_keys, &{&1, records})
  end

  def reflective_records(%Evaluation{split: split}, _component_keys) do
    raise ArgumentError,
          "reflective records come from train evaluations only, got split #{inspect(split)}"
  end

  defp record(evaluation, case_id) do
    c = Map.fetch!(evaluation.cases, case_id)

    samples =
      for %Sample{case_id: ^case_id, scorer_errors: [], outcome: outcome} = s <-
            evaluation.run.samples,
          outcome != :budget_exhausted,
          do: s

    case Enum.sort_by(samples, &{sample_score(&1), &1.index}) do
      [] ->
        []

      [worst | _] ->
        secrets =
          Map.get(evaluation.private[:secrets] || %{}, case_id, %{expected: [], options: []})

        withhold =
          if evaluation.feedback == :with_expected,
            do: secrets.options,
            else: secrets.options ++ secrets.expected

        record = %{
          case_id: case_id,
          score: Map.fetch!(evaluation.scores, case_id),
          inputs: input_text(c.input),
          outputs: output_text(worst),
          tool_calls: tool_calls(worst),
          feedback: Enum.map(worst.scores, &feedback(&1, withhold))
        }

        if evaluation.feedback == :with_expected and c.split == "train",
          do: [Map.put(record, :expected, c.expected)],
          else: [record]
    end
  end

  defp input_text(text) when is_binary(text), do: text

  defp input_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", fn message ->
      "#{message.role}: #{Nous.Message.extract_text(message)}"
    end)
  end

  # A simulated case: the user the simulator played (never `expected`).
  defp input_text(%Nous.Eval.Simulator.Scenario{} = scenario),
    do: Nous.Eval.Simulator.describe(scenario)

  defp output_text(%Sample{outcome: :ok, output: output}) when is_binary(output), do: output

  # A simulated episode: the conversation, without the simulator's reasoning.
  defp output_text(%Sample{outcome: :ok, output: %{"schema" => "nous.sim_episode/1"} = episode}),
    do: "(#{episode["termination"]})\n" <> Nous.Eval.Simulator.transcript_text(episode)

  defp output_text(%Sample{outcome: :ok, output: output}), do: inspect(output, limit: 50)

  defp output_text(%Sample{outcome: outcome, error: error}),
    do: "(run #{outcome}) #{error || ""}"

  defp tool_calls(%Sample{trace: %Trace{} = trace}) do
    trace
    |> Trace.tool_calls()
    |> Enum.map(fn call ->
      %{
        name: call.name,
        arguments: encode(call.arguments),
        outcome: call.outcome,
        result: if(call.error, do: encode(call.error), else: encode(call.result))
      }
    end)
  end

  defp tool_calls(%Sample{}), do: []

  defp encode(nil), do: ""
  defp encode(text) when is_binary(text), do: text

  defp encode(value) do
    JSON.encode!(value)
  rescue
    _ -> inspect(value, limit: 50)
  end

  defp feedback(%Score{} = score, withhold) do
    %{
      scorer: score.name,
      passed?: score.passed?,
      value: value(score.value),
      reason: guard_text(score.reason, withhold),
      paths: paths(score.details),
      missing_tools: missing_tools(score.details),
      critique: guard_text(critique(score.details), withhold)
    }
  end

  defp value(:pass), do: 1.0
  defp value(:fail), do: 0.0
  defp value({:label, label}), do: label
  defp value(number) when is_number(number), do: number / 1

  defp guard_text(nil, _secrets), do: nil

  defp guard_text(text, secrets) when is_binary(text) do
    folded = String.downcase(text)

    if Enum.any?(secrets, &quotes?(folded, &1)), do: @withheld, else: text
  end

  defp guard_text(_other, _secrets), do: nil

  # A secret is quoted when the text contains it (case-insensitively), or,
  # for a long secret such as a rubric, any 40-character run of it.
  defp quotes?(folded, secret) do
    secret = String.downcase(secret)

    if String.length(secret) <= 40 do
      String.contains?(folded, secret)
    else
      graphemes = String.graphemes(secret)

      graphemes
      |> Enum.chunk_every(40, 10, :discard)
      |> Enum.any?(&String.contains?(folded, Enum.join(&1)))
    end
  end

  defp critique(%{critique: critique}) when is_binary(critique), do: critique
  defp critique(_details), do: nil

  # Paths only, never the expected values: `Equals` (`paths`), `ToolArgs`
  # (`mismatches`), `Trajectory` (`arg_mismatches`).
  defp paths(details) when is_map(details) do
    direct = List.wrap(details[:paths])

    nested =
      for key <- [:mismatches, :arg_mismatches],
          %{} = entry <- List.wrap(details[key]),
          path <- List.wrap(entry[:paths]),
          do: path

    (direct ++ nested) |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp paths(_details), do: []

  defp missing_tools(%{missing: missing}) when is_list(missing) do
    for %{} = entry <- missing, name = entry[:name], is_binary(name), uniq: true, do: name
  end

  defp missing_tools(_details), do: []
end

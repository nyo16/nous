defmodule Mix.Tasks.Nous.Eval.Compare do
  @shortdoc "Compares two stored eval runs and gates the second against the first"

  @moduledoc """
  Compares a candidate eval run with a baseline run from the store
  (`Nous.Eval.Compare`) and prints the comparison.

      mix nous.eval.compare baseline:main 20261101t153012z-1a2b3c4d
      mix nous.eval.compare RUN_A RUN_B --gate pass_rate,scorer:trajectory --margin 0.02

  `RUN_A` is the baseline and `RUN_B` the candidate; each is a run id or
  `baseline:LABEL` (the run a baseline label points at).

  ## Options

    * `--store SPEC` - `file:DIR` (default `file:.nous/eval`),
      `sqlite:PATH` or `duckdb:PATH`
    * `--gate METRICS` - comma-separated gate metrics: `pass_rate`
      (default), `case_score`, `scorer:NAME`
    * `--margin F` - tolerated drop, in `[0, 1)` (default 0.0)
    * `--max-error-rate F` - tolerated share of `:error` samples in the
      candidate, in `[0, 1)` (default 0.0)
    * `--allow-dataset-change` - compare runs of different datasets on
      their common case ids
    * `--task MODULE` - the task the runs came from, for the per-tag
      breakdown (optional)
    * `--format FORMAT` - `console` (default), `markdown` or `json`
    * `--output PATH` - write the report there instead of printing it

  ## Exit status

  0 when the candidate passes the gate, 1 on a regression, 2 on an
  operational error: bad arguments, a run or label not found, runs of
  different datasets without `--allow-dataset-change`, a candidate that was
  aborted, exhausted its budget or has more scorer errors than
  `--max-error-rate`, or a comparison that cannot decide (see
  `Mix.Tasks.Nous.Eval`).
  """

  use Mix.Task

  alias Nous.Eval.{CLI, Compare}

  @switches [
    store: :string,
    gate: :string,
    margin: :float,
    max_error_rate: :float,
    allow_dataset_change: :boolean,
    task: :string,
    format: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.finish("nous.eval.compare", execute(argv))
  end

  defp execute(argv) do
    with {:ok, opts, refs} <- CLI.parse(argv, @switches),
         {:ok, baseline_ref, candidate_ref} <- refs(refs),
         {:ok, format} <- CLI.format(opts[:format]),
         {:ok, gate} <- CLI.gate(opts),
         {:ok, cases} <- cases(opts[:task]),
         {:ok, store} <- CLI.open_store(opts[:store]),
         {:ok, baseline} <- CLI.fetch_run(store, baseline_ref),
         {:ok, candidate} <- CLI.fetch_run(store, candidate_ref),
         {:ok, comparison} <- compare(baseline, candidate, gate, cases, opts),
         :ok <- CLI.emit([comparison], format, opts[:output]) do
      {:ok, CLI.exit_code(candidate, comparison, gate.max_error_rate)}
    end
  end

  defp refs([baseline, candidate]), do: {:ok, baseline, candidate}
  defp refs(_), do: {:error, "expected two runs: RUN_A (baseline) RUN_B (candidate)"}

  defp cases(nil), do: {:ok, nil}

  defp cases(name) do
    with {:ok, module} <- CLI.task_module(name),
         {:ok, task} <- Nous.Eval.Task.load(module) do
      {:ok, task.dataset.cases}
    end
  end

  defp compare(baseline, candidate, gate, cases, opts) do
    compare_opts =
      [gate: gate, allow_dataset_change: Keyword.get(opts, :allow_dataset_change, false)] ++
        if(cases, do: [cases: cases], else: [])

    case Compare.compare(baseline, candidate, compare_opts) do
      {:ok, comparison} -> {:ok, comparison}
      {:error, reason} -> {:error, "cannot compare: " <> CLI.describe(reason)}
    end
  end
end

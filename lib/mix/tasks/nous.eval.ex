defmodule Mix.Tasks.Nous.Eval do
  @shortdoc "Runs an eval task, stores the run and gates it against a baseline"

  @moduledoc """
  Runs a `Nous.Eval` task (`Nous.Eval.run/2`), stores the run, prints its
  report and, with `--baseline`, compares it with a stored baseline run
  (`Nous.Eval.Compare`).

      mix nous.eval --task MyApp.Evals.Refunds --k 3 --seed 42
      mix nous.eval --task MyApp.Evals.Refunds --set-baseline main
      mix nous.eval --task MyApp.Evals.Refunds --baseline main --gate pass_rate,scorer:judge

  ## Options

    * `--task MODULE` - the task module (required); it must be compiled into
      the project
    * `--k N` - samples per case (default 3)
    * `--split SPLITS` - comma-separated: `train`, `val`, `test`
    * `--tag TAG` - run only cases with this tag; repeatable, or
      comma-separated
    * `--seed N` - base seed; each sample's seed is derived from it
    * `--parallelism N` - samples in flight (default: schedulers online)
    * `--timeout MS` - per-sample limit (default 120000)
    * `--budget-cost USD`, `--budget-tokens N`, `--budget-samples N` - run
      budget (see "Budgets" in `Nous.Eval.run/2`). `--budget-cost` refuses
      to start when a model has no known price
    * `--store SPEC` - `file:DIR` (default `file:.nous/eval`),
      `sqlite:PATH` or `duckdb:PATH`. The run is stored there, and LLM
      judges look up the calibration `mix nous.eval.judge.calibrate` stored
      there (`require_calibration`)
    * `--baseline LABEL` - compare against the run the label points at
      (checked before the eval starts)
    * `--gate METRICS` - comma-separated gate metrics: `pass_rate`
      (default), `case_score`, `scorer:NAME`
    * `--margin F` - tolerated drop, in `[0, 1)` (default 0.0)
    * `--max-error-rate F` - tolerated share of `:error` samples, in
      `[0, 1)` (default 0.0)
    * `--allow-dataset-change` - compare with a baseline of a different
      dataset on the common case ids
    * `--format FORMAT` - `console` (default), `markdown` or `json`. With a
      baseline, `json` prints the comparison (which holds both summaries)
    * `--output PATH` - write the report there instead of printing it
    * `--set-baseline LABEL` - point the label at this run, only when the
      exit status is 0

  ## Exit status

  | Status | Meaning |
  |---|---|
  | 0 | pass: the run completed, its scorer error rate is within `--max-error-rate`, and (with `--baseline`) no gate metric regressed |
  | 1 | regression: a gate metric dropped by more than `--margin` with significance (see `Nous.Eval.Compare`) |
  | 2 | operational error: bad arguments, unknown task, no cases selected, store failure, budget refused (unknown price) or exhausted, aborted run, scorer error rate above `--max-error-rate`, or a comparison that cannot decide |

  A run that exhausted its budget exits 2 even if its finished samples
  passed: the unrun cases were never checked, and a gate must not pass on
  partial results.

  ## CI

      mix nous.eval --task MyApp.Evals.Refunds --seed 1 --budget-cost 2.00 \\
        --baseline main --format markdown --output eval-report.md

  On the main branch, refresh the baseline with `--set-baseline main` (or
  `mix nous.eval.baseline set RUN main`).
  """

  use Mix.Task

  alias Nous.Eval.{CLI, Compare}

  @switches [
    task: :string,
    k: :integer,
    split: :string,
    tag: [:string, :keep],
    seed: :integer,
    parallelism: :integer,
    timeout: :integer,
    budget_cost: :float,
    budget_tokens: :integer,
    budget_samples: :integer,
    store: :string,
    baseline: :string,
    gate: :string,
    margin: :float,
    max_error_rate: :float,
    allow_dataset_change: :boolean,
    format: :string,
    output: :string,
    set_baseline: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.finish("nous.eval", execute(argv))
  end

  defp execute(argv) do
    with {:ok, opts, []} <- parse(argv),
         {:ok, module} <- CLI.task_module(opts[:task]),
         {:ok, task} <- Nous.Eval.Task.load(module),
         {:ok, format} <- CLI.format(opts[:format]),
         {:ok, gate} <- CLI.gate(opts),
         {:ok, splits} <- CLI.splits(opts[:split]),
         {:ok, label} <- CLI.label(opts[:set_baseline], "--set-baseline"),
         {:ok, store} <- CLI.open_store(opts[:store]),
         {:ok, baseline} <- baseline(store, opts[:baseline]),
         {:ok, run} <- eval(module, opts, splits, store),
         :ok <- CLI.stored(store, run),
         {:ok, comparison} <- compare(baseline, run, task, gate, opts),
         :ok <- CLI.emit(subjects(run, comparison, format), format, opts[:output]) do
      code = CLI.exit_code(run, comparison, gate.max_error_rate)
      with :ok <- maybe_set_baseline(store, label, run, code), do: {:ok, code}
    end
  end

  defp parse(argv) do
    case CLI.parse(argv, @switches) do
      {:ok, opts, []} -> {:ok, opts, []}
      {:ok, _opts, [arg | _]} -> {:error, "unexpected argument #{inspect(arg)}"}
      error -> error
    end
  end

  defp baseline(_store, nil), do: {:ok, nil}
  defp baseline(store, label), do: CLI.baseline_run(store, label)

  defp eval(module, opts, splits, store) do
    run_opts =
      [
        k: opts[:k],
        seed: opts[:seed],
        parallelism: opts[:parallelism],
        timeout: opts[:timeout],
        splits: splits,
        tags: CLI.tags(opts),
        budget: CLI.budget(opts),
        store: CLI.run_store(store)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Nous.Eval.run(module, run_opts) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, CLI.describe(reason)}
    end
  end

  defp compare(nil, _run, _task, _gate, _opts), do: {:ok, nil}

  defp compare(baseline, run, task, gate, opts) do
    case Compare.compare(baseline, run,
           gate: gate,
           cases: task.dataset.cases,
           allow_dataset_change: Keyword.get(opts, :allow_dataset_change, false)
         ) do
      {:ok, comparison} -> {:ok, comparison}
      {:error, reason} -> {:error, "cannot compare with the baseline: " <> CLI.describe(reason)}
    end
  end

  defp subjects(run, nil, _format), do: [run]
  defp subjects(_run, comparison, :json), do: [comparison]
  defp subjects(run, comparison, _format), do: [run, comparison]

  defp maybe_set_baseline(_store, nil, _run, _code), do: :ok
  defp maybe_set_baseline(store, label, run, 0), do: CLI.set_baseline(store, label, run.id)

  defp maybe_set_baseline(_store, label, _run, _code) do
    Mix.shell().error("Baseline #{label} not updated: the run did not pass")
  end
end

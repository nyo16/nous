defmodule Mix.Tasks.Nous.Eval.Rescore do
  @shortdoc "Re-scores a stored eval run with the task's current scorers"

  @moduledoc """
  Scores the samples of a stored run again with the task's current scorers,
  without running the agent (`Nous.Eval.rescore/3`), and stores the result
  as a new run.

      mix nous.eval.rescore 20261101t153012z-1a2b3c4d
      mix nous.eval.rescore baseline:main --task MyApp.Evals.Refunds

  Use it after changing a scorer, an expected value or a threshold: the
  outputs and traces are reused, only the verdicts change. The new run has
  a new id, `metadata.rescored_from` set to the source run's id, and a
  fingerprint whose `"scorers"` and `"dataset"` describe the current task.
  Model-graded scorers (an LLM judge) are called again.

  ## Options

    * `--task MODULE` - the task whose scorers to use (default: the task
      recorded on the run)
    * `--store SPEC` - `file:DIR` (default `file:.nous/eval`),
      `sqlite:PATH` or `duckdb:PATH`; the new run is stored there too, and
      LLM judges look up their stored calibration there
    * `--parallelism N` - samples scored at once (default: schedulers online)
    * `--scorer-timeout MS` - per-scorer limit
    * `--budget-cost USD`, `--budget-tokens N` - bound what model-graded
      scorers spend (see `Nous.Eval.rescore/3`)
    * `--max-error-rate F` - tolerated share of `:error` samples, in
      `[0, 1)` (default 0.0)
    * `--format FORMAT` - `console` (default), `markdown` or `json`
    * `--output PATH` - write the report there instead of printing it

  ## Exit status

  0 when the re-scored run has no more scorer errors than tolerated, 2 on an
  operational error (bad arguments, run not found, a case missing from the
  task, store failure, budget refused or exhausted, a source run that was
  aborted or exhausted its budget, scorer errors above `--max-error-rate`).
  Compare the new run with `mix nous.eval.compare`.
  """

  use Mix.Task

  alias Nous.Eval.CLI

  @switches [
    task: :string,
    store: :string,
    parallelism: :integer,
    scorer_timeout: :integer,
    budget_cost: :float,
    budget_tokens: :integer,
    max_error_rate: :float,
    format: :string,
    output: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.finish("nous.eval.rescore", execute(argv))
  end

  defp execute(argv) do
    with {:ok, opts, args} <- CLI.parse(argv, @switches),
         {:ok, ref} <- ref(args),
         {:ok, format} <- CLI.format(opts[:format]),
         {:ok, gate} <- CLI.gate(Keyword.take(opts, [:max_error_rate])),
         {:ok, store} <- CLI.open_store(opts[:store]),
         {:ok, source} <- CLI.fetch_run(store, ref),
         {:ok, module} <- CLI.task_module(opts[:task] || source.task),
         {:ok, run} <- rescore(source, module, opts, store),
         :ok <- CLI.stored(store, run),
         :ok <- CLI.emit([run], format, opts[:output]) do
      Mix.shell().info("Re-scored #{source.id} as #{run.id}")
      {:ok, CLI.exit_code(run, nil, gate.max_error_rate)}
    end
  end

  defp ref([ref]), do: {:ok, ref}
  defp ref(_), do: {:error, "expected one run: RUN (an id or baseline:LABEL)"}

  defp rescore(source, module, opts, store) do
    rescore_opts =
      [
        parallelism: opts[:parallelism],
        scorer_timeout: opts[:scorer_timeout],
        budget: CLI.budget(opts),
        store: CLI.run_store(store)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Nous.Eval.rescore(source, module, rescore_opts) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, CLI.describe(reason)}
    end
  end
end

defmodule Mix.Tasks.Nous.Eval.Baseline do
  @shortdoc "Sets, shows or lists the history of an eval baseline label"

  @moduledoc """
  Manages baseline labels in an eval store (see "Baselines" in
  `Nous.Eval.Store`).

      mix nous.eval.baseline set 20261101t153012z-1a2b3c4d main
      mix nous.eval.baseline show main
      mix nous.eval.baseline history main

    * `set RUN LABEL` - point `LABEL` at the stored run `RUN`. Labels are
      append-only: the previous target stays in the history
    * `show LABEL` - the run the label points at, with its status and pass
      rate
    * `history LABEL` - every entry of the label, newest first

  `mix nous.eval --baseline LABEL` gates a new run against the label's run.

  ## Options

    * `--store SPEC` - `file:DIR` (default `file:.nous/eval`),
      `sqlite:PATH` or `duckdb:PATH`

  Exits with status 2 on an operational error (bad arguments, unknown run
  or label, store failure).
  """

  use Mix.Task

  alias Nous.Eval.{CLI, Reporter}

  @switches [store: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    CLI.finish("nous.eval.baseline", execute(argv))
  end

  defp execute(argv) do
    with {:ok, opts, args} <- CLI.parse(argv, @switches),
         {:ok, command} <- command(args),
         {:ok, store} <- CLI.open_store(opts[:store]),
         :ok <- perform(command, store) do
      {:ok, 0}
    end
  end

  defp command(["set", run_id, label]) do
    with {:ok, label} <- CLI.label(label, "LABEL"), do: {:ok, {:set, run_id, label}}
  end

  defp command(["show", label]) do
    with {:ok, label} <- CLI.label(label, "LABEL"), do: {:ok, {:show, label}}
  end

  defp command(["history", label]) do
    with {:ok, label} <- CLI.label(label, "LABEL"), do: {:ok, {:history, label}}
  end

  defp command(_args),
    do: {:error, "expected: set RUN LABEL | show LABEL | history LABEL"}

  defp perform({:set, run_id, label}, store) do
    with {:ok, _run} <- CLI.fetch_run(store, run_id), do: CLI.set_baseline(store, label, run_id)
  end

  defp perform({:show, label}, {module, state, spec} = store) do
    with {:ok, entry} <- entry(module, state, spec, label),
         {:ok, run} <- CLI.fetch_run(store, entry.run_id) do
      pass_rate = get_in(run.summary, ["pass_rate", "estimate"])

      Mix.shell().info("""
      #{label} -> #{run.id} (set #{DateTime.to_iso8601(entry.set_at)})
        task: #{run.task}
        status: #{run.status}
        started: #{run.started_at && DateTime.to_iso8601(run.started_at)}
        samples: #{length(run.samples)}, k #{run.k}
        pass rate: #{Reporter.pct(pass_rate)}
        fingerprint: #{run.fingerprint["id"]}\
      """)
    end
  end

  defp perform({:history, label}, {module, state, spec}) do
    case module.list_baselines(state, label) do
      {:ok, []} ->
        {:error, "baseline #{inspect(label)} is not set in #{spec}"}

      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          Mix.shell().info("#{DateTime.to_iso8601(entry.set_at)}  #{label} -> #{entry.run_id}")
        end)

      {:error, reason} ->
        {:error, "cannot read baseline #{label}: #{CLI.describe(reason)}"}
    end
  end

  defp entry(module, state, spec, label) do
    case module.get_baseline(state, label) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, "baseline #{inspect(label)} is not set in #{spec}"}
      {:error, reason} -> {:error, "cannot read baseline #{label}: #{CLI.describe(reason)}"}
    end
  end
end

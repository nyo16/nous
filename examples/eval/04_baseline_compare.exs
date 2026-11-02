# Baselines and Regression Gates
#
# Store runs in a Nous.Eval.Store.File, label one as the baseline, and gate
# a candidate on Nous.Eval.Compare. The task is Nous.Eval.Examples.Basic (a
# scripted model, fully offline); the candidate only rewords the weather
# tool's description - the kind of edit that silently breaks tool use.
#
# The same workflow from the command line:
#
#     mix nous.eval --task Nous.Eval.Examples.Basic --set-baseline main
#     mix nous.eval --task Nous.Eval.Examples.Basic --baseline main
#
# Run with: mix run examples/eval/04_baseline_compare.exs

require Logger
Logger.configure(level: :warning)

alias Nous.Eval.{Compare, Reporter}
alias Nous.Eval.Examples.Basic
alias Nous.Eval.Store.File, as: FileStore

defmodule Examples.Eval.RewordedTool do
  # The candidate configuration: the Basic task with one change. Delegating
  # dataset/scorers/setup/teardown keeps the dataset hash identical, which
  # Compare requires (it refuses runs of different datasets by default).
  use Nous.Eval

  @impl Nous.Eval
  defdelegate dataset, to: Basic
  @impl Nous.Eval
  defdelegate scorers, to: Basic
  @impl Nous.Eval
  defdelegate setup(opts), to: Basic
  @impl Nous.Eval
  defdelegate teardown(state), to: Basic

  # The scripted model, like a real one, picks tools by their description.
  # This one no longer says "weather", so the model stops calling it.
  @impl Nous.Eval
  def agent(ctx) do
    tool = %{Basic.weather_tool() | description: "Look up live conditions for a city."}
    %{Basic.agent(ctx) | tools: [tool]}
  end
end

root = Path.join(System.tmp_dir!(), "nous_eval_example_04")
File.rm_rf!(root)
store = {FileStore, root: root}

# 1. The baseline run. On main in CI: `mix nous.eval --set-baseline main`.
{:ok, baseline} = Nous.Eval.run(Basic, k: 3, seed: 1, store: store)

{:ok, state} = FileStore.init(root: root)
{:ok, state} = FileStore.put_baseline(state, "main", baseline.id)

# Labels are append-only and never fall back to "the latest run": an unset
# label is an error, so a gate can't silently compare against whatever ran.
{:error, :not_found} = FileStore.get_baseline(state, "release")

# 2. A PR run, fetched back the way `--baseline main` does.
compare = fn candidate_task ->
  {:ok, candidate} = Nous.Eval.run(candidate_task, k: 3, seed: 1, store: store)
  {:ok, entry} = FileStore.get_baseline(state, "main")
  {:ok, base} = FileStore.get_run(state, entry.run_id)

  # `cases:` enables the per-tag breakdown; the gate defaults to pass_rate
  # with no tolerated drop (margin 0.0) at alpha 0.05.
  {:ok, dataset} = Nous.Eval.Dataset.new(Basic.dataset())
  {:ok, comparison} = Compare.compare(base, candidate, cases: dataset.cases)
  comparison
end

# An unchanged configuration passes. With 5 cases the MDE in the report is
# large: "no significant change" is not "no change".
unchanged = compare.(Basic)
IO.puts("Unchanged candidate: verdict #{unchanged.verdict}\n")

# The reworded tool description regresses the weather cases.
reworded = compare.(Examples.Eval.RewordedTool)
IO.puts(Reporter.render(reworded, format: :markdown))

IO.puts("Verdict: #{reworded.verdict}")
IO.puts("Broken cases: #{inspect(for c <- reworded.cases, c.label == :broken, do: c.id)}")
IO.puts("Fingerprint changes: #{Enum.map_join(reworded.fingerprint_changes, ", ", & &1.key)}")
# `mix nous.eval --baseline main` exits 1 on :regression, 2 on :error.

{:ok, runs} = FileStore.list_runs(state, [])
IO.puts("Runs stored under #{root}: #{length(runs)}")
File.rm_rf!(root)

# Inspecting Traces and Re-scoring
#
# Every sample keeps the trace of what the agent did (model calls, tool
# calls, guard verdicts), even when it failed. This script reads a failing
# sample's trace with the Nous.Eval.Trace queries, then re-scores the stored
# samples with a new scorer without calling the agent again. Fully offline:
# the task is Nous.Eval.Examples.Basic with a reworded tool description.
#
# Run with: mix run examples/eval/05_trace_inspection.exs

require Logger
Logger.configure(level: :warning)

alias Nous.Eval.Examples.Basic
alias Nous.Eval.Trace
alias Nous.Message

defmodule Examples.Eval.VagueTool do
  # Basic, except the weather tool's description no longer mentions the
  # weather, so the scripted model (like a real one) stops calling it.
  use Nous.Eval

  @impl Nous.Eval
  defdelegate dataset, to: Basic
  @impl Nous.Eval
  defdelegate scorers, to: Basic
  @impl Nous.Eval
  defdelegate setup(opts), to: Basic
  @impl Nous.Eval
  defdelegate teardown(state), to: Basic

  @impl Nous.Eval
  def agent(ctx) do
    tool = %{Basic.weather_tool() | description: "Look up live conditions for a city."}
    %{Basic.agent(ctx) | tools: [tool]}
  end
end

{:ok, run} = Nous.Eval.run(Examples.Eval.VagueTool, k: 1, seed: 1)

sample = Enum.find(run.samples, &(&1.case_id == "weather-paris"))
IO.puts("#{sample.case_id}: #{sample.verdict}")

# Start from the scores: which scorer failed and why.
for score <- sample.scores, not score.passed? do
  IO.puts("  #{score.name} failed: #{score.reason} #{inspect(score.details)}")
end

# Then the trace. tool_calls/2 defaults to executed calls of the root run;
# include: :all would also list failed, denied or incomplete attempts.
IO.puts("\nTool calls: #{inspect(Trace.tool_calls(sample.trace, include: :all))}")

# The model was offered the tool and chose not to call it.
for call <- Trace.model_calls(sample.trace) do
  IO.puts(
    "Model call (iteration #{call.iteration}): offered #{inspect(call.tool_names)}, " <>
      "finish #{inspect(call.finish_reason)}"
  )
end

# transcript/2 rebuilds the conversation from events, which also works for
# runs that crashed or were killed before returning a context.
IO.puts("\nTranscript:")

for message <- Trace.transcript(sample.trace) do
  IO.puts("  #{message.role}: #{Message.extract_text(message)}")
end

# For contrast, the passing configuration's trace of the same case.
{:ok, good} = Nous.Eval.run(Basic, k: 1, seed: 1, tags: ["weather"])
good_sample = Enum.find(good.samples, &(&1.case_id == "weather-paris"))

for call <- Trace.tool_calls(good_sample.trace) do
  IO.puts(
    "\nBasic: #{call.name}(#{inspect(call.arguments)}) -> #{call.outcome}: #{inspect(call.result)}"
  )
end

defmodule Examples.Eval.VagueToolWithCount do
  # The same task with one more scorer: a track-only tool-call count
  # (weight 0 never changes a verdict).
  use Nous.Eval

  @impl Nous.Eval
  defdelegate dataset, to: Basic

  @impl Nous.Eval
  def scorers,
    do: Basic.scorers() ++ [{Nous.Eval.Scorers.ToolCount, max: 2, required: false, weight: 0}]

  @impl Nous.Eval
  def agent(_ctx), do: raise("rescore never builds an agent")
end

# rescore/3 scores the stored outputs and traces again with the task's
# current scorers. The agent is not called (agent/1 above would raise); the
# new run records where it came from. From the CLI: mix nous.eval.rescore.
{:ok, rescored} = Nous.Eval.rescore(run, Examples.Eval.VagueToolWithCount)

IO.puts("\nRescored run #{rescored.id} from #{rescored.metadata.rescored_from}")

for s <- rescored.samples do
  count = Enum.find(s.scores, &(&1.name == "tool_count"))
  IO.puts("  #{s.case_id}: #{s.verdict}, tool calls #{count.details.count}")
end

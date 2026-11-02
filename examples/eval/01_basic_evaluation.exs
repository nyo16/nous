# Basic Evaluation
#
# An eval task module, an Elixir dataset, built-in scorers, a run and a
# console report. Runs fully offline: a scripted model stands in for the LLM.
#
# Run with: mix run examples/eval/01_basic_evaluation.exs

require Logger
# The agent runner logs every run at :info/:debug; keep the report readable.
Logger.configure(level: :warning)

defmodule Examples.Eval.CapitalsModel do
  # A deterministic stand-in for a chat model. It is installed as the
  # process-scoped model dispatcher, so every request the agent makes lands
  # here instead of on the network. It gets Australia wrong on purpose, so
  # the report has a failing case to show.
  alias Nous.{Message, Usage}

  @capitals %{"France" => "Paris", "Japan" => "Tokyo", "Australia" => "Sydney"}

  def request(_model, messages, _settings) do
    question = messages |> List.last() |> Message.extract_text()

    answer =
      case Enum.find(@capitals, fn {country, _} -> String.contains?(question, country) end) do
        {country, city} -> "The capital of #{country} is #{city}."
        nil -> "I don't know."
      end

    usage = %Usage{requests: 1, input_tokens: 20, output_tokens: 8, total_tokens: 28}
    {:ok, Message.assistant(answer, metadata: %{usage: usage, finish_reason: "stop"})}
  end

  def request_stream(_model, _messages, _settings), do: {:error, :streaming_not_supported}
  def count_tokens(_messages), do: 20
end

defmodule Examples.Eval.Capitals do
  use Nous.Eval

  alias Nous.Eval.Scorers.{Contains, MaxTokens, NotContains}

  # Each case says what a good answer must contain, through its own scorer
  # (added after the task-wide scorers below). Ids are stable: baselines and
  # comparisons match cases by id.
  @impl Nous.Eval
  def dataset do
    for {id, country, city} <- [
          {"capital-france", "France", "Paris"},
          {"capital-japan", "Japan", "Tokyo"},
          {"capital-australia", "Australia", "Canberra"}
        ] do
      %{
        id: id,
        input: "What is the capital of #{country}?",
        tags: ["geography"],
        scorers: [{Contains, values: [city]}]
      }
    end
  end

  # Applied to every case, before the case's own scorers. Scorers are gates
  # (`required: true`) by default; MaxTokens is declared track-only
  # (`required: false, weight: 0`) so token use is recorded without ever
  # deciding a verdict.
  @impl Nous.Eval
  def scorers do
    [
      {NotContains, values: ["I don't know"]},
      {MaxTokens, max: 1_000, required: false, weight: 0}
    ]
  end

  # setup/1 runs once per eval run, in the calling process; the sample
  # processes find the dispatcher through `$callers`. teardown/1 always runs.
  @impl Nous.Eval
  def setup(_opts) do
    Nous.ModelDispatcher.put_dispatcher(Examples.Eval.CapitalsModel)
    {:ok, nil}
  end

  @impl Nous.Eval
  def teardown(_state), do: Nous.ModelDispatcher.put_dispatcher(nil)

  # Called once per sample: build a fresh agent. The model string only has
  # to parse (and be priced, for the cost column); the dispatcher answers.
  @impl Nous.Eval
  def agent(_ctx) do
    Nous.new("openai:gpt-4o-mini",
      instructions: "Answer geography questions in one sentence.",
      model_settings: %{temperature: 0}
    )
  end
end

# k: 3 samples per case. With a real model they would differ; the per-sample
# seed is derived from `seed`, the case id and the sample index.
{:ok, run} = Nous.Eval.run(Examples.Eval.Capitals, k: 3, seed: 1)

IO.puts(Nous.Eval.Reporter.render(run, format: :console))

# The report never prints agent output; read the samples for that.
IO.puts("\nFailing samples:")

for sample <- run.samples, sample.verdict != :pass do
  failed = for score <- sample.scores, not score.passed?, do: score.name

  IO.puts(
    "  #{sample.case_id} ##{sample.index}: #{inspect(sample.output)} " <>
      "(failed: #{Enum.join(failed, ", ")})"
  )
end

# The summary is plain data (string keys), stored with the run.
IO.puts("\nPass rate estimate: #{Float.round(run.summary["pass_rate"]["estimate"], 3)}")

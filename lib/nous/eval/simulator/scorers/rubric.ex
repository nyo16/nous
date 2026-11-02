defmodule Nous.Eval.Simulator.Scorers.Rubric do
  @moduledoc """
  An LLM judge over the episode transcript (`"sim.rubric"`), from a
  simulated case's `expected.rubric` (`judge`, `criteria`, `gate`).

  It is `Nous.Eval.Scorers.Judge` reading the conversation as the agent's
  output (`include: [:output]`): every `USER:`/`AGENT:` line, fenced as
  untrusted data. The simulated user's private reasoning and its reason
  for stopping are not in the transcript. The judge model is priced and
  budgeted like any model-graded scorer.

  It is diagnostic by default (`gate: false`: reported with weight 0): a
  judge reading a transcript inherits the simulator's biases, and
  natural-language assertions are the least reliable episode check. With
  `gate: true` it is a required scorer. Options are the judge's
  (`:judge`, `:rubric`, `:gate`, and the others `Nous.Eval.Scorers.Judge`
  documents except `:include` and `:name`).

  How the episode ended is decided first, as for every simulation scorer
  (see "Termination" in `Nous.Eval.Simulator`), so an abnormal episode is
  a fail without a judge call.
  """

  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.ScoreInput
  alias Nous.Eval.Scorers.Judge
  alias Nous.Eval.Simulator
  alias Nous.Eval.Simulator.Scorers.Common

  @id "sim.rubric"

  @impl true
  def id, do: @id

  @impl true
  def kind, do: :model_graded

  @impl true
  def init(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :include) or Keyword.has_key?(opts, :name),
      do: {:error, "#{@id}: :include and :name are fixed"},
      else: Judge.init(Keyword.merge(opts, include: [:output], name: @id))
  end

  @impl true
  def describe(config), do: Judge.describe(config)

  @impl true
  def score(%ScoreInput{} = input, config) do
    Common.score(input, @id, fn episode ->
      Judge.score(%{input | output: Simulator.transcript_text(episode)}, config)
    end)
  end
end

defmodule Nous.Eval.Case do
  @moduledoc """
  One evaluation case: an input for the agent, what is expected of the
  answer, and the scorers that judge it.

  Cases come from a `Nous.Eval.Dataset` (Elixir lists, YAML or JSONL; schema
  id `nous.case/1`). Every case has a stable string `id`: runs, baselines and
  comparisons match cases by it, so renaming an id makes it a new case.

  ## Fields

    * `:id` - stable, unique within the dataset (string)
    * `:input` - the prompt (string) or a message list (`[Nous.Message.t()]`)
      sent with `Nous.run(agent, messages: ...)`; for a simulated case
      (`nous.sim_case/1`), the `Nous.Eval.Simulator.Scenario` the simulated
      user plays (see `Nous.Eval.Simulator`)
    * `:expected` - free-form expectations the scorers read (string keys
      when loaded from YAML/JSONL)
    * `:scorers` - case-specific scorers (`Nous.Eval.Scorer.Spec`), added to
      the task's default scorers
    * `:threshold` - pass threshold for the weighted mean of the soft
      (`required: false`) scorers; `nil` means the default 0.5
    * `:tags` - strings, for selecting cases
    * `:split` - `"train" | "val" | "test" | nil`; assigned from `:group`
      when not given (see `Nous.Eval.Dataset`)
    * `:group` - cases that must land in the same split (paraphrases,
      near-duplicates); defaults to the id
    * `:metadata` - anything else; carried into the run record
  """

  alias Nous.Eval.Scorer

  @type split :: String.t() | nil

  @type t :: %__MODULE__{
          id: String.t(),
          input: String.t() | [Nous.Message.t()] | Nous.Eval.Simulator.Scenario.t(),
          expected: map(),
          scorers: [Scorer.Spec.t()],
          threshold: float() | nil,
          tags: [String.t()],
          split: split(),
          group: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:id, :input]
  defstruct [
    :id,
    :input,
    expected: %{},
    scorers: [],
    threshold: nil,
    tags: [],
    split: nil,
    group: nil,
    metadata: %{}
  ]

  @splits ["train", "val", "test"]

  @doc "The split names a case may carry."
  @spec splits() :: [String.t()]
  def splits, do: @splits
end

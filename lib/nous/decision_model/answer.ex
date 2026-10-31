defmodule Nous.DecisionModel.Answer do
  @moduledoc """
  The answer to one `Nous.DecisionModel.Question`.

  ## Fields

    * `:type` - `:noul`, `:choice` or `:score`, as declared.
    * `:noul` - for `:noul`, the probability that the answer is true.
    * `:choice` - for `:choice`, the most likely option id, exactly as
      declared (atom or string).
    * `:score` - for `:score`, the probability-weighted level index (0 is the
      first level). It can fall between two levels.
    * `:probabilities` - an ordered list:
      * `:choice` - `[{option_id, p}]` in declared option order
      * `:score` - `[{level_index, p}]`, lowest level first
      * `:noul` - `[{"true", p}, {"false", 1 - p}]`
    * `:confidence` - 0 (every option equally likely) to 1, as the backend
      reports it; `nil` when the backend does not report one (Clef `noul`).
  """

  @enforce_keys [:type]
  defstruct [:type, :noul, :choice, :score, :confidence, probabilities: []]

  @type t :: %__MODULE__{
          type: Nous.DecisionModel.Question.type(),
          noul: float() | nil,
          choice: Nous.DecisionModel.Question.option_id() | nil,
          score: float() | nil,
          probabilities: [{Nous.DecisionModel.Question.option_id() | non_neg_integer(), float()}],
          confidence: float() | nil
        }
end

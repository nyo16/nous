defmodule Nous.Eval.Optimizer.Candidate do
  @moduledoc """
  A profile in an optimization's pool.

    * `:profile` - the sealed `Nous.Profile`
    * `:parent_id` - the id of the candidate it was derived from (`nil` for
      the seed); a merge has two, in `:merged_from`
    * `:step` - the search step that produced it (`0` for the seed)
    * `:scores` - case id => objective on the selection set the strategy
      uses (validation for GEPA, the fixed train subset for OPRO)
    * `:mean` - the mean of `:scores`
    * `:changed` - the component keys that differ from its parent
  """

  alias Nous.Profile

  @type t :: %__MODULE__{
          profile: Profile.t(),
          parent_id: String.t() | nil,
          merged_from: [String.t()],
          step: non_neg_integer(),
          scores: %{String.t() => float()},
          mean: float(),
          changed: [String.t()]
        }

  @enforce_keys [:profile]
  defstruct [
    :profile,
    parent_id: nil,
    merged_from: [],
    step: 0,
    scores: %{},
    mean: 0.0,
    changed: []
  ]

  @doc "The candidate's profile id."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{profile: %Profile{id: id}}), do: id
end

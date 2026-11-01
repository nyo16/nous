defmodule Nous.Eval.Store.Baseline do
  @moduledoc """
  One entry in a baseline label's history: `label` pointed at `run_id` from
  `set_at` until the next entry for the same label.

  Labels are append-only (see `c:Nous.Eval.Store.put_baseline/3`): re-pointing
  a label adds an entry and keeps the old ones, so a regression gate's
  reference can always be audited and rolled back.
  """

  @type t :: %__MODULE__{
          label: String.t(),
          run_id: String.t(),
          set_at: DateTime.t()
        }

  @enforce_keys [:label, :run_id, :set_at]
  defstruct [:label, :run_id, :set_at]
end

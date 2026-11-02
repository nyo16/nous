defmodule Nous.Eval.Store.ProfileLabel do
  @moduledoc """
  One entry in a profile label's history: under profile name `name`, `label`
  pointed at the profile `profile_id` from `set_at` until the next entry for
  the same name and label.

  Labels are append-only (see `c:Nous.Eval.Store.put_profile_label/4`):
  promoting another profile adds an entry and keeps the old ones, so who
  pointed `production` at what, and when, is never lost and a rollback is
  just another entry.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          profile_id: String.t(),
          set_at: DateTime.t()
        }

  @enforce_keys [:name, :label, :profile_id, :set_at]
  defstruct [:name, :label, :profile_id, :set_at]
end

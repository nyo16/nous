defmodule Nous.Eval.Score do
  @moduledoc """
  One named result a scorer produced for one sample.

    * `:name` - `"<scorer id>"`, or `"<scorer id>.<key>"` for a scorer that
      emits several scores; always a string, never an atom from data
    * `:value` - `:pass | :fail`, a finite float in `0.0..1.0`, or
      `{:label, String.t()}`
    * `:passed?` - the scorer's own verdict under its threshold or rule
    * `:reason` - short, scorer-authored explanation (trusted text)
    * `:details` - evidence; may contain untrusted text such as agent output
      or a judge's critique
    * `:metadata` - e.g. judge model, prompt hash, raw scale value
  """

  @type value :: :pass | :fail | float() | {:label, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          value: value(),
          passed?: boolean(),
          reason: String.t() | nil,
          details: map(),
          metadata: map()
        }

  @enforce_keys [:name, :value, :passed?]
  defstruct [:name, :value, :passed?, reason: nil, details: %{}, metadata: %{}]
end

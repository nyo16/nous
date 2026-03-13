defmodule Nous.Plugins.InputGuard.Result do
  @moduledoc """
  Result of an input guard strategy check.

  Each strategy returns a `Result` indicating the severity of the input
  and optional metadata about why it was flagged.

  ## Severity Levels

    * `:safe` — Input appears benign
    * `:suspicious` — Input may be problematic but isn't clearly malicious
    * `:blocked` — Input is clearly malicious or policy-violating

  """

  @type severity :: :safe | :suspicious | :blocked

  @type t :: %__MODULE__{
          severity: severity(),
          reason: String.t() | nil,
          strategy: module() | nil,
          metadata: map()
        }

  defstruct severity: :safe,
            reason: nil,
            strategy: nil,
            metadata: %{}
end

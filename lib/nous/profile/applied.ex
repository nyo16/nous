defmodule Nous.Profile.Applied do
  @moduledoc """
  The profile an agent runs with, as stored on `%Nous.Agent{profile: ...}`.

  `Nous.Profile.apply/2` sets it. Besides the profile it keeps the agent's
  base text (the instructions and tools the profile replaced), so a run-level
  `profile:` option re-applies another profile to the base, and `profile:
  nil` restores it, without rebuilding the agent.

  Treat it as opaque: read the applied profile's id with
  `Nous.Profile.applied_id/1`.
  """

  @enforce_keys [:profile]
  defstruct [:profile, :base_instructions, base_tools: []]

  @type t :: %__MODULE__{
          profile: Nous.Profile.t(),
          base_instructions: String.t() | function() | nil,
          base_tools: [Nous.Tool.t()]
        }
end

defmodule Nous.Sandbox.Confined do
  @moduledoc """
  The result of `Nous.Sandbox.confine/2`: an argv to spawn plus the data needed
  to interpret what comes back.

  Enforcement is *data*, not behaviour. A provider states which mechanism it
  wrapped the argv with and which output patterns mean "denied" or "the runner
  broke"; `Nous.Sandbox.classify/3` is a pure function over that data. This is
  what keeps a cross-backend signature from matching: a bwrap-confined command
  carries only bwrap's signatures, so Seatbelt's "operation not permitted"
  never applies to it.
  """

  alias __MODULE__
  alias Nous.Sandbox.{Policy, RunnerFailureRule}

  @typedoc """
  The mechanism that wrapped the argv. `:none` means the argv was passed
  through unconfined (`:danger_full_access` only).
  """
  @type enforcement :: :sandbox_exec | :bwrap | :none

  @type t :: %Confined{
          argv: [String.t()],
          mode: Policy.mode(),
          enforcement: enforcement(),
          denial_signatures: [String.t()],
          runner_failure_rules: [RunnerFailureRule.t()]
        }

  @enforce_keys [:argv, :mode, :enforcement]
  defstruct [
    :argv,
    :mode,
    :enforcement,
    denial_signatures: [],
    runner_failure_rules: []
  ]
end

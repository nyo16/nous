defmodule Nous.Sandbox.RunnerFailureRule do
  @moduledoc """
  How to recognise "the sandbox runner itself failed" in a child's output.

  A runner failure means the command **never ran**: `bwrap` could not create a
  namespace, `sandbox-exec` rejected the profile. That is categorically
  different from "the command ran and was denied a write", and reporting it as
  a denial would let a broken runner read as working confinement.

  Fields:

    * `:allowed_exit_codes` — exit codes that are *not* runner failures. `nil`
      (the default) means every nonzero exit is a candidate.
    * `:fatal_signatures` — substrings that identify the runner's own error
      output, matched case-insensitively per line.
    * `:informational_lines` — full lines the runner prints that are noise, not
      failure. Dropped by exact case-insensitive full-line equality *before*
      fatal matching, so a chatty runner cannot be mistaken for a broken one.
  """

  alias __MODULE__

  @type t :: %RunnerFailureRule{
          allowed_exit_codes: [integer()] | nil,
          fatal_signatures: [String.t()],
          informational_lines: [String.t()]
        }

  defstruct allowed_exit_codes: nil,
            fatal_signatures: [],
            informational_lines: []
end

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

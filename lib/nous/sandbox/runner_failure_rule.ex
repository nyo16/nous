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

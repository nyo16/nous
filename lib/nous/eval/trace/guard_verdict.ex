defmodule Nous.Eval.Trace.GuardVerdict do
  @moduledoc """
  One guard decision in a `Nous.Eval.Trace`, from
  `Nous.Eval.Trace.guard_verdicts/2`.

  | `guard` | Source event | `verdict` | `surface` | `action` |
  |---|---|---|---|---|
  | `:decision_guard` | `[:nous, :decision_guard, :verdict]` | `:allow \\| :escalate \\| :deny` | `:user_input \\| :tool_call \\| :tool_result \\| :model_output` | effective `result` (`:allow \\| :deny \\| :modify`) |
  | `:input_guard` | `[:nous, :input_guard, :verdict]` | severity `:safe \\| :suspicious \\| :blocked` | `nil` | policy `action` |
  | `:loop_guard` | `[:nous, :loop_guard, :advisory]` | `:advisory` | `nil` | `nil` |
  | `:hook` | `[:nous, :hook, :decision]` of a decision hook that is not a DecisionGuard surface | `:allow \\| :escalate \\| :deny` | the hook event | effective `result` |

  A DecisionGuard hook surface emits both a `decision_guard` verdict and a
  `hook` decision; only the former is kept.

  `:metadata` is the raw event metadata (it may hold untrusted text).
  """

  @type guard :: :decision_guard | :input_guard | :loop_guard | :hook

  @type t :: %__MODULE__{
          guard: guard(),
          verdict: atom() | nil,
          surface: atom() | nil,
          action: atom() | nil,
          agent_run_id: String.t() | nil,
          parent_agent_run_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          metadata: map(),
          seq: non_neg_integer()
        }

  defstruct [
    :guard,
    :verdict,
    :surface,
    :action,
    :agent_run_id,
    :parent_agent_run_id,
    :tool_call_id,
    :seq,
    metadata: %{}
  ]
end

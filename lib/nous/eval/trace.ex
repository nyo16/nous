defmodule Nous.Eval.Trace do
  @moduledoc """
  The telemetry events one eval sample produced, in emission order.

  A trace is everything Nous emitted under the sample's `trace_id`: the root
  run, its model and tool calls, guard verdicts, and every sub-agent run
  (linked through `parent_agent_run_id` / `parent_tool_call_id`). It
  survives failed and killed runs, so a failing sample can be inspected up
  to the point it stopped.

  Events carry the metadata documented in `Nous.Telemetry`. Content keys
  (`messages`, `response`, `arguments`, `result`, `details`, `errors`) hold
  user data.

  `truncated?` is true when the per-trace event or byte cap was reached; the
  tail of the trace is then missing, and a scorer that needs to prove an
  absence ("tool X was never called") must not pass on it.
  """

  alias Nous.Eval.Trace.Event

  @type t :: %__MODULE__{
          trace_id: String.t(),
          events: [Event.t()],
          truncated?: boolean(),
          dropped: non_neg_integer()
        }

  @enforce_keys [:trace_id]
  defstruct [:trace_id, events: [], truncated?: false, dropped: 0]
end

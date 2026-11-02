defmodule Nous.Eval.Trace.Event do
  @moduledoc """
  One telemetry event in a `Nous.Eval.Trace`.

    * `:name` - the telemetry event name, e.g. `[:nous, :agent, :tool_call, :stop]`
    * `:measurements` / `:metadata` - as emitted (see `Nous.Telemetry`)
    * `:at` - `System.monotonic_time/0` when the collector received it
      (`:native` units); orders events and gives relative timings
    * `:seq` - position in the trace, from 0
  """

  @type t :: %__MODULE__{
          name: [atom()],
          measurements: map(),
          metadata: map(),
          at: integer(),
          seq: non_neg_integer()
        }

  @enforce_keys [:name, :at, :seq]
  defstruct [:name, :at, :seq, measurements: %{}, metadata: %{}]
end

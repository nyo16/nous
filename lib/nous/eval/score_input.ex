defmodule Nous.Eval.ScoreInput do
  @moduledoc """
  What a scorer reads for one sample.

    * `:case` - the `Nous.Eval.Case`
    * `:sample` - the sample index, `0..k-1`
    * `:seed` - the seed the sample ran with, or `nil`
    * `:output` - the agent's final output (string or structured value);
      `nil` when the run failed
    * `:run_outcome` - `{:ok, result} | {:error, reason} | :killed`
    * `:trace` - the sample's `Nous.Eval.Trace`
    * `:usage` - `Nous.Usage` summed over the whole run tree
    * `:duration_ms` - wall time of the sample
    * `:track_trace` - `nil`, or a function the eval runner sets that
      charges a trace id's model requests to the run's budget
      (`Nous.Eval.run/2`'s `:budget`). A model-graded scorer calls it with
      the trace id of its own model runs before the first request, so
      every request, answered or failed, is paid for. Spend a scorer only
      reports in `Score` metadata is not charged.

  A failed run is not a scorer error: output scorers fail the sample with
  `reason: "run_failed"`, trace scorers score the partial trace.
  """

  alias Nous.Eval.{Case, Trace}

  @type run_outcome :: {:ok, map()} | {:error, term()} | :killed

  @type t :: %__MODULE__{
          case: Case.t(),
          sample: non_neg_integer(),
          seed: integer() | nil,
          output: term(),
          run_outcome: run_outcome(),
          trace: Trace.t(),
          usage: Nous.Usage.t(),
          duration_ms: non_neg_integer(),
          track_trace: (String.t() -> :ok) | nil
        }

  @enforce_keys [:case, :sample, :run_outcome, :trace]
  defstruct [
    :case,
    :sample,
    :run_outcome,
    :trace,
    seed: nil,
    output: nil,
    usage: %Nous.Usage{},
    duration_ms: 0,
    track_trace: nil
  ]
end

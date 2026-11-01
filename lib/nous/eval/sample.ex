defmodule Nous.Eval.Sample do
  @moduledoc """
  One execution of one case, with its scores.

    * `:case_id` / `:index` - the case and the sample number (`0..k-1`)
    * `:seed` - the seed sent, or `nil`
    * `:trace_id` - the trace the sample ran under
    * `:outcome` - how the agent run ended: `:ok`, `:error`, `:killed`
      (timeout), or `:budget_exhausted` (never started or cancelled by the
      run budget)
    * `:output` - the agent's final output, `nil` unless `:ok`
    * `:error` - a printable description of the run error, or `nil`
    * `:verdict` - `:pass | :fail | :error` after composing the scorers
      (see `Nous.Eval.Scoring`); `nil` for a budget-exhausted sample
    * `:case_score` - the gated objective: `0.0` when a required scorer
      failed, else the weighted mean of the soft scorers (`1.0` with none);
      `nil` when the verdict is `:error`
    * `:scores` / `:scorer_errors` / `:skipped` - every scorer result,
      stored regardless of the verdict (`skipped` holds `{scorer, reason}`)
    * `:trace` - the `Nous.Eval.Trace`
    * `:usage` / `:cost` / `:duration_ms` / `:iterations` - resource use;
      `cost` is `nil` when no price is known
  """

  alias Nous.Eval.{Score, ScorerError, Trace}

  @type outcome :: :ok | :error | :killed | :budget_exhausted
  @type verdict :: :pass | :fail | :error

  @type t :: %__MODULE__{
          case_id: String.t(),
          index: non_neg_integer(),
          seed: integer() | nil,
          trace_id: String.t() | nil,
          outcome: outcome(),
          output: term(),
          error: String.t() | nil,
          verdict: verdict() | nil,
          case_score: float() | nil,
          scores: [Score.t()],
          scorer_errors: [ScorerError.t()],
          skipped: [{String.t(), String.t()}],
          trace: Trace.t() | nil,
          usage: Nous.Usage.t(),
          cost: float() | nil,
          duration_ms: non_neg_integer(),
          iterations: non_neg_integer()
        }

  @enforce_keys [:case_id, :index, :outcome]
  defstruct [
    :case_id,
    :index,
    :outcome,
    seed: nil,
    trace_id: nil,
    output: nil,
    error: nil,
    verdict: nil,
    case_score: nil,
    scores: [],
    scorer_errors: [],
    skipped: [],
    trace: nil,
    usage: %Nous.Usage{},
    cost: nil,
    duration_ms: 0,
    iterations: 0
  ]
end

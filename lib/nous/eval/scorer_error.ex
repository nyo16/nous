defmodule Nous.Eval.ScorerError do
  @moduledoc """
  A scorer failed to produce a verdict. It says nothing about the agent: a
  sample with any scorer error is `:error`, never `:pass` or `:fail`, and an
  eval run with errors exits non-zero in CI.

  `kind` is one of:

    * `:raised` - the scorer raised, threw or exited
    * `:timeout` - the scorer exceeded its time limit
    * `:invalid_config` - bad options, or a required scorer skipped
    * `:missing_trace` - the trace needed is absent or truncated
    * `:judge_unparseable` / `:judge_out_of_range` / `:judge_call_failed` -
      the LLM judge's answer could not be used
    * `:budget_exhausted` - a model-graded scorer had no budget left
    * `:non_finite` - a score value was NaN, infinite or outside `0.0..1.0`
  """

  @type kind ::
          :raised
          | :timeout
          | :invalid_config
          | :missing_trace
          | :judge_unparseable
          | :judge_out_of_range
          | :judge_call_failed
          | :budget_exhausted
          | :non_finite

  @type t :: %__MODULE__{
          scorer: String.t(),
          kind: kind(),
          reason: String.t() | nil,
          details: map()
        }

  defexception [:scorer, :kind, reason: nil, details: %{}]

  @kinds [
    :raised,
    :timeout,
    :invalid_config,
    :missing_trace,
    :judge_unparseable,
    :judge_out_of_range,
    :judge_call_failed,
    :budget_exhausted,
    :non_finite
  ]

  @doc "Every error kind."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @impl true
  def message(%__MODULE__{scorer: scorer, kind: kind, reason: nil}),
    do: "scorer #{scorer} failed: #{kind}"

  def message(%__MODULE__{scorer: scorer, kind: kind, reason: reason}),
    do: "scorer #{scorer} failed: #{kind}: #{reason}"
end

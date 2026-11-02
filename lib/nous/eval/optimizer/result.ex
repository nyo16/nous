defmodule Nous.Eval.Optimizer.Result do
  @moduledoc """
  The outcome of `Nous.Eval.Optimizer.run/2`.

    * `:verdict` - `:accepted` or `:rejected`
    * `:reasons` - why, in plain words (always set for a rejection)
    * `:profile` - the candidate that went to the test split (with the
      optimizer's provenance; the stored version when it was persisted), or
      `nil` when the search never found a candidate better than the seed
    * `:seed_profile` - the agent's base text as a profile
    * `:comparison` - `Nous.Eval.Compare` of the seed's test run (baseline)
      against the candidate's (the no-regression direction)
    * `:improvement` - the comparison the other way round: a `:regression`
      verdict there means the seed is significantly worse than the
      candidate, i.e. the candidate improves on it
    * `:sign_test` - `%{b:, c:, p_value:}`: test cases the candidate improved
      (`b`) and worsened (`c`) by pass rate, and the exact one-sided sign-test
      p-value (McNemar's exact binomial halved when `b > c`, else `1.0`). The
      improvement gate needs both a `:regression` verdict in `:improvement`
      and this p below alpha, so at alpha 0.05 the smallest test split that
      can pass is 5 cases, all improved (p = 0.5^5 = 0.03125)
    * `:guard` - the guard filter's verdict on the test split's guard cases
      (`:ok`, `:skipped` or `{:error, reason}`)
    * `:report` - the `Nous.Eval.ProfileReport` (render it with
      `Nous.Eval.ProfileReport.render/2`), or `nil` without a candidate
    * `:candidates` / `:rejections` - the strategy's pool and rejection log.
      A rejection made after the reflector proposed text carries
      `proposal: %{component => text}` with the rejected proposal
    * `:steps` / `:stop_reason` - search steps run and why the search ended
      (`:max_steps`, `:budget_exhausted`, ...)
    * `:budget` - limits, spend and reserve
    * `:run_ids` - every `Nous.Eval.Run` the optimization produced
    * `:stored?` - whether the accepted profile was persisted
  """

  alias Nous.Eval.Optimizer.Candidate

  @type t :: %__MODULE__{
          verdict: :accepted | :rejected,
          reasons: [String.t()],
          profile: Nous.Profile.t() | nil,
          seed_profile: Nous.Profile.t(),
          comparison: Nous.Eval.Compare.t() | nil,
          improvement: Nous.Eval.Compare.t() | nil,
          sign_test: %{b: non_neg_integer(), c: non_neg_integer(), p_value: float()} | nil,
          guard: :ok | :skipped | {:error, term()},
          report: Nous.Eval.ProfileReport.t() | nil,
          candidates: [Candidate.t()],
          rejections: [map()],
          steps: non_neg_integer(),
          stop_reason: term(),
          budget: map(),
          run_ids: [String.t()],
          stored?: boolean()
        }

  @enforce_keys [:verdict, :seed_profile]
  defstruct [
    :verdict,
    :seed_profile,
    reasons: [],
    profile: nil,
    comparison: nil,
    improvement: nil,
    sign_test: nil,
    guard: :skipped,
    report: nil,
    candidates: [],
    rejections: [],
    steps: 0,
    stop_reason: nil,
    budget: %{},
    run_ids: [],
    stored?: false
  ]
end

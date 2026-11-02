defmodule Nous.Eval.Optimizer.Strategy do
  @moduledoc """
  A search strategy for `Nous.Eval.Optimizer`: how candidate profiles are
  proposed and which one is best.

  The optimizer owns everything around the search: splits, the budget, the
  seed evaluation, the final pick's test-split acceptance, the report and
  persistence. A strategy only searches, through the helpers on
  `Nous.Eval.Optimizer.Context` (`evaluate/4`, `derive/4`, `propose/4`,
  `feasible/3`), which charge the budget and enforce the split and safety
  rules for it.

    * `c:init/2` receives the seed candidate (the agent's base text as a
      profile) and may evaluate it.
    * `c:step/2` runs one search step. Return `{:halt, reason, state}` when
      the search cannot continue (`:budget_exhausted` when a helper returned
      `{:error, :budget_exhausted}`, or an operational error).
    * `c:best/1` picks the candidate to test. It must never look at test
      data: the optimizer has not evaluated the test split for any
      candidate but the seed when it asks.
    * `c:summary/1` reports the candidates and rejections for the result.

  Built-ins: `Nous.Eval.Optimizer.Strategies.GEPA` (default) and
  `Nous.Eval.Optimizer.Strategies.OPRO`.
  """

  alias Nous.Eval.Optimizer.{Candidate, Context}

  @callback init(seed :: Candidate.t(), Context.t()) :: {:ok, state :: term()} | {:error, term()}
  @callback step(state :: term(), Context.t()) ::
              {:cont, state :: term()} | {:halt, reason :: term(), state :: term()}
  @callback best(state :: term()) :: Candidate.t()
  @callback summary(state :: term()) :: %{candidates: [Candidate.t()], rejections: [map()]}
end

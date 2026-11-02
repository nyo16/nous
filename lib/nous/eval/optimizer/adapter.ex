defmodule Nous.Eval.Optimizer.Adapter do
  @moduledoc """
  How `Nous.Eval.Optimizer` evaluates a candidate profile and turns the
  result into evidence for the reflector (the GEPA adapter shape).

  The default, `Nous.Eval.Optimizer.AgentAdapter`, runs the eval task with
  `Nous.Eval.run/2` and the candidate applied to every agent the task
  builds. An adapter for another system implements the same five callbacks
  and is passed as `adapter: {module, opts}`.

  ## Contract

    * `c:evaluate/3` never raises per case: a case that crashed, timed out
      or errored is in the result with score `0.0`. It reports what it spent
      (`metric_calls`, `tokens`, `cost`) and the run status; the optimizer
      charges the spend whatever the status and uses only `:completed`
      evaluations for decisions.
    * `c:reflective_records/2` builds records from **train** evaluations
      only and raises `ArgumentError` for any other split: validation and
      test content never reaches the reflector, only their scores reach
      the optimizer. Records are rendered under the evaluation's feedback
      policy (see "Feedback policy" in `Nous.Eval.Optimizer`).
  """

  alias Nous.Eval.Case
  alias Nous.Eval.Optimizer.Evaluation

  @typedoc """
  A batch to evaluate:

    * `:case_ids` - the cases
    * `:split` - the split label recorded on the evaluation
    * `:k` - samples per case
    * `:budget` - the most this evaluation may spend
      (`[max_tokens: n, max_cost: usd, max_samples: n]`, see "Budgets" in
      `Nous.Eval.run/2`)
    * `:feedback` - the feedback policy for its reflective records
    * `:seed` - the base seed (the same for every evaluation, so a parent
      and its child see the same sample seeds)
  """
  @type batch :: %{
          required(:case_ids) => [String.t()],
          required(:split) => String.t(),
          required(:k) => pos_integer(),
          required(:budget) => keyword(),
          required(:feedback) => :diagnostic | :with_expected,
          required(:seed) => integer() | nil
        }

  @typedoc """
  One piece of reflector evidence, for one train case:

    * `:case_id`, `:score` - the case and its objective (from the scorer
      structs, never parsed from text)
    * `:inputs` - the case input as text (untrusted)
    * `:outputs` - the agent's output or error (untrusted)
    * `:tool_calls` - `[%{name, arguments, outcome, result}]` from the
      trace (untrusted)
    * `:feedback` - one map per score: `:scorer`, `:passed?`, `:value`,
      `:reason` (trusted, scorer-authored), `:paths` (mismatched argument
      or output paths; untrusted), `:missing_tools` (expected tool names
      that were not called), `:critique` (a judge's critique; untrusted)
    * `:expected` - the case's `expected` map, present only under
      `:with_expected` for a train case
  """
  @type reflective_record :: %{
          required(:case_id) => String.t(),
          required(:score) => float(),
          required(:inputs) => String.t(),
          required(:outputs) => String.t(),
          required(:tool_calls) => [map()],
          required(:feedback) => [map()],
          optional(:expected) => map()
        }

  @doc "Prepares the adapter for `task` (no model call)."
  @callback init(task :: module(), opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Every case the optimizer may draw batches from."
  @callback cases(state :: term()) :: [Case.t()]

  @doc """
  The agent the profiles are written for, with its base text: component
  keys are validated and profiles sealed against it, and the guard filter
  receives it with each profile applied.
  """
  @callback agent(state :: term()) :: Nous.Agent.t()

  @doc "Evaluates `profile` on `batch`."
  @callback evaluate(state :: term(), profile :: Nous.Profile.t(), batch()) ::
              {:ok, Evaluation.t()} | {:error, term()}

  @doc """
  The reflector evidence for `component_keys`: `%{key => [record]}`.
  Raises `ArgumentError` unless the evaluation's split is `"train"`.
  """
  @callback reflective_records(Evaluation.t(), component_keys :: [String.t()]) ::
              %{String.t() => [reflective_record()]}
end

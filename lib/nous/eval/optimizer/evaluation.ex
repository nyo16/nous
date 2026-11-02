defmodule Nous.Eval.Optimizer.Evaluation do
  @moduledoc """
  One candidate profile evaluated on a batch of cases: what
  `c:Nous.Eval.Optimizer.Adapter.evaluate/3` returns.

    * `:profile_id` - the evaluated `Nous.Profile`'s id
    * `:split` - the split the batch was drawn from (`"train"`, `"val"`,
      `"test"`) or `"guard"` for the guard-tagged cases the feasibility
      filter runs
    * `:case_ids` - the batch, in order
    * `:scores` - case id => the case's objective: the mean of its samples'
      gated `case_score` (`Nous.Eval.Sample`), where a sample that errored
      or was not scored counts `0.0`. Errors never count as passes, and a
      case is never left out, so every candidate is scored on the same cases
    * `:status` - the run status (`:completed`, `:budget_exhausted`,
      `:aborted`); only a `:completed` evaluation is used for decisions
    * `:feedback` - the feedback policy its reflective records are rendered
      under (`:diagnostic` or `:with_expected`)
    * `:cases` - case id => `Nous.Eval.Case`, for the reflective records
    * `:run` - the `Nous.Eval.Run` behind it (samples, traces, summary)
    * `:metric_calls` / `:tokens` / `:cost` - what it spent: samples
      started, tokens, USD (`nil` when a request had no price)
    * `:private` - adapter-private data for `reflective_records/2`
  """

  alias Nous.Eval.{Case, Run}

  @type split :: String.t()

  @type t :: %__MODULE__{
          profile_id: String.t() | nil,
          split: split(),
          case_ids: [String.t()],
          scores: %{String.t() => float()},
          status: Run.status(),
          feedback: :diagnostic | :with_expected,
          cases: %{String.t() => Case.t()},
          run: Run.t() | nil,
          metric_calls: non_neg_integer(),
          tokens: non_neg_integer(),
          cost: float() | nil,
          private: map()
        }

  @enforce_keys [:profile_id, :split, :case_ids, :scores]
  defstruct [
    :profile_id,
    :split,
    :case_ids,
    :scores,
    status: :completed,
    feedback: :diagnostic,
    cases: %{},
    run: nil,
    metric_calls: 0,
    tokens: 0,
    cost: 0.0,
    private: %{}
  ]

  @doc "The sum of the per-case scores (GEPA's minibatch objective)."
  @spec total(t()) :: float()
  def total(%__MODULE__{scores: scores}), do: scores |> Map.values() |> Enum.sum() |> Kernel./(1)

  @doc "The mean per-case score; `0.0` for an empty batch."
  @spec mean(t()) :: float()
  def mean(%__MODULE__{scores: scores}) when map_size(scores) == 0, do: 0.0
  def mean(%__MODULE__{scores: scores} = evaluation), do: total(evaluation) / map_size(scores)

  @doc """
  The evaluation restricted to `case_ids` (scores, cases and the run's
  samples). Used to read the guard-tagged cases out of a test evaluation.
  """
  @spec take(t(), [String.t()], split()) :: t()
  def take(%__MODULE__{} = evaluation, case_ids, split) do
    wanted = MapSet.new(case_ids)
    ids = Enum.filter(evaluation.case_ids, &MapSet.member?(wanted, &1))

    run =
      case evaluation.run do
        %Run{} = run ->
          %{run | samples: Enum.filter(run.samples, &MapSet.member?(wanted, &1.case_id))}

        nil ->
          nil
      end

    %{
      evaluation
      | split: split,
        case_ids: ids,
        scores: Map.take(evaluation.scores, ids),
        cases: Map.take(evaluation.cases, ids),
        run: run
    }
  end
end

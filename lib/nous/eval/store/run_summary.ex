defmodule Nous.Eval.Store.RunSummary do
  @moduledoc """
  The listing view of a stored `Nous.Eval.Run`: everything except the
  samples and their traces, plus the sample count.

  `c:Nous.Eval.Store.list_runs/2` returns these so a listing never decodes
  traces. Fetch the full run with `c:Nous.Eval.Store.get_run/2`.
  """

  alias Nous.Eval.Run

  @type t :: %__MODULE__{
          id: String.t(),
          schema_version: pos_integer(),
          task: String.t() | nil,
          status: Run.status(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          dataset_hash: String.t() | nil,
          k: pos_integer(),
          seed: integer() | nil,
          sample_count: non_neg_integer(),
          summary: map(),
          metadata: map()
        }

  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :status,
    schema_version: 1,
    task: nil,
    started_at: nil,
    finished_at: nil,
    dataset_hash: nil,
    k: 1,
    seed: nil,
    sample_count: 0,
    summary: %{},
    metadata: %{}
  ]

  @doc "The summary of `run`."
  @spec from_run(Run.t()) :: t()
  def from_run(%Run{} = run) do
    %__MODULE__{
      id: run.id,
      schema_version: run.schema_version,
      task: run.task,
      status: run.status,
      started_at: run.started_at,
      finished_at: run.finished_at,
      dataset_hash: run.dataset_hash,
      k: run.k,
      seed: run.seed,
      sample_count: length(run.samples),
      summary: run.summary,
      metadata: run.metadata
    }
  end
end

defmodule Nous.Eval.Run do
  @moduledoc """
  The record of one eval run: its configuration fingerprint, every sample,
  and the summary statistics. This is what a `Nous.Eval.Store` persists and
  what `Nous.Eval.Compare` diffs.

    * `:id` - the eval run id (string)
    * `:schema_version` - record format version; stores read every older
      version and refuse newer ones
    * `:task` - the task module name as a string
    * `:status` - `:completed`, `:budget_exhausted` (stopped early, partial
      results) or `:aborted` (operational failure, e.g. the trace handler
      was detached)
    * `:fingerprint` - everything that identifies the configuration under
      test (see `Nous.Eval.Fingerprint`)
    * `:dataset_hash` - content hash of the dataset that ran
    * `:k` / `:seed` - samples per case and the base seed
    * `:budget` - the configured limits and what was spent
    * `:samples` - `[Nous.Eval.Sample.t()]`
    * `:summary` - aggregate metrics computed from the samples
    * `:metadata` - free-form (e.g. git sha, CI job)
  """

  alias Nous.Eval.Sample

  @schema_version 1

  @type status :: :completed | :budget_exhausted | :aborted

  @type t :: %__MODULE__{
          id: String.t(),
          schema_version: pos_integer(),
          task: String.t() | nil,
          status: status(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          fingerprint: map(),
          dataset_hash: String.t() | nil,
          k: pos_integer(),
          seed: integer() | nil,
          budget: map(),
          samples: [Sample.t()],
          summary: map(),
          metadata: map()
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    schema_version: @schema_version,
    task: nil,
    status: :completed,
    started_at: nil,
    finished_at: nil,
    fingerprint: %{},
    dataset_hash: nil,
    k: 1,
    seed: nil,
    budget: %{},
    samples: [],
    summary: %{},
    metadata: %{}
  ]

  @doc "The record format version this release writes."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version
end

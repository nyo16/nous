defmodule Nous.Workflow.Checkpoint do
  @moduledoc """
  Checkpoint for suspending and resuming workflow execution.

  When a workflow is paused (via hook, atomics signal, or human checkpoint),
  a checkpoint captures the full execution state so the workflow can be
  resumed later.

  ## Fields

  | Field | Description |
  |-------|-------------|
  | `workflow_id` | Graph ID |
  | `run_id` | Unique run identifier |
  | `node_id` | Node where execution paused |
  | `state` | Full workflow state at pause point |
  | `status` | `:suspended` or `:completed` or `:failed` |
  | `reason` | Why the workflow was paused |
  | `created_at` | When checkpoint was created |
  """

  alias __MODULE__

  @type t :: %Checkpoint{
          workflow_id: String.t(),
          run_id: String.t(),
          node_id: String.t() | nil,
          state: Nous.Workflow.State.t(),
          status: :suspended | :completed | :failed,
          reason: term(),
          created_at: DateTime.t()
        }

  defstruct [
    :workflow_id,
    :run_id,
    :node_id,
    :state,
    :reason,
    status: :suspended,
    created_at: nil
  ]

  @doc """
  Create a new checkpoint from execution context.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %Checkpoint{
      workflow_id: Map.fetch!(attrs, :workflow_id),
      run_id: Map.get(attrs, :run_id) || generate_id(),
      node_id: Map.get(attrs, :node_id),
      state: Map.fetch!(attrs, :state),
      status: Map.get(attrs, :status, :suspended),
      reason: Map.get(attrs, :reason),
      created_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

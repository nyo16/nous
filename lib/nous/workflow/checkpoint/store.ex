defmodule Nous.Workflow.Checkpoint.Store do
  @moduledoc """
  Behaviour for checkpoint storage backends.
  """

  alias Nous.Workflow.Checkpoint

  @callback save(Checkpoint.t()) :: :ok | {:error, term()}
  @callback load(run_id :: String.t()) :: {:ok, Checkpoint.t()} | {:error, :not_found}
  @callback list(workflow_id :: String.t()) :: {:ok, [Checkpoint.t()]}
  @callback delete(run_id :: String.t()) :: :ok | {:error, term()}
end

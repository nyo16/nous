defmodule Nous.Workflow.Scratch do
  @moduledoc """
  Optional per-workflow ETS table for large/binary data exchange between steps.

  Use when workflow steps produce large data (fetched HTML, images, CSVs)
  that shouldn't be copied through the immutable state pipeline. The scratch
  table is created lazily and auto-cleaned on workflow completion.

  ## Usage

  Enable via `scratch: true` option when running a workflow:

      {:ok, state} = Nous.Workflow.run(graph, %{}, scratch: true)

  Inside a transform or handler:

      # Write large data
      Nous.Workflow.Scratch.put(scratch, :raw_html, large_binary)

      # Read it later
      html = Nous.Workflow.Scratch.get(scratch, :raw_html)

  The scratch reference is available in `state.metadata.scratch`.
  """

  @type t :: %__MODULE__{
          table: :ets.tid() | nil,
          id: String.t()
        }

  defstruct table: nil, id: nil

  @doc """
  Create a new scratch space (lazily — ETS table created on first write).
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      id: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    }
  end

  @doc """
  Store a value in the scratch space.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%__MODULE__{} = scratch, key, value) do
    scratch = ensure_table(scratch)
    :ets.insert(scratch.table, {key, value})
    scratch
  end

  @doc """
  Retrieve a value from the scratch space.
  """
  @spec get(t(), term(), term()) :: term()
  def get(scratch, key, default \\ nil)

  def get(%__MODULE__{table: nil}, _key, default), do: default

  def get(%__MODULE__{} = scratch, key, default) do
    case :ets.lookup(scratch.table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc """
  Delete a key from the scratch space.
  """
  @spec delete(t(), term()) :: :ok
  def delete(%__MODULE__{table: nil}, _key), do: :ok

  def delete(%__MODULE__{} = scratch, key) do
    :ets.delete(scratch.table, key)
    :ok
  end

  @doc """
  Clean up the scratch ETS table. Called automatically on workflow completion.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{table: nil}), do: :ok

  def cleanup(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end

  defp ensure_table(%__MODULE__{table: nil} = scratch) do
    table = :ets.new(:"nous_scratch_#{scratch.id}", [:set, :public])
    %{scratch | table: table}
  end

  defp ensure_table(scratch), do: scratch
end

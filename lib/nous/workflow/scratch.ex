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

  alias __MODULE__

  @type t :: %Scratch{
          table: :ets.tid() | nil,
          id: String.t()
        }

  defstruct table: nil, id: nil

  @doc """
  Create a new scratch space (lazily — ETS table created on first write).
  """
  @spec new() :: t()
  def new do
    %Scratch{
      id: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    }
  end

  @doc """
  Store a value in the scratch space.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%Scratch{} = scratch, key, value) do
    scratch = ensure_table(scratch)
    :ets.insert(scratch.table, {key, value})
    scratch
  end

  @doc """
  Retrieve a value from the scratch space.
  """
  @spec get(t(), term(), term()) :: term()
  def get(scratch, key, default \\ nil)

  def get(%Scratch{table: nil}, _key, default), do: default

  def get(%Scratch{} = scratch, key, default) do
    case :ets.lookup(scratch.table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc """
  Delete a key from the scratch space.
  """
  @spec delete(t(), term()) :: :ok
  def delete(%Scratch{table: nil}, _key), do: :ok

  def delete(%Scratch{} = scratch, key) do
    :ets.delete(scratch.table, key)
    :ok
  end

  @doc """
  Clean up the scratch ETS table. Called automatically on workflow completion.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%Scratch{table: nil}), do: :ok

  def cleanup(%Scratch{table: table}) do
    :ets.delete(table)
    :ok
  end

  defp ensure_table(%Scratch{table: nil} = scratch) do
    # Constant atom: without :named_table the name is cosmetic, and a
    # per-run :"nous_scratch_#{id}" atom would leak (atoms are never GC'd).
    table = :ets.new(:nous_scratch, [:set, :public])
    %{scratch | table: table}
  end

  defp ensure_table(scratch), do: scratch
end

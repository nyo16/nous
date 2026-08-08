defmodule Nous.Workflow.Checkpoint.ETS do
  @moduledoc """
  ETS-backed checkpoint store. Suitable for development and testing.

  The table is owned by a supervised TableOwner GenServer started under the
  Nous application supervisor. Without it the table would die with whichever
  transient process happened to create it first, silently losing every
  suspended workflow that relied on resume.

  Note: Data is lost on node restart. For production, use a persistent
  backend.
  """

  @behaviour Nous.Workflow.Checkpoint.Store

  @table :nous_workflow_checkpoints

  defmodule TableOwner do
    @moduledoc false
    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    @table :nous_workflow_checkpoints

    @impl true
    def init(:ok) do
      table =
        case :ets.whereis(@table) do
          :undefined ->
            # :protected — only this owner writes; any process may read.
            :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

          _ref ->
            @table
        end

      {:ok, %{table: table}}
    end

    @impl true
    def handle_call({:save, run_id, checkpoint}, _from, %{table: table} = state) do
      :ets.insert(table, {run_id, checkpoint})
      {:reply, :ok, state}
    end

    def handle_call({:delete, run_id}, _from, %{table: table} = state) do
      :ets.delete(table, run_id)
      {:reply, :ok, state}
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {TableOwner, :start_link, [[]]}, type: :worker}
  end

  @impl true
  def save(checkpoint) do
    GenServer.call(owner(), {:save, checkpoint.run_id, checkpoint})
  end

  @impl true
  def load(run_id) do
    ensure_table()

    case :ets.lookup(@table, run_id) do
      [{^run_id, checkpoint}] -> {:ok, checkpoint}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list(workflow_id) do
    ensure_table()

    checkpoints =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, cp} -> cp end)
      |> Enum.filter(&(&1.workflow_id == workflow_id))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    {:ok, checkpoints}
  end

  @impl true
  def delete(run_id) do
    GenServer.call(owner(), {:delete, run_id})
  end

  # The table is owned by the supervised TableOwner (started in
  # Nous.Application). Resolve it, starting one on demand for ad-hoc callers
  # that run before/without the supervisor (mainly tests). Reads are allowed
  # from any process under :protected.
  defp owner do
    case Process.whereis(TableOwner) do
      nil ->
        case TableOwner.start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  defp ensure_table, do: owner()
end

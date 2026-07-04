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

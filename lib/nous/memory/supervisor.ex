defmodule Nous.Memory.Supervisor do
  @moduledoc """
  DynamicSupervisor for memory managers.

  Provides fault isolation and dynamic agent creation for the memory system.
  Each agent gets its own supervised Memory Manager.

  ## Architecture

  ```
  Application Supervisor
      └── Nous.Memory.Supervisor (DynamicSupervisor)
              │
              ├── Nous.Memory.Manager (agent: "agent_1")
              │
              ├── Nous.Memory.Manager (agent: "agent_2")
              │
              └── ...
  ```

  ## Usage

      # Start the supervisor (usually in your application)
      {:ok, _} = Nous.Memory.Supervisor.start_link()

      # Start a memory manager for an agent
      {:ok, manager} = Nous.Memory.Supervisor.start_manager(
        agent_id: "my_agent",
        store: {RocksdbStore, path: "/data/my_agent"}
      )

      # Stop a manager
      :ok = Nous.Memory.Supervisor.stop_manager(manager)

  ## Integration with Application

  Add to your application supervision tree:

      children = [
        Nous.Memory.Supervisor,
        # ... other children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  """

  use DynamicSupervisor

  alias Nous.Memory.Manager

  @doc """
  Start the Memory Supervisor.

  ## Options

  - `:name` - Name registration (default: `Nous.Memory.Supervisor`)

  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a Memory Manager under supervision.

  See `Nous.Memory.Manager.start_link/1` for available options.
  The `:agent_id` option is required.

  Returns `{:ok, pid}` on success.
  """
  @spec start_manager(keyword()) :: DynamicSupervisor.on_start_child()
  def start_manager(opts) do
    start_manager(__MODULE__, opts)
  end

  @doc """
  Start a Memory Manager under a specific supervisor.
  """
  @spec start_manager(Supervisor.supervisor(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_manager(supervisor, opts) do
    spec = {Manager, opts}
    DynamicSupervisor.start_child(supervisor, spec)
  end

  @doc """
  Stop a Memory Manager.

  Returns `:ok` on success.
  """
  @spec stop_manager(pid()) :: :ok | {:error, :not_found}
  def stop_manager(manager) do
    stop_manager(__MODULE__, manager)
  end

  @doc """
  Stop a Memory Manager under a specific supervisor.
  """
  @spec stop_manager(Supervisor.supervisor(), pid()) :: :ok | {:error, :not_found}
  def stop_manager(supervisor, manager) do
    DynamicSupervisor.terminate_child(supervisor, manager)
  end

  @doc """
  List all running Memory Managers.

  Returns a list of `{id, pid, type, modules}` tuples.
  """
  @spec which_managers() :: [{term(), pid(), :worker | :supervisor, [module()]}]
  def which_managers do
    which_managers(__MODULE__)
  end

  @doc """
  List all running Memory Managers under a specific supervisor.
  """
  @spec which_managers(Supervisor.supervisor()) :: [
          {term(), pid(), :worker | :supervisor, [module()]}
        ]
  def which_managers(supervisor) do
    DynamicSupervisor.which_children(supervisor)
  end

  @doc """
  Get the count of running Memory Managers.
  """
  @spec count_managers() :: non_neg_integer()
  def count_managers do
    count_managers(__MODULE__)
  end

  @doc """
  Get the count of running Memory Managers under a specific supervisor.
  """
  @spec count_managers(Supervisor.supervisor()) :: non_neg_integer()
  def count_managers(supervisor) do
    DynamicSupervisor.count_children(supervisor).workers
  end

  # Callbacks

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

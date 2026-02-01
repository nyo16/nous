defmodule Nous.Memory.Manager do
  @moduledoc """
  GenServer that orchestrates memory storage and search for a single agent.

  Each agent gets its own Memory Manager, providing isolated memory space.
  The Manager coordinates between storage backends and search indexes.

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────┐
  │           Nous.Memory.Manager (GenServer)               │
  │                                                         │
  │  State:                                                 │
  │    - agent_id: String.t()                               │
  │    - store: pid() (storage backend GenServer)           │
  │    - search: pid() | nil (search index GenServer)       │
  │    - config: keyword()                                  │
  └──────────┬────────────────────────────┬─────────────────┘
             │                            │
  ┌──────────▼──────────┐    ┌────────────▼────────────────┐
  │  Store GenServer    │    │   Search GenServer          │
  │  (implements Store) │    │   (implements Search)       │
  └─────────────────────┘    └─────────────────────────────┘
  ```

  ## Usage

      # Start a manager with default in-memory store
      {:ok, manager} = Nous.Memory.Manager.start_link(agent_id: "my_agent")

      # Start with custom store backend
      {:ok, store} = Nous.Memory.Stores.RocksdbStore.start_link(path: "/data/memories")
      {:ok, manager} = Nous.Memory.Manager.start_link(
        agent_id: "my_agent",
        store: store
      )

      # Store and recall memories
      {:ok, memory} = Nous.Memory.Manager.store(manager, "User prefers dark mode",
        tags: ["preference"],
        importance: :medium
      )

      {:ok, results} = Nous.Memory.Manager.recall(manager, "user preferences")

  ## Configuration

  - `:agent_id` - Required. Unique identifier for this agent's memory space.
  - `:store` - Storage backend pid or module (default: starts AgentStore)
  - `:store_opts` - Options passed to store on start
  - `:search` - Search backend pid, module, or nil for simple search
  - `:search_opts` - Options passed to search backend on start

  """

  use GenServer

  alias Nous.Memory
  alias Nous.Memory.Stores.AgentStore
  alias Nous.Memory.Search.Simple, as: SimpleSearch

  require Logger

  @type manager_ref :: pid() | atom() | GenServer.server()

  defstruct [:agent_id, :store, :search, :config]

  # Client API

  @doc """
  Start a Memory Manager for the given agent.

  ## Options

  - `:agent_id` - Required. Unique identifier for this agent.
  - `:store` - Storage backend (pid, module, or `{module, opts}`)
  - `:search` - Search backend (pid, module, `{module, opts}`, or nil)
  - `:name` - Optional name registration

  ## Examples

      # With defaults (in-memory store, simple search)
      {:ok, manager} = Manager.start_link(agent_id: "my_agent")

      # With custom store
      {:ok, manager} = Manager.start_link(
        agent_id: "my_agent",
        store: {RocksdbStore, path: "/data/agent_1"}
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Store a new memory.

  ## Options

  - `:tags` - List of tags for categorization
  - `:importance` - `:low`, `:medium`, `:high`, or `:critical`
  - `:source` - `:conversation`, `:user`, or `:system`
  - `:metadata` - Arbitrary key-value data

  Returns `{:ok, memory}` on success.
  """
  @spec store(manager_ref(), String.t(), keyword()) :: {:ok, Memory.t()} | {:error, term()}
  def store(manager, content, opts \\ []) do
    GenServer.call(manager, {:store, content, opts})
  end

  @doc """
  Recall memories matching the query.

  Uses the configured search backend to find relevant memories.

  ## Options

  - `:limit` - Maximum number of results (default: 10)
  - `:tags` - Filter by tags
  - `:importance` - Filter by minimum importance
  - `:include_scores` - Include relevance scores in results

  Returns `{:ok, [memory]}` on success.
  """
  @spec recall(manager_ref(), String.t(), keyword()) :: {:ok, [Memory.t()]} | {:error, term()}
  def recall(manager, query, opts \\ []) do
    GenServer.call(manager, {:recall, query, opts})
  end

  @doc """
  Get a specific memory by ID.

  Returns `{:ok, memory}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get(manager_ref(), term()) :: {:ok, Memory.t()} | {:error, :not_found | term()}
  def get(manager, id) do
    GenServer.call(manager, {:get, id})
  end

  @doc """
  Update an existing memory.

  ## Options

  - `:content` - New content
  - `:tags` - New tags (replaces existing)
  - `:importance` - New importance level
  - `:metadata` - New metadata (merged with existing)

  Returns `{:ok, memory}` on success.
  """
  @spec update(manager_ref(), term(), keyword()) :: {:ok, Memory.t()} | {:error, term()}
  def update(manager, id, updates) do
    GenServer.call(manager, {:update, id, updates})
  end

  @doc """
  Delete a memory by ID.

  Returns `:ok` on success.
  """
  @spec forget(manager_ref(), term()) :: :ok | {:error, term()}
  def forget(manager, id) do
    GenServer.call(manager, {:forget, id})
  end

  @doc """
  List all memories with optional filtering.

  ## Options

  - `:tags` - Filter by tags (memories with any matching tag)
  - `:importance` - Filter by minimum importance level
  - `:tier` - Filter by memory tier
  - `:limit` - Maximum number of memories to return
  - `:offset` - Number of memories to skip

  Returns `{:ok, [memory]}` on success.
  """
  @spec list(manager_ref(), keyword()) :: {:ok, [Memory.t()]} | {:error, term()}
  def list(manager, opts \\ []) do
    GenServer.call(manager, {:list, opts})
  end

  @doc """
  Clear memories with optional filtering.

  ## Options

  - `:tags` - Only clear memories with matching tags
  - `:tier` - Only clear memories in the specified tier

  Returns `{:ok, count}` with the number of deleted memories.
  """
  @spec clear(manager_ref(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear(manager, opts \\ []) do
    GenServer.call(manager, {:clear, opts})
  end

  @doc """
  Get the count of stored memories.
  """
  @spec count(manager_ref(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(manager, opts \\ []) do
    GenServer.call(manager, {:count, opts})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    store = start_store(opts)
    search = start_search(opts)

    state = %__MODULE__{
      agent_id: agent_id,
      store: store,
      search: search,
      config: opts
    }

    Logger.debug("Memory.Manager started for agent #{agent_id}")

    {:ok, state}
  end

  @impl true
  def handle_call({:store, content, opts}, _from, state) do
    memory = Memory.new(content, opts)

    with {:ok, stored} <- store_call(state.store, :store, [memory]),
         :ok <- index_memory(state.search, stored) do
      {:reply, {:ok, stored}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recall, query, opts}, _from, state) do
    result = search_memories(state, query, opts)
    {:reply, result, state}
  end

  def handle_call({:get, id}, _from, state) do
    case store_call(state.store, :get, [id]) do
      {:ok, memory} ->
        # Touch the memory to update access tracking
        touched = Memory.touch(memory)
        _ = store_call(state.store, :update, [touched])
        {:reply, {:ok, touched}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:update, id, updates}, _from, state) do
    with {:ok, memory} <- store_call(state.store, :get, [id]) do
      updated = apply_updates(memory, updates)

      with {:ok, stored} <- store_call(state.store, :update, [updated]),
           :ok <- update_search_index(state.search, stored) do
        {:reply, {:ok, stored}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:forget, id}, _from, state) do
    with :ok <- store_call(state.store, :delete, [id]),
         :ok <- delete_from_index(state.search, id) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    result = store_call(state.store, :list, [opts])
    {:reply, result, state}
  end

  def handle_call({:clear, opts}, _from, state) do
    with {:ok, count} <- store_call(state.store, :clear, [opts]),
         {:ok, _} <- clear_search_index(state.search) do
      {:reply, {:ok, count}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:count, opts}, _from, state) do
    result = store_call(state.store, :count, [opts])
    {:reply, result, state}
  end

  # Private functions

  defp start_store(opts) do
    case Keyword.get(opts, :store) do
      nil ->
        # Start default AgentStore
        {:ok, pid} = AgentStore.start_link([])
        pid

      pid when is_pid(pid) ->
        pid

      module when is_atom(module) ->
        {:ok, pid} = module.start_link(Keyword.get(opts, :store_opts, []))
        pid

      {module, store_opts} when is_atom(module) ->
        {:ok, pid} = module.start_link(store_opts)
        pid
    end
  end

  defp start_search(opts) do
    case Keyword.get(opts, :search) do
      nil ->
        # Start default SimpleSearch
        {:ok, pid} = SimpleSearch.start_link([])
        pid

      false ->
        # Explicitly disable search
        nil

      pid when is_pid(pid) ->
        pid

      module when is_atom(module) ->
        {:ok, pid} = module.start_link(Keyword.get(opts, :search_opts, []))
        pid

      {module, search_opts} when is_atom(module) ->
        {:ok, pid} = module.start_link(search_opts)
        pid
    end
  end

  defp store_call(store, function, args) do
    apply(GenServer, :call, [store, List.to_tuple([function | args])])
  end

  defp index_memory(nil, _memory), do: :ok

  defp index_memory(search, memory) do
    GenServer.call(search, {:index, memory})
  end

  defp update_search_index(nil, _memory), do: :ok

  defp update_search_index(search, memory) do
    GenServer.call(search, {:update, memory})
  end

  defp delete_from_index(nil, _id), do: :ok

  defp delete_from_index(search, id) do
    GenServer.call(search, {:delete, id})
  end

  defp clear_search_index(nil), do: {:ok, 0}

  defp clear_search_index(search) do
    GenServer.call(search, :clear)
  end

  defp search_memories(state, query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    tags = Keyword.get(opts, :tags)
    importance = Keyword.get(opts, :importance)

    case state.search do
      nil ->
        # No search backend, fall back to listing with filters
        filter_opts =
          [limit: limit]
          |> maybe_add(:tags, tags)
          |> maybe_add(:importance, importance)

        store_call(state.store, :list, [filter_opts])

      search ->
        # Use search backend
        search_opts =
          [limit: limit]
          |> maybe_add(:tags, tags)
          |> maybe_add(:importance, importance)

        case GenServer.call(search, {:search, query, search_opts}) do
          {:ok, results} ->
            # Extract memories from search results
            memories = Enum.map(results, & &1.memory)
            {:ok, memories}

          error ->
            error
        end
    end
  end

  defp apply_updates(memory, updates) do
    memory
    |> maybe_update_field(:content, Keyword.get(updates, :content))
    |> maybe_update_field(:tags, Keyword.get(updates, :tags))
    |> maybe_update_field(:importance, Keyword.get(updates, :importance))
    |> maybe_merge_metadata(Keyword.get(updates, :metadata))
    |> Map.put(:accessed_at, DateTime.utc_now())
  end

  defp maybe_update_field(memory, _field, nil), do: memory
  defp maybe_update_field(memory, field, value), do: Map.put(memory, field, value)

  defp maybe_merge_metadata(memory, nil), do: memory

  defp maybe_merge_metadata(memory, new_metadata) do
    Map.update!(memory, :metadata, &Map.merge(&1, new_metadata))
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end

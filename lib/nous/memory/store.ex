defmodule Nous.Memory.Store do
  @moduledoc """
  Behaviour for pluggable memory storage backends.

  Implement this behaviour to create custom storage backends for the memory system.
  Built-in implementations include:

  - `Nous.Memory.Stores.AgentStore` - ETS-backed in-memory store (testing, single session)
  - `Nous.Memory.Stores.MarkdownStore` - File-based markdown storage (human readable, Git-able)
  - `Nous.Memory.Stores.RocksdbStore` - High-performance persistent KV store

  ## Example Implementation

      defmodule MyApp.Memory.RedisStore do
        @behaviour Nous.Memory.Store

        @impl true
        def start_link(opts) do
          # Initialize Redis connection
          GenServer.start_link(__MODULE__, opts, name: opts[:name])
        end

        @impl true
        def store(pid, memory) do
          GenServer.call(pid, {:store, memory})
        end

        @impl true
        def get(pid, id) do
          GenServer.call(pid, {:get, id})
        end

        # ... implement other callbacks
      end

  ## Using a Custom Store

      {:ok, store} = MyApp.Memory.RedisStore.start_link(url: "redis://localhost")

      {:ok, manager} = Nous.Memory.Manager.start_link(
        agent_id: "my_agent",
        store: store  # Pass the store pid
      )

  """

  alias Nous.Memory

  @type store_ref :: pid() | atom() | GenServer.server()

  @doc """
  Start the store process.

  Returns `{:ok, pid}` on success.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Store a memory.

  Returns `{:ok, memory}` with any store-assigned fields (like ID) on success,
  or `{:error, reason}` on failure.
  """
  @callback store(store_ref(), Memory.t()) :: {:ok, Memory.t()} | {:error, term()}

  @doc """
  Get a memory by ID.

  Returns `{:ok, memory}` if found, or `{:error, :not_found}` if not.
  """
  @callback get(store_ref(), id :: term()) :: {:ok, Memory.t()} | {:error, :not_found | term()}

  @doc """
  Update an existing memory.

  Returns `{:ok, memory}` on success, or `{:error, reason}` on failure.
  """
  @callback update(store_ref(), Memory.t()) :: {:ok, Memory.t()} | {:error, term()}

  @doc """
  Delete a memory by ID.

  Returns `:ok` on success (including if the memory didn't exist),
  or `{:error, reason}` on failure.
  """
  @callback delete(store_ref(), id :: term()) :: :ok | {:error, term()}

  @doc """
  List memories with optional filtering.

  ## Options

  - `:tags` - Filter by tags (memories with any matching tag)
  - `:importance` - Filter by minimum importance level
  - `:tier` - Filter by memory tier
  - `:limit` - Maximum number of memories to return
  - `:offset` - Number of memories to skip

  Returns `{:ok, [memory]}` on success.
  """
  @callback list(store_ref(), opts :: keyword()) :: {:ok, [Memory.t()]} | {:error, term()}

  @doc """
  Clear memories with optional filtering.

  ## Options

  - `:tags` - Only clear memories with matching tags
  - `:tier` - Only clear memories in the specified tier
  - `:before` - Only clear memories created before this DateTime

  Returns `{:ok, count}` with the number of deleted memories on success.
  """
  @callback clear(store_ref(), opts :: keyword()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Get the count of stored memories.

  ## Options

  Same filtering options as `list/2`.
  """
  @callback count(store_ref(), opts :: keyword()) :: {:ok, non_neg_integer()} | {:error, term()}

  # Optional callbacks with default implementations

  @doc """
  Check if the store supports a specific feature.

  Features include:
  - `:persistence` - Data survives process restarts
  - `:transactions` - Atomic multi-operation support
  - `:embeddings` - Native embedding storage

  Default implementation returns false for all features.
  """
  @callback supports?(store_ref(), feature :: atom()) :: boolean()

  @optional_callbacks [supports?: 2]

  @doc """
  Default implementation of supports?/2 that returns false.
  """
  def supports?(_store_ref, _feature), do: false
end

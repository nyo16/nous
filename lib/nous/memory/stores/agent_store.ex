defmodule Nous.Memory.Stores.AgentStore do
  @moduledoc """
  ETS-backed in-memory storage backend for the memory system.

  This store is ideal for:
  - Testing and development
  - Single-session memory (memory is lost when process stops)
  - Quick prototyping without external dependencies

  ## Usage

      {:ok, store} = AgentStore.start_link()

      # Store a memory
      memory = Nous.Memory.new("User prefers dark mode", tags: ["preference"])
      {:ok, stored} = AgentStore.store(store, memory)

      # Get by ID
      {:ok, retrieved} = AgentStore.get(store, stored.id)

      # List with filters
      {:ok, memories} = AgentStore.list(store, tags: ["preference"])

  ## Note

  Data is stored in an ETS table owned by the GenServer process.
  When the process terminates, all data is lost.
  For persistent storage, use `RocksdbStore` or `MarkdownStore`.

  """

  @behaviour Nous.Memory.Store

  use GenServer

  alias Nous.Memory

  # Client API

  @impl Nous.Memory.Store
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Nous.Memory.Store
  def store(store, %Memory{} = memory) do
    GenServer.call(store, {:store, memory})
  end

  @impl Nous.Memory.Store
  def get(store, id) do
    GenServer.call(store, {:get, id})
  end

  @impl Nous.Memory.Store
  def update(store, %Memory{} = memory) do
    GenServer.call(store, {:update, memory})
  end

  @impl Nous.Memory.Store
  def delete(store, id) do
    GenServer.call(store, {:delete, id})
  end

  @impl Nous.Memory.Store
  def list(store, opts \\ []) do
    GenServer.call(store, {:list, opts})
  end

  @impl Nous.Memory.Store
  def clear(store, opts \\ []) do
    GenServer.call(store, {:clear, opts})
  end

  @impl Nous.Memory.Store
  def count(store, opts \\ []) do
    GenServer.call(store, {:count, opts})
  end

  @impl Nous.Memory.Store
  def supports?(_store, feature) do
    feature in [:in_memory]
  end

  # Server Callbacks

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:memories, [:set, :private])
    {:ok, %{table: table, next_id: 1}}
  end

  @impl GenServer
  def handle_call({:store, memory}, _from, state) do
    # Ensure ID is set
    memory =
      if memory.id do
        memory
      else
        %{memory | id: state.next_id}
      end

    :ets.insert(state.table, {memory.id, memory})

    next_id =
      if is_integer(memory.id) and memory.id >= state.next_id do
        memory.id + 1
      else
        state.next_id
      end

    {:reply, {:ok, memory}, %{state | next_id: next_id}}
  end

  def handle_call({:get, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, memory}] -> {:reply, {:ok, memory}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, memory}, _from, state) do
    case :ets.lookup(state.table, memory.id) do
      [{_, _existing}] ->
        :ets.insert(state.table, {memory.id, memory})
        {:reply, {:ok, memory}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    :ets.delete(state.table, id)
    {:reply, :ok, state}
  end

  def handle_call({:list, opts}, _from, state) do
    memories =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, memory} -> memory end)
      |> apply_filters(opts)
      |> apply_pagination(opts)

    {:reply, {:ok, memories}, state}
  end

  def handle_call({:clear, opts}, _from, state) do
    if Enum.empty?(opts) do
      # Clear all
      count = :ets.info(state.table, :size)
      :ets.delete_all_objects(state.table)
      {:reply, {:ok, count}, state}
    else
      # Clear with filters
      memories =
        state.table
        |> :ets.tab2list()
        |> Enum.map(fn {_id, memory} -> memory end)
        |> apply_filters(opts)

      Enum.each(memories, fn memory ->
        :ets.delete(state.table, memory.id)
      end)

      {:reply, {:ok, length(memories)}, state}
    end
  end

  def handle_call({:count, opts}, _from, state) do
    count =
      if Enum.empty?(opts) do
        :ets.info(state.table, :size)
      else
        state.table
        |> :ets.tab2list()
        |> Enum.map(fn {_id, memory} -> memory end)
        |> apply_filters(opts)
        |> length()
      end

    {:reply, {:ok, count}, state}
  end

  # Private functions

  defp apply_filters(memories, opts) do
    memories
    |> filter_by_tags(Keyword.get(opts, :tags))
    |> filter_by_importance(Keyword.get(opts, :importance))
    |> filter_by_tier(Keyword.get(opts, :tier))
  end

  defp filter_by_tags(memories, nil), do: memories
  defp filter_by_tags(memories, []), do: memories

  defp filter_by_tags(memories, tags) do
    Enum.filter(memories, fn memory ->
      Enum.any?(tags, &(&1 in memory.tags))
    end)
  end

  defp filter_by_importance(memories, nil), do: memories

  defp filter_by_importance(memories, min_importance) do
    Enum.filter(memories, fn memory ->
      Memory.matches_importance?(memory, min_importance)
    end)
  end

  defp filter_by_tier(memories, nil), do: memories

  defp filter_by_tier(memories, tier) do
    Enum.filter(memories, &(&1.tier == tier))
  end

  defp apply_pagination(memories, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)

    memories
    |> Enum.drop(offset)
    |> then(fn m -> if limit, do: Enum.take(m, limit), else: m end)
  end
end

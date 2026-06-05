defmodule Nous.Persistence.ETS do
  @moduledoc """
  ETS-based persistence backend.

  Stores serialized context data in a named ETS table. The table is owned
  by a dedicated GenServer started under the Nous application supervisor,
  so the table outlives transient callers - previously the table died
  with whichever process happened to call save/load first.

  Data does not survive node restarts. Useful for development, testing,
  and short-lived sessions.

  ## Usage

      # In AgentServer config
      AgentServer.start_link(
        session_id: "session_123",
        agent_config: %{model: "openai:gpt-4", instructions: "Be helpful"},
        persistence: Nous.Persistence.ETS
      )

  """

  @behaviour Nous.Persistence

  @table :nous_persistence

  defmodule TableOwner do
    @moduledoc false
    use GenServer

    @table :nous_persistence

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    @impl true
    def init(:ok) do
      table =
        case :ets.whereis(@table) do
          :undefined ->
            # :protected — only this owner process writes; any process may read.
            # Previously :public let any in-node process read/overwrite another
            # session's serialized context (and persisted deps).
            :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

          _ref ->
            @table
        end

      {:ok, %{table: table}}
    end

    @impl true
    def handle_call({:save, session_id, data}, _from, %{table: table} = state) do
      # :ets.insert/2 into this owner's validated :protected table cannot fail in
      # normal operation (it only raises on a bad table reference). Don't wrap it
      # in try/rescue — that would mask a genuine bug (wrong table) as a confusing
      # {:ets_insert_failed, _}. Let it crash so the supervisor restarts clean.
      true = :ets.insert(table, {session_id, data})
      {:reply, :ok, state}
    end

    def handle_call({:delete, session_id}, _from, %{table: table} = state) do
      :ets.delete(table, session_id)
      {:reply, :ok, state}
    end

    def handle_call(:clear, _from, %{table: table} = state) do
      :ets.delete_all_objects(table)
      {:reply, :ok, state}
    end
  end

  @doc false
  def child_spec(_opts) do
    %{id: __MODULE__, start: {TableOwner, :start_link, [[]]}, type: :worker}
  end

  @impl true
  def save(session_id, data) when is_binary(session_id) and is_map(data) do
    GenServer.call(owner(), {:save, session_id, data})
  end

  @impl true
  def load(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(session_id) when is_binary(session_id) do
    GenServer.call(owner(), {:delete, session_id})
  end

  @impl true
  def list do
    ensure_table()
    keys = :ets.foldl(fn {key, _val}, acc -> [key | acc] end, [], @table)
    {:ok, keys}
  end

  @doc """
  Remove all persisted sessions. Routed through the owner (the table is
  `:protected`, so only the owner may write). Useful for tests.
  """
  def clear do
    GenServer.call(owner(), :clear)
  end

  # The table is owned by the supervised TableOwner (started in
  # Nous.Application). Resolve it, starting one on demand for ad-hoc callers
  # that run before/without the supervisor (mainly tests).
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

  # Reads are allowed from any process under :protected; just make sure the
  # owner (and therefore the table) exists.
  defp ensure_table, do: owner()
end

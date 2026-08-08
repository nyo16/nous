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

    # Unbounded growth (P-2): this table is owned by a supervised GenServer that
    # lives for the node's lifetime and retains every session's full serialized
    # message history. Bound it on both axes, because either alone leaves a
    # hole: a TTL does not stop a burst of short-lived sessions inside the
    # window, and a size cap alone lets one idle session pin memory forever.
    #
    # Defaults are deliberately loose so no existing user notices an eviction:
    # 24h is far longer than the dev/test sessions this backend is scoped to,
    # and 10_000 retained sessions is orders of magnitude past normal use.
    # Override (either bound may be :infinity to disable it):
    #
    #     config :nous, :persistence_ets,
    #       ttl: :timer.hours(1),
    #       max_entries: 500,
    #       sweep_interval: :timer.minutes(1)
    @default_ttl :timer.hours(24)
    @default_max_entries 10_000
    @default_sweep_interval :timer.minutes(5)

    @spec start_link(keyword()) :: GenServer.on_start()
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

      opts = Application.get_env(:nous, :persistence_ets, [])

      state = %{
        table: table,
        ttl: Keyword.get(opts, :ttl, @default_ttl),
        max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
        sweep_interval: Keyword.get(opts, :sweep_interval, @default_sweep_interval)
      }

      schedule_sweep(state)

      {:ok, state}
    end

    @impl true
    def handle_call({:save, session_id, data}, _from, %{table: table} = state) do
      # :ets.insert/2 into this owner's validated :protected table cannot fail in
      # normal operation (it only raises on a bad table reference). Don't wrap it
      # in try/rescue — that would mask a genuine bug (wrong table) as a confusing
      # {:ets_insert_failed, _}. Let it crash so the supervisor restarts clean.
      true = :ets.insert(table, {session_id, data, System.monotonic_time(:millisecond)})
      enforce_max_entries(state)
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

    @impl true
    def handle_info(:sweep, state) do
      expire(state)
      schedule_sweep(state)
      {:noreply, state}
    end

    # Defining any handle_info/2 clause overrides the one `use GenServer`
    # injects, so the catch-all has to be explicit or a stray message crashes
    # the owner and takes the whole table with it.
    def handle_info(_msg, state), do: {:noreply, state}

    defp schedule_sweep(%{ttl: :infinity}), do: :ok

    defp schedule_sweep(%{sweep_interval: interval}) do
      Process.send_after(self(), :sweep, interval)
      :ok
    end

    # TTL sweep. `saved_at` is write time, not access time: load/1 reads ETS
    # directly from the caller process (the whole point of :protected +
    # read_concurrency), so refreshing it on read would put a write through this
    # owner on every read. Eviction is therefore least-recently-*written*.
    defp expire(%{ttl: :infinity}), do: 0

    defp expire(%{table: table, ttl: ttl}) do
      cutoff = System.monotonic_time(:millisecond) - ttl
      :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end

    defp enforce_max_entries(%{max_entries: :infinity}), do: :ok

    defp enforce_max_entries(%{table: table, max_entries: max}) do
      case :ets.info(table, :size) - max do
        over when over > 0 ->
          # Trim in one batch down to ~90% of the cap instead of one row per
          # over-cap save: finding the oldest rows in a :set is an O(n) scan, so
          # a block eviction amortizes it over ~max/10 saves rather than paying
          # it on every single save once the table is full.
          drop = over + div(max, 10)

          table
          |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$2", :"$1"}}]}])
          |> Enum.sort()
          |> Enum.take(drop)
          |> Enum.each(fn {_saved_at, session_id} -> :ets.delete(table, session_id) end)

        _ ->
          :ok
      end
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
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
      [{^session_id, data, _saved_at}] -> {:ok, data}
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
    keys = :ets.foldl(fn {key, _val, _saved_at}, acc -> [key | acc] end, [], @table)
    {:ok, keys}
  end

  @doc """
  Remove all persisted sessions. Routed through the owner (the table is
  `:protected`, so only the owner may write). Useful for tests.
  """
  @spec clear() :: :ok
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

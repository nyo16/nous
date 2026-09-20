defmodule Nous.Persistence.ETS do
  @moduledoc """
  ETS-based persistence backend.

  Stores serialized context data in a named ETS table. The table is owned
  by a dedicated GenServer started under the Nous application supervisor,
  so the table outlives transient callers - previously the table died
  with whichever process happened to call save/load first.

  Reads AND writes go straight to ETS from the calling process; the owner
  exists to keep the table alive, sweep expired sessions, and enforce the
  size cap. Routing every `save/2` through the owner as a `GenServer.call`
  used to copy a serialized context three times (caller → owner mailbox →
  ETS) and serialise all writers behind one process.

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

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    @impl true
    def init(:ok) do
      table =
        case :ets.whereis(@table) do
          :undefined ->
            # :public so save/delete/clear insert from the CALLER (one copy,
            # straight into ETS) instead of a GenServer.call that copies the
            # serialized context into this process's mailbox first and then
            # into ETS, with every writer queued behind one owner. This does
            # not widen the trust boundary: the API itself has no per-session
            # authorisation, so any in-node process could already overwrite
            # another session through `save/2` — :protected only ever stopped
            # a direct `:ets.insert`, which the same process could reach by
            # calling the public function. write_concurrency because the
            # writers really are concurrent now (one per agent process).
            :ets.new(@table, [
              :named_table,
              :set,
              :public,
              read_concurrency: true,
              write_concurrency: true
            ])

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

    # The cap check is an O(1) :ets.info(size) unless the table is over the
    # cap, so a cast per save is cheap; it keeps the trim off the caller's
    # critical path and serialises the (rare) O(n) eviction in one process.
    @impl true
    def handle_cast(:enforce_max_entries, state) do
      enforce_max_entries(state)
      {:noreply, state}
    end

    # `sync/0` exists so callers that need "every cast before this point has
    # been processed" (tests asserting on the cap) can wait for it.
    @impl true
    def handle_call(:sync, _from, state), do: {:reply, :ok, state}

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
  def child_spec(_opts) do
    %{id: __MODULE__, start: {TableOwner, :start_link, [[]]}, type: :worker}
  end

  @impl true
  def save(session_id, data) when is_binary(session_id) and is_map(data) do
    owner = owner()
    # :ets.insert/2 into the owner's :public table cannot fail in normal
    # operation (it only raises on a bad table reference). Don't rescue —
    # that would mask a genuine bug as a confusing error tuple.
    true = :ets.insert(@table, {session_id, data, System.monotonic_time(:millisecond)})
    GenServer.cast(owner, :enforce_max_entries)
    :ok
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
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  @impl true
  def list do
    ensure_table()
    keys = :ets.foldl(fn {key, _val, _saved_at}, acc -> [key | acc] end, [], @table)
    {:ok, keys}
  end

  @doc """
  Remove all persisted sessions. Useful for tests.
  """
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Block until the owner has processed every size-cap check queued before
  this call. Only needed by callers that want to observe the cap
  synchronously (tests); `save/2` itself never waits for it.
  """
  @spec sync() :: :ok
  def sync, do: GenServer.call(owner(), :sync)

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

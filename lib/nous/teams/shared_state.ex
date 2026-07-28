defmodule Nous.Teams.SharedState do
  @moduledoc """
  ETS-based shared state for per-team discoveries and file region claims.

  Owns an ETS table that stores:
  - **Discoveries** — findings shared by agents (topic, content, timestamp)
  - **Region claims** — file region locks to prevent editing conflicts

  ## Architecture

  Each team gets its own `SharedState` GenServer. The ETS table is owned by this
  process and destroyed when the process terminates. Claims auto-expire after a
  configurable timeout (default 5 minutes).

  ## Quick Start

      {:ok, pid} = SharedState.start_link(team_id: "team_1")

      SharedState.share_discovery(pid, "alice", %{topic: "Bug in parser", content: "Found null check missing"})
      SharedState.get_discoveries(pid)

      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      {:error, :conflict} = SharedState.claim_region(pid, "bob", "lib/parser.ex", 15, 25)
      :ok = SharedState.release_region(pid, "alice", "lib/parser.ex")
  """

  use GenServer

  @default_claim_ttl :timer.minutes(5)

  # Discoveries used to live for the whole team lifetime while only claims
  # expired (P-2: "never prunes"). One hour is deliberately generous — longer
  # than any realistic single team run, so no existing caller loses a
  # discovery it would still have read — while still bounding a long-lived
  # supervised team. Pass `discovery_ttl: :infinity` to opt out.
  @default_discovery_ttl :timer.hours(1)

  # Client API

  @doc """
  Start a SharedState process for a team.

  ## Options

  - `:team_id` (required) — unique identifier for the team
  - `:claim_ttl` — claim expiration in ms (default: 5 minutes)
  - `:discovery_ttl` — discovery expiration in ms, or `:infinity` (default: 1 hour)
  - `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Nous.Util.split_gen_opts(opts)
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Store a discovery from an agent.

  The discovery map should contain `:topic` and `:content` keys. A timestamp
  is automatically added.

  ## Examples

      SharedState.share_discovery(pid, "alice", %{topic: "Bug", content: "Null check missing"})
  """
  @spec share_discovery(pid(), String.t(), map()) :: :ok
  def share_discovery(pid, agent_name, discovery_map) do
    GenServer.call(pid, {:share_discovery, agent_name, discovery_map})
  end

  @doc """
  Retrieve all discoveries stored for this team.

  Returns a list of maps with `:agent`, `:topic`, `:content`, and `:timestamp` keys.

  ## Examples

      discoveries = SharedState.get_discoveries(pid)
      # [%{agent: "alice", topic: "Bug", content: "...", timestamp: ~U[...]}]
  """
  @spec get_discoveries(pid()) :: [map()]
  def get_discoveries(server) do
    # Runs in the CALLER against the :protected table — no handle_call. The
    # table is an :ordered_set keyed by {:discovery, seq}, so select traverses
    # in seq order and the old per-read Enum.sort_by is gone.
    :ets.select(table_for(server), [{{{:discovery, :_}, :"$1"}, [], [:"$1"]}])
  end

  @doc """
  Claim a file region for exclusive editing.

  Returns `:ok` if the claim succeeds, or `{:error, :conflict}` if the region
  overlaps with an existing claim by a different agent.

  ## Examples

      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      {:error, :conflict} = SharedState.claim_region(pid, "bob", "lib/parser.ex", 15, 25)
  """
  @spec claim_region(pid(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :conflict}
  def claim_region(pid, agent_name, file_path, start_line, end_line) do
    GenServer.call(pid, {:claim_region, agent_name, file_path, start_line, end_line})
  end

  @doc """
  Release all region claims for an agent on a specific file.

  ## Examples

      :ok = SharedState.release_region(pid, "alice", "lib/parser.ex")
  """
  @spec release_region(pid(), String.t(), String.t()) :: :ok
  def release_region(pid, agent_name, file_path) do
    GenServer.call(pid, {:release_region, agent_name, file_path})
  end

  @doc """
  Get all current region claims.

  Returns a list of maps with `:agent`, `:file`, `:start_line`, `:end_line`,
  and `:expires_at` keys.

  ## Examples

      claims = SharedState.get_claims(pid)
      # [%{agent: "alice", file: "lib/parser.ex", start_line: 10, end_line: 20, expires_at: ~U[...]}]
  """
  @spec get_claims(pid()) :: [map()]
  def get_claims(server) do
    # Runs in the CALLER (see get_discoveries/1). Claims are keyed by
    # {agent, file}, so :ordered_set order is lexicographic rather than
    # insertion order — the stored seq still decides the returned order.
    table_for(server)
    |> :ets.select([{{{:claim, :_, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.sort_by(fn {seq, _claim} -> seq end)
    |> Enum.map(fn {_seq, claim} -> claim end)
  end

  # Server

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    claim_ttl = Keyword.get(opts, :claim_ttl, @default_claim_ttl)
    discovery_ttl = Keyword.get(opts, :discovery_ttl, @default_discovery_ttl)

    # One ETS row PER entry instead of a single growing list term:
    #   {{:discovery, seq}, entry}            — discoveries, ordered by seq
    #   {{:claim, agent, file}, {seq, claim}} — claims, unique per agent+file
    # The old single-row-list design copied the entire growing list term on
    # every :ets.insert (O(n) per write, O(n^2) accumulation). Per-row writes
    # are O(1) and claim conflict checks become a file-scoped :ets.select.
    # Constant atom: without :named_table the name is cosmetic, and a
    # per-team :"team_state_#{team_id}" atom would leak (atoms are never GC'd).
    #
    # P-2: was [:set, :private], which forced every read through handle_call —
    # the whole team serialized behind one mailbox for what are pure reads.
    # :protected keeps writes owner-only while letting reads run concurrently
    # in the caller; :ordered_set makes discovery reads come back in seq order
    # for free; read_concurrency because reads now vastly outnumber writes.
    table = :ets.new(:team_state, [:ordered_set, :protected, read_concurrency: true])

    {:ok,
     %{
       team_id: team_id,
       table: table,
       claim_ttl: claim_ttl,
       discovery_ttl: discovery_ttl,
       expiry_timers: %{},
       seq: 0
     }}
  end

  @impl true
  def handle_call({:share_discovery, agent_name, discovery_map}, _from, state) do
    entry = %{
      agent: agent_name,
      topic: Map.get(discovery_map, :topic, Map.get(discovery_map, "topic")),
      content: Map.get(discovery_map, :content, Map.get(discovery_map, "content")),
      timestamp: DateTime.utc_now()
    }

    # O(1) per-row insert keyed by a monotonic seq (preserves insertion order
    # on read) — no list term copied.
    :ets.insert(state.table, {{:discovery, state.seq}, entry})

    # Bound the discovery set with the same Process.send_after mechanism
    # claims already use, rather than adding a second eviction scheme.
    schedule_discovery_expiry(state.seq, state.discovery_ttl)

    {:reply, :ok, %{state | seq: state.seq + 1}}
  end

  @impl true
  def handle_call(:get_table, _from, state) do
    # Reads happen in the caller; they only need the tid. Callers resolve it
    # through here once and cache it — see table_for/1.
    {:reply, state.table, state}
  end

  @impl true
  def handle_call({:claim_region, agent_name, file_path, start_line, end_line}, _from, state) do
    # Conflict = an OTHER agent's claim on the SAME file with an overlapping
    # range. Scope to the file + exclude self in ETS (matchspec on the key),
    # then refine overlap in Elixir over just that small set — instead of
    # scanning every claim across all files.
    same_file_other_claims =
      :ets.select(state.table, [
        {{{:claim, :"$1", file_path}, :"$2"}, [{:"/=", :"$1", agent_name}], [:"$2"]}
      ])

    conflict? =
      Enum.any?(same_file_other_claims, fn {_seq, claim} ->
        ranges_overlap?(claim.start_line, claim.end_line, start_line, end_line)
      end)

    if conflict? do
      {:reply, {:error, :conflict}, state}
    else
      expires_at = DateTime.add(DateTime.utc_now(), state.claim_ttl, :millisecond)
      claim_key = {agent_name, file_path}

      new_claim = %{
        agent: agent_name,
        file: file_path,
        start_line: start_line,
        end_line: end_line,
        expires_at: expires_at
      }

      # Keyed by {:claim, agent, file}, so re-claiming the same file by the same
      # agent overwrites the prior claim (the old explicit dedup). seq preserves
      # insertion order for get_claims.
      :ets.insert(state.table, {{:claim, agent_name, file_path}, {state.seq, new_claim}})
      state = %{state | seq: state.seq + 1}

      # Cancel any existing expiry timer for this agent+file
      state = cancel_timer(state, claim_key)

      # Schedule expiry
      timer_ref = Process.send_after(self(), {:expire_claim, claim_key}, state.claim_ttl)
      state = put_in(state.expiry_timers[claim_key], timer_ref)

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:release_region, agent_name, file_path}, _from, state) do
    # O(1) delete by key (claims are unique per agent+file).
    :ets.delete(state.table, {:claim, agent_name, file_path})

    claim_key = {agent_name, file_path}
    state = cancel_timer(state, claim_key)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:expire_claim, {agent_name, file_path}}, state) do
    :ets.delete(state.table, {:claim, agent_name, file_path})

    state = %{state | expiry_timers: Map.delete(state.expiry_timers, {agent_name, file_path})}
    {:noreply, state}
  end

  @impl true
  def handle_info({:expire_discovery, seq}, state) do
    # Mirrors {:expire_claim, _} above. No expiry_timers bookkeeping: unlike a
    # claim, a discovery is never re-keyed or released, so its timer is never
    # cancelled and there is nothing to track.
    :ets.delete(state.table, {:discovery, seq})
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  # Private

  defp ranges_overlap?(s1, e1, s2, e2), do: s1 <= e2 and s2 <= e1

  defp schedule_discovery_expiry(_seq, :infinity), do: :ok

  defp schedule_discovery_expiry(seq, ttl) do
    Process.send_after(self(), {:expire_discovery, seq}, ttl)
    :ok
  end

  # Reads run in the caller process against the :protected table instead of
  # serializing behind the owner's mailbox (P-2). Callers hold only a pid or a
  # registered name, so resolve the tid once per caller process and cache it in
  # the process dictionary: one GenServer.call on a caller's first read, direct
  # concurrent ETS reads for every read after that.
  defp table_for(server) do
    case GenServer.whereis(server) do
      owner when is_pid(owner) and node(owner) == node() ->
        cached_table(server, owner)

      # Unregistered name, or a remote/{name, node} reference whose table id
      # would mean nothing locally: pay the round-trip. An unregistered name
      # still exits :noproc here, exactly as the old call-per-read did.
      _ ->
        GenServer.call(server, :get_table)
    end
  end

  # The cache is validated, not trusted: ETS reuses table identifiers, so a tid
  # cached before an owner crash could otherwise alias an unrelated table.
  # :ets.info(tid, :owner) is an O(1) BIF returning :undefined for a dead table,
  # so any mismatch just re-resolves through the (restarted) owner.
  defp cached_table(server, owner) do
    key = {__MODULE__, :table, owner}

    case Process.get(key) do
      nil ->
        table = GenServer.call(server, :get_table)
        Process.put(key, table)
        table

      table ->
        if :ets.info(table, :owner) == owner do
          table
        else
          Process.delete(key)
          cached_table(server, owner)
        end
    end
  end

  defp cancel_timer(state, key) do
    case Map.get(state.expiry_timers, key) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        %{state | expiry_timers: Map.delete(state.expiry_timers, key)}
    end
  end
end

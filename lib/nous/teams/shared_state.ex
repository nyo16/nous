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

  # Client API

  @doc """
  Start a SharedState process for a team.

  ## Options

  - `:team_id` (required) — unique identifier for the team
  - `:claim_ttl` — claim expiration in ms (default: 5 minutes)
  - `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = split_gen_opts(opts)
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
  def get_discoveries(pid) do
    GenServer.call(pid, :get_discoveries)
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
  def get_claims(pid) do
    GenServer.call(pid, :get_claims)
  end

  # Server

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    claim_ttl = Keyword.get(opts, :claim_ttl, @default_claim_ttl)

    table = :ets.new(:"team_state_#{team_id}", [:set, :private])

    # Initialize discovery list and claims list
    :ets.insert(table, {:discoveries, []})
    :ets.insert(table, {:claims, []})

    {:ok, %{team_id: team_id, table: table, claim_ttl: claim_ttl, expiry_timers: %{}}}
  end

  @impl true
  def handle_call({:share_discovery, agent_name, discovery_map}, _from, state) do
    entry = %{
      agent: agent_name,
      topic: Map.get(discovery_map, :topic, Map.get(discovery_map, "topic")),
      content: Map.get(discovery_map, :content, Map.get(discovery_map, "content")),
      timestamp: DateTime.utc_now()
    }

    [{:discoveries, discoveries}] = :ets.lookup(state.table, :discoveries)
    :ets.insert(state.table, {:discoveries, discoveries ++ [entry]})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_discoveries, _from, state) do
    [{:discoveries, discoveries}] = :ets.lookup(state.table, :discoveries)
    {:reply, discoveries, state}
  end

  @impl true
  def handle_call({:claim_region, agent_name, file_path, start_line, end_line}, _from, state) do
    [{:claims, claims}] = :ets.lookup(state.table, :claims)

    conflict? =
      Enum.any?(claims, fn claim ->
        claim.file == file_path and
          claim.agent != agent_name and
          ranges_overlap?(claim.start_line, claim.end_line, start_line, end_line)
      end)

    if conflict? do
      {:reply, {:error, :conflict}, state}
    else
      # Remove any existing claim by this agent on this file
      claims = Enum.reject(claims, &(&1.file == file_path and &1.agent == agent_name))

      expires_at = DateTime.add(DateTime.utc_now(), state.claim_ttl, :millisecond)
      claim_key = {agent_name, file_path}

      new_claim = %{
        agent: agent_name,
        file: file_path,
        start_line: start_line,
        end_line: end_line,
        expires_at: expires_at
      }

      :ets.insert(state.table, {:claims, claims ++ [new_claim]})

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
    [{:claims, claims}] = :ets.lookup(state.table, :claims)
    claims = Enum.reject(claims, &(&1.file == file_path and &1.agent == agent_name))
    :ets.insert(state.table, {:claims, claims})

    claim_key = {agent_name, file_path}
    state = cancel_timer(state, claim_key)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_claims, _from, state) do
    [{:claims, claims}] = :ets.lookup(state.table, :claims)
    {:reply, claims, state}
  end

  @impl true
  def handle_info({:expire_claim, {agent_name, file_path}}, state) do
    [{:claims, claims}] = :ets.lookup(state.table, :claims)
    claims = Enum.reject(claims, &(&1.file == file_path and &1.agent == agent_name))
    :ets.insert(state.table, {:claims, claims})

    state = %{state | expiry_timers: Map.delete(state.expiry_timers, {agent_name, file_path})}
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

  defp split_gen_opts(opts) do
    case Keyword.pop(opts, :name) do
      {nil, rest} -> {[], rest}
      {name, rest} -> {[name: name], rest}
    end
  end

  defp ranges_overlap?(s1, e1, s2, e2), do: s1 <= e2 and s2 <= e1

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

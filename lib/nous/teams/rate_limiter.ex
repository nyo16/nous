defmodule Nous.Teams.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for per-team and per-agent usage control.

  Tracks token usage and enforces budget limits and rate limits (requests
  per minute, tokens per minute) for a team's agents.

  ## Architecture

  Each team optionally gets its own `RateLimiter` GenServer. Agents call
  `acquire/3` BEFORE making an LLM request to atomically reserve an
  estimated token count + 1 request slot. After the call completes, the
  agent calls `record_usage/3` with the reservation ref to reconcile
  actual vs estimated; if the call errored before completing, the agent
  calls `release/2` to refund the reservation.

  Pre-deduction is what makes the limiter race-safe under concurrent
  acquires (M-9): without it, two callers could both see "budget remaining"
  before either's usage was recorded.

  ## Quick Start

      {:ok, pid} = RateLimiter.start_link(
        team_id: "team_1",
        budget: 10.0,
        per_agent_budget: 5.0,
        rpm: 60,
        tpm: 100_000
      )

      # Reserve, run, reconcile:
      {:ok, ref} = RateLimiter.acquire(pid, "alice", 1000)

      case do_llm_call(...) do
        {:ok, response} ->
          actual_tokens = response.usage.total_tokens
          actual_cost = response.usage.cost
          RateLimiter.record_usage(pid, "alice", %{
            tokens: actual_tokens, cost: actual_cost, reservation: ref
          })

        {:error, _} ->
          RateLimiter.release(pid, ref)
      end

  ## Backward compatibility

  `record_usage/3` called WITHOUT a `:reservation` key still works as
  post-hoc accounting (legacy semantics). This keeps direct usage like
  `RateLimiter.record_usage(pid, "alice", %{tokens: 500})` valid for
  callers that don't go through `acquire`.

  Reservations that are never reconciled or released are pruned after
  `:reservation_ttl_ms` (default 5 minutes) with a `Logger.warning/1`,
  so a missing `release/2` doesn't leak budget forever.

  ## Configuration

  - `:budget` — team-wide budget in USD (default: `:infinity`)
  - `:per_agent_budget` — per-agent budget in USD (default: `:infinity`)
  - `:rpm` — requests per minute limit (default: `:infinity`)
  - `:tpm` — tokens per minute limit (default: `:infinity`)
  - `:reservation_ttl_ms` — reservation expiry (default: 300_000 = 5 min)
  """

  use GenServer

  require Logger

  @type reservation_ref :: reference()

  @type status :: %{
          budget_remaining: float() | :infinity,
          agents: %{
            String.t() => %{cost: float(), tokens: non_neg_integer(), requests: non_neg_integer()}
          },
          open_reservations: non_neg_integer()
        }

  @default_reservation_ttl_ms 300_000

  # Client API

  @doc """
  Start a RateLimiter for a team.

  ## Options

  - `:team_id` (required) — unique identifier for the team
  - `:budget` — total team budget in USD (default: `:infinity`)
  - `:per_agent_budget` — per-agent budget in USD (default: `:infinity`)
  - `:rpm` — requests per minute (default: `:infinity`)
  - `:tpm` — tokens per minute (default: `:infinity`)
  - `:reservation_ttl_ms` — reservation expiry (default: 300_000)
  - `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = split_gen_opts(opts)
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Atomically reserve `tokens` and 1 request for `agent_name`.

  Returns `{:ok, reservation_ref}` if within budget and rate limits.
  The ref must be passed back to either `record_usage/3` (with
  `:reservation`) or `release/2` so the reservation isn't held forever.

  ## Examples

      {:ok, ref} = RateLimiter.acquire(pid, "alice", 1000)
      {:error, :budget_exceeded} = RateLimiter.acquire(pid, "alice", 1000)
      {:error, :rate_limited} = RateLimiter.acquire(pid, "alice", 1000)
  """
  @spec acquire(pid(), String.t(), non_neg_integer()) ::
          {:ok, reservation_ref()} | {:error, :budget_exceeded} | {:error, :rate_limited}
  def acquire(pid, agent_name, tokens \\ 1) do
    GenServer.call(pid, {:acquire, agent_name, tokens})
  end

  @doc """
  Cancel a reservation. Refunds the reserved tokens + request.

  Use this when an LLM call errored before completing and you don't have
  actual usage to record.
  """
  @spec release(pid(), reservation_ref()) :: :ok
  def release(pid, ref) when is_reference(ref) do
    GenServer.cast(pid, {:release, ref})
  end

  @doc """
  Get the current status of the rate limiter.

  Returns a map with `:budget_remaining`, `:agents` usage breakdown, and
  `:open_reservations` (held but not yet reconciled or released).
  """
  @spec get_status(pid()) :: status()
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc """
  Record actual usage after an LLM call completes.

  Two modes:

  - **With `:reservation` key** — reconciles actual vs estimated. The
    reservation is consumed (dropped from open reservations) and the
    delta `(actual - estimate)` is applied to totals/agent/window.

  - **Without `:reservation` key (legacy)** — adds the actual usage as
    a fresh entry, with no reconciliation. Use this only when you didn't
    go through `acquire/3`.

  ## Examples

      # Reservation-based (race-safe)
      {:ok, ref} = RateLimiter.acquire(pid, "alice", 1000)
      RateLimiter.record_usage(pid, "alice",
        %{tokens: 850, cost: 0.012, reservation: ref})

      # Post-hoc (legacy, not race-safe)
      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 0.01})
  """
  @spec record_usage(pid(), String.t(), map()) :: :ok
  def record_usage(pid, agent_name, usage_map) do
    GenServer.cast(pid, {:record_usage, agent_name, usage_map})
  end

  # Server

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    budget = Keyword.get(opts, :budget, :infinity)
    per_agent_budget = Keyword.get(opts, :per_agent_budget, :infinity)
    rpm = Keyword.get(opts, :rpm, :infinity)
    tpm = Keyword.get(opts, :tpm, :infinity)
    reservation_ttl_ms = Keyword.get(opts, :reservation_ttl_ms, @default_reservation_ttl_ms)

    state = %{
      team_id: team_id,
      budget: budget,
      per_agent_budget: per_agent_budget,
      rpm: rpm,
      tpm: tpm,
      reservation_ttl_ms: reservation_ttl_ms,
      total_cost: 0.0,
      total_tokens: 0,
      total_requests: 0,
      agents: %{},
      # Sliding window: list of {timestamp_ms, tokens, requests}
      window: [],
      # Reservations: %{ref => {agent_name, est_tokens, est_requests, ts}}
      reservations: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, agent_name, tokens}, _from, state) do
    state = state |> prune_window() |> prune_reservations()
    agent_usage = Map.get(state.agents, agent_name, default_agent_usage())

    cond do
      budget_exceeded?(state, agent_usage) ->
        {:reply, {:error, :budget_exceeded}, state}

      rate_limited?(state, tokens) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        # Reserve atomically: pre-deduct tokens + 1 request to the
        # window and the agent's totals so a concurrent acquire can't
        # also see "room available". Cost is unknown until the LLM
        # responds, so it stays at 0 in the reservation.
        ref = make_ref()
        now = System.monotonic_time(:millisecond)

        state = apply_delta(state, agent_name, tokens, 1, 0.0, now)
        reservation = {agent_name, tokens, 1, now}
        state = %{state | reservations: Map.put(state.reservations, ref, reservation)}

        {:reply, {:ok, ref}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    budget_remaining =
      case state.budget do
        :infinity -> :infinity
        budget -> budget - state.total_cost
      end

    status = %{
      budget_remaining: budget_remaining,
      agents:
        Map.new(state.agents, fn {name, usage} ->
          {name, %{cost: usage.cost, tokens: usage.tokens, requests: usage.requests}}
        end),
      open_reservations: map_size(state.reservations)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    state = prune_window(state)

    case Map.pop(state.reservations, ref) do
      {nil, _} ->
        {:noreply, state}

      {{agent_name, est_tokens, est_requests, _ts}, rest} ->
        # Refund: subtract the reservation entirely AND add a negative
        # window entry so the sliding-window rate-limit math sees the
        # refund. (Without the negative entry, the original +est_tokens
        # acquire entry would still count for TPM until it timed out.)
        state = %{state | reservations: rest}
        now = System.monotonic_time(:millisecond)
        state = apply_delta(state, agent_name, -est_tokens, -est_requests, 0.0, now)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:record_usage, agent_name, usage_map}, state) do
    state = state |> prune_window() |> prune_reservations()

    case Map.get(usage_map, :reservation) do
      nil -> handle_legacy_record(state, agent_name, usage_map)
      ref -> handle_reconciled_record(state, agent_name, usage_map, ref)
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Server helpers
  # ---------------------------------------------------------------------------

  # Legacy path: post-hoc accounting, no reservation involved.
  defp handle_legacy_record(state, agent_name, usage_map) do
    tokens = Map.get(usage_map, :tokens, 0)
    cost = Map.get(usage_map, :cost, 0.0)
    requests = Map.get(usage_map, :requests, 1)
    now = System.monotonic_time(:millisecond)

    state = apply_delta(state, agent_name, tokens, requests, cost, now)
    {:noreply, state}
  end

  # Reservation-reconciled path: convert the reservation into an actual
  # usage entry by applying (actual - estimate) as a delta.
  defp handle_reconciled_record(state, agent_name, usage_map, ref) do
    actual_tokens = Map.get(usage_map, :tokens, 0)
    actual_cost = Map.get(usage_map, :cost, 0.0)
    actual_requests = Map.get(usage_map, :requests, 1)

    case Map.pop(state.reservations, ref) do
      {nil, _} ->
        # Reservation was already pruned (TTL) or doesn't exist. Treat
        # as a legacy record so the actual still counts somewhere.
        Logger.warning(
          "RateLimiter: record_usage with unknown reservation ref for agent " <>
            inspect(agent_name) <> "; falling back to legacy post-hoc record"
        )

        handle_legacy_record(state, agent_name, Map.delete(usage_map, :reservation))

      {{res_agent, est_tokens, est_requests, _ts}, rest} ->
        # The reservation may have been on a different agent name; warn
        # but reconcile against the reservation's agent (it's what
        # actually got debited).
        if res_agent != agent_name do
          Logger.warning(
            "RateLimiter: reservation belonged to #{inspect(res_agent)} but " <>
              "record_usage was called for #{inspect(agent_name)}; reconciling " <>
              "against the reservation owner."
          )
        end

        state = %{state | reservations: rest}

        token_delta = actual_tokens - est_tokens
        request_delta = actual_requests - est_requests
        now = System.monotonic_time(:millisecond)

        # Apply the delta. Cost is always added (reservation reserves 0
        # cost). Tokens and requests can be negative if actual < estimate.
        state = apply_delta(state, res_agent, token_delta, request_delta, actual_cost, now)
        {:noreply, state}
    end
  end

  # Apply a (possibly negative) delta to totals, agent usage, and window.
  # All callers pass an integer `ts` so the window always reflects the
  # operation; no nil-ts/no-window path is needed.
  defp apply_delta(state, agent_name, token_delta, request_delta, cost_delta, ts)
       when is_integer(ts) do
    agent_usage = Map.get(state.agents, agent_name, default_agent_usage())

    updated_agent = %{
      cost: max(0.0, agent_usage.cost + cost_delta),
      tokens: max(0, agent_usage.tokens + token_delta),
      requests: max(0, agent_usage.requests + request_delta)
    }

    state = %{
      state
      | total_cost: max(0.0, state.total_cost + cost_delta),
        total_tokens: max(0, state.total_tokens + token_delta),
        total_requests: max(0, state.total_requests + request_delta),
        agents: Map.put(state.agents, agent_name, updated_agent)
    }

    if token_delta != 0 or request_delta != 0 do
      %{state | window: state.window ++ [{ts, token_delta, request_delta}]}
    else
      state
    end
  end

  # Drop reservations older than `:reservation_ttl_ms` and refund them.
  # Logs a warning per dropped reservation so leaks are visible.
  defp prune_reservations(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.reservation_ttl_ms

    {expired, kept} =
      Map.split_with(state.reservations, fn {_ref, {_agent, _toks, _reqs, ts}} -> ts <= cutoff end)

    state = %{state | reservations: kept}

    Enum.reduce(expired, state, fn {_ref, {agent, toks, reqs, _ts}}, acc ->
      Logger.warning(
        "RateLimiter: reservation for #{inspect(agent)} expired " <>
          "(#{toks} tokens, #{reqs} request) - refunding. Caller should pair " <>
          "acquire/3 with record_usage(reservation: ref) or release/2."
      )

      apply_delta(acc, agent, -toks, -reqs, 0.0, now)
    end)
  end

  # ---------------------------------------------------------------------------
  # Pure helpers
  # ---------------------------------------------------------------------------

  defp split_gen_opts(opts) do
    case Keyword.pop(opts, :name) do
      {nil, rest} -> {[], rest}
      {name, rest} -> {[name: name], rest}
    end
  end

  defp default_agent_usage, do: %{cost: 0.0, tokens: 0, requests: 0}

  defp budget_exceeded?(%{budget: :infinity, per_agent_budget: :infinity}, _agent_usage),
    do: false

  defp budget_exceeded?(%{budget: budget, total_cost: total_cost}, _agent_usage)
       when is_number(budget) and total_cost >= budget,
       do: true

  defp budget_exceeded?(%{per_agent_budget: per_agent_budget}, %{cost: agent_cost})
       when is_number(per_agent_budget) and agent_cost >= per_agent_budget,
       do: true

  defp budget_exceeded?(_state, _agent_usage), do: false

  defp rate_limited?(%{rpm: :infinity, tpm: :infinity}, _tokens), do: false

  defp rate_limited?(state, tokens) do
    {window_requests, window_tokens} = window_totals(state.window)

    rpm_exceeded =
      case state.rpm do
        :infinity -> false
        rpm -> window_requests + 1 > rpm
      end

    tpm_exceeded =
      case state.tpm do
        :infinity -> false
        tpm -> window_tokens + tokens > tpm
      end

    rpm_exceeded or tpm_exceeded
  end

  defp window_totals(window) do
    Enum.reduce(window, {0, 0}, fn {_ts, tokens, requests}, {total_req, total_tok} ->
      {total_req + requests, total_tok + tokens}
    end)
  end

  defp prune_window(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - 60_000

    pruned = Enum.filter(state.window, fn {ts, _tokens, _requests} -> ts > cutoff end)
    %{state | window: pruned}
  end
end

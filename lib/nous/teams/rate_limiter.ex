defmodule Nous.Teams.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for per-team and per-agent usage control.

  Tracks token usage and enforces budget limits and rate limits (requests per
  minute, tokens per minute) for a team's agents.

  ## Architecture

  Each team optionally gets its own `RateLimiter` GenServer. Agents call
  `acquire/3` before making LLM requests. The limiter checks both team-wide
  and per-agent budgets, returning `:ok` or an error tuple.

  ## Quick Start

      {:ok, pid} = RateLimiter.start_link(
        team_id: "team_1",
        budget: 10.0,
        per_agent_budget: 5.0,
        rpm: 60,
        tpm: 100_000
      )

      :ok = RateLimiter.acquire(pid, "alice", 1000)
      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 0.01})
      status = RateLimiter.get_status(pid)

  ## Configuration

  - `:budget` — team-wide budget in USD (default: infinity)
  - `:per_agent_budget` — per-agent budget in USD (default: infinity)
  - `:rpm` — requests per minute limit (default: infinity)
  - `:tpm` — tokens per minute limit (default: infinity)
  """

  use GenServer

  @type status :: %{
          budget_remaining: float() | :infinity,
          agents: %{
            String.t() => %{cost: float(), tokens: non_neg_integer(), requests: non_neg_integer()}
          }
        }

  # Client API

  @doc """
  Start a RateLimiter for a team.

  ## Options

  - `:team_id` (required) — unique identifier for the team
  - `:budget` — total team budget in USD (default: `:infinity`)
  - `:per_agent_budget` — per-agent budget in USD (default: `:infinity`)
  - `:rpm` — requests per minute (default: `:infinity`)
  - `:tpm` — tokens per minute (default: `:infinity`)
  - `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = split_gen_opts(opts)
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Acquire permission to use tokens.

  Returns `:ok` if within budget and rate limits, or an error tuple.

  ## Examples

      :ok = RateLimiter.acquire(pid, "alice", 1000)
      {:error, :budget_exceeded} = RateLimiter.acquire(pid, "alice", 1000)
      {:error, :rate_limited} = RateLimiter.acquire(pid, "alice", 1000)
  """
  @spec acquire(pid(), String.t(), non_neg_integer()) ::
          :ok | {:error, :budget_exceeded} | {:error, :rate_limited}
  def acquire(pid, agent_name, tokens \\ 1) do
    GenServer.call(pid, {:acquire, agent_name, tokens})
  end

  @doc """
  Get the current status of the rate limiter.

  Returns a map with `:budget_remaining` and `:agents` usage breakdown.

  ## Examples

      status = RateLimiter.get_status(pid)
      # %{budget_remaining: 8.5, agents: %{"alice" => %{cost: 1.5, tokens: 1000, requests: 5}}}
  """
  @spec get_status(pid()) :: status()
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc """
  Record actual usage after an LLM call completes.

  The usage map can contain `:tokens`, `:cost`, and `:requests` keys.

  ## Examples

      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 0.01, requests: 1})
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

    state = %{
      team_id: team_id,
      budget: budget,
      per_agent_budget: per_agent_budget,
      rpm: rpm,
      tpm: tpm,
      total_cost: 0.0,
      total_tokens: 0,
      total_requests: 0,
      agents: %{},
      # Sliding window: list of {timestamp_ms, tokens, requests}
      window: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, agent_name, tokens}, _from, state) do
    # M-9 (KNOWN LIMITATION): acquire/3 currently only CHECKS the budget;
    # actual deduction happens asynchronously in :record_usage. Concurrent
    # acquires near the cap may all see "budget remaining" and proceed,
    # producing post-hoc accounting rather than true reservation. A full
    # token-bucket fix (pre-deduct + delta reconcile + release-on-error)
    # was attempted but breaks the existing record_usage contract; left
    # for follow-up. Document this so callers know not to rely on
    # bounded spend under contention.
    state = prune_window(state)
    agent_usage = Map.get(state.agents, agent_name, default_agent_usage())

    cond do
      budget_exceeded?(state, agent_usage) ->
        {:reply, {:error, :budget_exceeded}, state}

      rate_limited?(state, tokens) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        {:reply, :ok, state}
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
        end)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:record_usage, agent_name, usage_map}, state) do
    state = prune_window(state)
    tokens = Map.get(usage_map, :tokens, 0)
    cost = Map.get(usage_map, :cost, 0.0)
    requests = Map.get(usage_map, :requests, 1)

    now = System.monotonic_time(:millisecond)

    agent_usage = Map.get(state.agents, agent_name, default_agent_usage())

    updated_agent = %{
      cost: agent_usage.cost + cost,
      tokens: agent_usage.tokens + tokens,
      requests: agent_usage.requests + requests
    }

    window_entry = {now, tokens, requests}

    state = %{
      state
      | total_cost: state.total_cost + cost,
        total_tokens: state.total_tokens + tokens,
        total_requests: state.total_requests + requests,
        agents: Map.put(state.agents, agent_name, updated_agent),
        window: state.window ++ [window_entry]
    }

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private

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
        rpm -> window_requests >= rpm
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

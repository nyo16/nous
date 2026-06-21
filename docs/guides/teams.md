# Teams

The Nous Teams subsystem turns a flat agent into a coordinated group of agents that work the same problem together. Each team is a small OTP supervision tree: a lifecycle Coordinator spawns and monitors agent processes, a SharedState process holds discoveries and file-region locks, an optional RateLimiter enforces budget and rate caps, and a PubSub topic scheme carries messages between members. Agents talk to each other through tools, not glue code.

## Overview

A team is built from these layers:

- **Supervision** -- `Teams.Supervisor` (one per team), a per-team agent `DynamicSupervisor`, and the team-internal processes registered under deterministic names.
- **Lifecycle** -- `Teams.Coordinator` (GenServer) spawns, stops, lists, and monitors agents; it broadcasts membership events and dissolves the team.
- **Roles** -- `Teams.Role` (plain struct) configures system prompt, tool whitelist/blacklist, and iteration limits. Built-ins: `researcher/0`, `coder/0`, `lead/0`.
- **Shared state** -- `Teams.SharedState` (GenServer + private ETS table) stores discoveries and file-region claims with a ~5-minute TTL.
- **Rate limiting** -- `Teams.RateLimiter` (GenServer) reserves tokens/requests before each LLM call and reconciles actual usage afterward.
- **Comms** -- `Teams.Comms` builds the `nous:team:<id>` topic scheme and wraps `Nous.PubSub`.
- **Agent tools** -- `Plugins.TeamTools` exposes `peer_message`, `broadcast_message`, `share_discovery`, `list_team`, and `claim_region` to the agents themselves.

## Quick Start

Start a team supervisor, spawn two agents into it, then inspect and dissolve:

```elixir
alias Nous.Teams.{Coordinator, Role}

# 1. Start the per-team supervision tree.
#    :team_id is required. Passing :budget also starts a RateLimiter.
{:ok, _sup} = Nous.Teams.Supervisor.start_link(
  team_id: "team_1",
  team_name: "Research Team",
  pubsub: MyApp.PubSub,
  budget: 10.0,
  rpm: 60,
  tpm: 100_000,
  name: :team_1_sup
)

# 2. The Coordinator is registered under a derived name.
coordinator = :"team_coordinator_team_1"

# 3. Spawn agents. The agent config map is whatever AgentServer accepts;
#    pass a Role via the opts to shape prompt and tool access.
{:ok, _alice} = Coordinator.spawn_agent(coordinator, "alice",
  %{model: "openai:gpt-4o", instructions: "Research specialist"},
  role: Role.researcher())

{:ok, _bob} = Coordinator.spawn_agent(coordinator, "bob",
  %{model: "openai:gpt-4o", instructions: "Implementation specialist"},
  role: Role.coder())

# 4. Inspect.
Coordinator.list_agents(coordinator)
# => [%{name: "alice", pid: #PID<...>, status: :running}, ...]

Coordinator.team_status(coordinator)
# => %{team_id: "team_1", team_name: "Research Team", agent_count: 2, agents: [...]}

# 5. Tear down.
Coordinator.stop_agent(coordinator, "bob")
Coordinator.dissolve(coordinator)
```

## Starting a Team

`Nous.Teams.Supervisor.start_link/1` boots the whole tree under `Nous.AgentDynamicSupervisor`. Its `init/1` reads these options:

- `:team_id` (required) -- unique identifier; everything else is derived from it.
- `:team_name` -- human-readable name (defaults to `team_id`).
- `:pubsub` -- PubSub module for messaging (falls back to `Nous.PubSub.configured_pubsub()`).
- `:budget` -- team budget in USD. **Passing it is what starts the RateLimiter** (`has_rate_limiter = budget != nil`); omit it and no limiter is supervised.
- `:per_agent_budget` -- per-agent budget in USD (only meaningful with a budget set).
- `:rpm` -- requests-per-minute cap.
- `:tpm` -- tokens-per-minute cap.
- `:name` -- optional name for the supervisor process itself.

The supervisor uses a `:one_for_all` strategy and starts the Coordinator last so it can reference the other processes. The team-internal processes are registered under names derived from `team_id`:

| Process | Registered name |
|---------|-----------------|
| Agent `DynamicSupervisor` | `:"team_agent_sup_<team_id>"` |
| `SharedState` | `:"team_shared_state_<team_id>"` |
| `RateLimiter` (if `:budget`) | `:"team_rate_limiter_<team_id>"` |
| `Coordinator` | `:"team_coordinator_<team_id>"` |

You drive a team through its Coordinator name, e.g. `:"team_coordinator_team_1"`.

## Managing Agents

All agent lifecycle goes through `Teams.Coordinator`, which takes the Coordinator pid (or registered name) as its first argument.

```elixir
@spec spawn_agent(pid(), String.t(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
@spec stop_agent(pid(), String.t()) :: :ok | {:error, :not_found}
@spec list_agents(pid()) :: [agent_info()]
@spec team_status(pid()) :: map()
@spec dissolve(pid()) :: :ok
```

- **`spawn_agent/4`** -- starts a `Nous.AgentServer` under the team's `DynamicSupervisor`, registers it in `Nous.AgentRegistry` with a `{:team, team_id, name}` key, and gives it `inactivity_timeout: :infinity`. The agent's session id is `"team:<team_id>:<name>"`. Spawning the same name twice returns `{:error, :already_exists}`. Supported opts:
  - `:role` -- a `Teams.Role` struct, threaded into the agent's deps as `:team_role`.
  - `:plugins` -- list of plugin modules for the agent.

  On success the Coordinator monitors the new process and broadcasts `{:agent_joined, name}` to the team topic.

- **`stop_agent/2`** -- terminates the agent's child, demonitors it, and broadcasts `{:agent_left, name}`. Returns `{:error, :not_found}` for an unknown name.

- **`list_agents/1`** -- returns `[%{name: ..., pid: ..., status: :running | :stopped}]`.

- **`team_status/1`** -- returns `%{team_id:, team_name:, agent_count:, agents:}`.

- **`dissolve/1`** -- terminates every agent, flushes all monitors, and broadcasts `{:team_dissolved, team_id}`. The Coordinator process itself stays alive (you can spawn fresh agents afterward); use the Supervisor to tear the whole tree down.

The Coordinator also reacts to crashes: when a monitored agent goes `:DOWN`, it broadcasts `{:agent_crashed, name, reason}` and drops the agent from its state.

### Team deps injected into every agent

When `spawn_agent/4` builds the child, it merges a team context into the agent config's `:deps` map. These keys are what `Plugins.TeamTools` reads at runtime:

```elixir
%{
  team_id:             state.team_id,
  team_name:           state.team_name,
  team_role:           Keyword.get(opts, :role),
  shared_state_pid:    state.shared_state,      # may be a registered NAME
  rate_limiter_pid:    state.rate_limiter,      # may be a registered NAME
  team_coordinator_pid: self(),
  agent_name:          agent_name
}
```

## Roles

A `Teams.Role` is a plain struct -- no process. `Role.new/1` builds one from keyword attrs:

```elixir
@spec new(keyword()) :: t()
role = Role.new(
  name: :reviewer,                 # required atom
  system_prompt: "Review code carefully",
  denied_tools: ["execute_code"],  # blacklist
  max_iterations: 10               # default 15
)
```

Fields: `name`, `system_prompt`, `allowed_tools` (whitelist, `nil` = all), `denied_tools` (blacklist, `nil` = none), `max_iterations` (default `15`).

`apply_tool_filter/2` filters a tool list against the role:

```elixir
@spec apply_tool_filter(t(), [Nous.Tool.t()]) :: [Nous.Tool.t()]
```

- If `allowed_tools` is set, only those tools are kept.
- Otherwise, if `denied_tools` is set, those tools are removed.
- Otherwise all tools pass through.
- `allowed_tools` takes precedence over `denied_tools` (the function head matches the allowed clause first).

### Built-in roles

| Role | Tool access | `max_iterations` |
|------|-------------|------------------|
| `Role.researcher/0` | whitelist: `search`, `read_file`, `web_fetch`, `recall`, `share_discovery`, `peer_message`, `broadcast_message`, `list_team` | 15 |
| `Role.coder/0` | denies `delete_file`, `drop_table` | 15 |
| `Role.lead/0` | unrestricted | 20 |

Each ships a tailored `system_prompt`: the researcher gathers and shares findings, the coder claims regions before editing, the lead coordinates and arbitrates.

## Agent Tools (Plugins.TeamTools)

Add `Nous.Plugins.TeamTools` to an agent's plugin list to give it team-aware tools. On `init/2` the plugin subscribes the agent to both the team topic and its own direct topic (only when `:team_id` and `:agent_name` are both present in deps). It reads `:team_id`, `:agent_name`, `:shared_state_pid`, and `:team_coordinator_pid` from `ctx.deps`.

The five tools:

| Tool | Effect |
|------|--------|
| `peer_message` (`to`, `content`) | Sends `{:peer_message, from, to, content}` on the recipient's direct topic. |
| `broadcast_message` (`content`) | Sends `{:team_broadcast, from, content}` on the team topic. |
| `share_discovery` (`topic`, `content`) | Stores the finding in `SharedState` and broadcasts `{:discovery, from, discovery}` to the team. |
| `list_team` (no args) | Calls `Coordinator.list_agents/1` and returns members + status. |
| `claim_region` (`file`, `start_line`, `end_line`) | Claims a file region via `SharedState`; returns `claimed` or `conflict`. |

The plugin resolves `shared_state_pid` / `team_coordinator_pid` through a `resolve_alive/1` helper that accepts both a pid **and a registered name (atom)** -- important because `Teams.Supervisor` threads these in as names, not pids. If the target is unavailable, `share_discovery` and `claim_region` degrade gracefully rather than crash.

## Shared State

`Teams.SharedState` owns a private ETS table per team and serves two purposes: a discovery board and file-region locks. The table is destroyed when the process terminates (`terminate/2` calls `:ets.delete/1`).

```elixir
@spec share_discovery(pid(), String.t(), map()) :: :ok
@spec get_discoveries(pid()) :: [map()]
@spec claim_region(pid(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
        :ok | {:error, :conflict}
@spec release_region(pid(), String.t(), String.t()) :: :ok
@spec get_claims(pid()) :: [map()]
```

**Discoveries** -- `share_discovery/3` records `%{agent, topic, content, timestamp}` (timestamp added automatically; accepts atom or string `topic`/`content` keys). `get_discoveries/1` returns them in insertion order.

**Region claims** -- `claim_region/5` succeeds with `:ok` unless the requested `start_line..end_line` overlaps an existing claim on the **same file by a different agent**, in which case it returns `{:error, :conflict}`. Overlap is inclusive (`s1 <= e2 and s2 <= e1`). Re-claiming the same file as the same agent overwrites the prior claim. `release_region/3` deletes an agent's claim on a file.

Claims auto-expire after a TTL (`:claim_ttl`, default `:timer.minutes(5)`), scheduled with `Process.send_after/3`; an expired claim is silently dropped from the table.

## Rate Limiting

`Teams.RateLimiter` is a token-bucket limiter that the agent runner is expected to call around each LLM request when `:rate_limiter_pid` is wired into deps. The pattern is reserve, run, reconcile:

```elixir
@spec acquire(pid(), String.t(), non_neg_integer()) ::
        {:ok, reservation_ref()} | {:error, :budget_exceeded} | {:error, :rate_limited}
@spec record_usage(pid(), String.t(), map()) :: :ok
@spec release(pid(), reservation_ref()) :: :ok
@spec get_status(pid()) :: status()

{:ok, ref} = RateLimiter.acquire(pid, "alice", 1000)  # reserve est. 1000 tokens + 1 request

case do_llm_call(...) do
  {:ok, response} ->
    RateLimiter.record_usage(pid, "alice", %{
      tokens: response.usage.total_tokens,
      cost: response.usage.cost,
      reservation: ref            # reconcile actual vs estimate
    })

  {:error, _} ->
    RateLimiter.release(pid, ref) # refund the reservation
end
```

`acquire/3` pre-deducts the estimated tokens and one request before returning the ref. It can fail with `{:error, :budget_exceeded}` (cost over `:budget` or `:per_agent_budget`) or `{:error, :rate_limited}` (window over `:rpm` or `:tpm`). All limits default to `:infinity`.

Two reconciliation modes for `record_usage/3`:

- **With `:reservation`** -- consumes the reservation and applies the delta `(actual - estimate)`. Race-safe.
- **Without `:reservation` (legacy)** -- adds usage as a fresh post-hoc entry. Use only when you did not go through `acquire/3`.

`get_status/1` returns `%{budget_remaining:, agents: %{name => %{cost, tokens, requests}}, open_reservations:}`.

**Concurrency caveat (from the module's own docs):** the token (`tpm`) and request (`rpm`) limits are race-safe because `acquire/3` pre-deducts them. The **dollar budget is not** -- `acquire/3` reserves `0` cost (the runtime has no per-token cost model), so N concurrent in-flight calls can overshoot the budget by their combined cost. Treat `tpm`/`rpm` as the hard concurrency guards and the budget as a soft ceiling. Reservations never reconciled or released are pruned after `:reservation_ttl_ms` (default 5 minutes) with a `Logger.warning`, refunding their tokens.

## PubSub Comms

`Teams.Comms` defines the topic scheme and wraps `Nous.PubSub`. All helpers are no-ops if PubSub is `nil` or unavailable.

| Topic | Builder | Carries |
|-------|---------|---------|
| `nous:team:<id>` | `team_topic/1` | team-wide broadcasts and membership events |
| `nous:team:<id>:context` | `context_topic/1` | shared context updates |
| `nous:team:<id>:agent:<name>` | `agent_topic/2` | direct messages to one agent |

```elixir
Comms.subscribe_team(pubsub, "team_1")
Comms.subscribe_agent(pubsub, "team_1", "alice")
Comms.broadcast_team(pubsub, "team_1", {:discovery, "alice", %{topic: "bug"}})
Comms.send_to_agent(pubsub, "team_1", "bob", {:peer_message, "alice", "bob", "check this"})
```

Membership events the Coordinator emits on the team topic: `{:agent_joined, name}`, `{:agent_left, name}`, `{:agent_crashed, name, reason}`, `{:team_dissolved, team_id}`. `Plugins.TeamTools` emits `{:peer_message, from, to, content}`, `{:team_broadcast, from, content}`, and `{:discovery, from, discovery}`.

## Gotchas

- **No budget, no limiter.** The RateLimiter is only supervised when you pass `:budget` to `Teams.Supervisor.start_link/1`. `:rpm`/`:tpm` alone won't start one.
- **The dollar budget can overshoot.** Under concurrency only `tpm`/`rpm` are hard guards; the cost budget is reconciled after the fact. See the rate-limiting section above.
- **You address the Coordinator by derived name.** `start_link/1` registers internals as `:"team_coordinator_<id>"` etc.; there's no single "team handle" struct.
- **Deps may hold names, not pids.** `shared_state_pid` and `rate_limiter_pid` in agent deps are often registered atoms. Anything reading them must resolve names to live pids (as `TeamTools.resolve_alive/1` does) or region locking and discovery sharing silently no-op.
- **`dissolve/1` keeps the Coordinator alive.** It clears agents and monitors but does not stop the GenServer; stop the whole tree via the Supervisor.
- **Region overlap is inclusive and per-file.** Same agent re-claiming a file overwrites; a different agent overlapping the line range gets `{:error, :conflict}`.
- **Claims and discoveries are ephemeral.** They live in a private ETS table owned by `SharedState` and vanish when that process dies; claims also expire after ~5 minutes.
- **Duplicate agent names are rejected.** `spawn_agent/4` returns `{:error, :already_exists}` rather than replacing the existing agent.

## Related guides

- [Memory System](memory.md) -- persistent, searchable agent memory (works per-agent inside a team).
- [Tool Development](tool_development.md) -- the tool/plugin behaviour that `TeamTools` builds on.
- [LiveView Integration](liveview-integration.md) -- subscribing UIs to the team PubSub topics.

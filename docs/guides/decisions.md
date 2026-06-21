# Decision Graph

The Nous decision graph gives agents a structured way to track their own reasoning. As an agent works through a complex task, it records goals, the decisions it makes, the options it weighs, the actions it takes, and the outcomes it observes — all as nodes in a directed graph connected by typed edges. The graph persists the reasoning process so an agent can revisit prior decisions, supersede them when it finds a better approach, and build on what it already concluded.

## Overview

The system has three layers, all plain modules and structs — no GenServer:

- **Data Layer** -- `Node` (struct), `Edge` (struct), `Store` (behaviour + backends)
- **Query Layer** -- graph traversal via the store's `query/3` callback
- **Integration Layer** -- `Plugins.Decisions` (the plugin), the agent decision tools, and `ContextBuilder` (system-prompt injection)

State is opaque. A store's `init/1` returns a `state` term that the caller threads through every subsequent call, so multiple independent graphs can coexist in one VM.

A **node** (`Nous.Decisions.Node`) has a `type` (`:goal | :decision | :option | :action | :outcome | :observation | :revisit`), a `label`, a `status` (`:active | :completed | :superseded | :rejected`), and optional `confidence` (0.0-1.0), `rationale`, and `metadata`. An **edge** (`Nous.Decisions.Edge`) connects `from_id` to `to_id` with an `edge_type` (`:leads_to | :chosen | :rejected | :requires | :blocks | :enables | :supersedes`). Both get auto-generated IDs and timestamps.

## Quick Start

The fastest path is to attach the plugin to an agent. The only required config is the store backend:

```elixir
agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Decisions],
  deps: %{decisions_config: %{store: Nous.Decisions.Store.ETS}}
)

{:ok, result} = Nous.run(agent, "Plan and implement user authentication.")
```

With the plugin attached, the agent gets a system prompt describing four decision tools (`add_goal`, `record_decision`, `record_outcome`, `query_decisions`) and is told to track its reasoning as it works. The current active goals and recent decisions are injected into the prompt so the agent always sees where it left off.

You can also drive the graph directly, without an agent:

```elixir
alias Nous.Decisions
alias Nous.Decisions.{Node, Edge, Store}

# 1. Initialize the store (opaque state)
{:ok, state} = Store.ETS.init([])

# 2. Add a goal
goal = Node.new(%{type: :goal, label: "Implement auth", confidence: 0.9})
{:ok, state} = Decisions.add_node(Store.ETS, state, goal)

# 3. Record a decision and link it to the goal
decision = Node.new(%{type: :decision, label: "Use JWT tokens", rationale: "Stateless, scales horizontally"})
{:ok, state} = Decisions.add_node(Store.ETS, state, decision)

edge = Edge.new(%{from_id: goal.id, to_id: decision.id, edge_type: :leads_to})
{:ok, state} = Decisions.add_edge(Store.ETS, state, edge)

# 4. Query the graph
{:ok, goals} = Decisions.active_goals(Store.ETS, state)
{:ok, recent} = Decisions.recent_decisions(Store.ETS, state, limit: 5)
```

## Agent Integration

### The Decisions plugin

`Nous.Plugins.Decisions` is the user-facing entry point. It is configured entirely through `deps[:decisions_config]`:

```elixir
agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Decisions],
  deps: %{
    decisions_config: %{
      # Required
      store: Nous.Decisions.Store.ETS,

      # Optional
      store_opts: [],                  # passed to store.init/1
      decision_limit: 5,               # max recent decisions in context (default: 5)
      auto_inject: true,               # inject decision context into the prompt (default: true)
      inject_strategy: :first_only     # :first_only (default) | :every_iteration
    }
  }
)
```

`:store` is the only required key. If it is missing, the plugin logs a warning during `init` and the decision tools simply do not function — the agent still runs.

On initialization the plugin calls `store.init/1` (converting a `store_opts` map to a keyword list if needed), stashes the resulting `store_state` back into `decisions_config`, and applies the defaults above. If `store.init/1` returns an error, it is logged and the plugin is effectively disabled for the run.

### Auto-injection

When `auto_inject: true` (the default) and a store is configured, the plugin injects a decision-tracking summary into the agent's context. `:inject_strategy` controls how often:

- **`:first_only`** (default) -- inject once, on the first request of the run. Tracked via an internal `_inject_done` flag.
- **`:every_iteration`** -- re-inject before every request, so the agent always sees the freshest goals and decisions (at the cost of more tokens).

The injected text is produced by `Nous.Decisions.ContextBuilder.build/3`, which queries the store for `:active_goals` and `:recent_decisions` (honoring `:decision_limit`) and formats them into a markdown summary. Active goals are listed with their short ID, label, status, and confidence, and each goal's immediate children are shown as a small tree (a `:chosen`/`:rejected` edge is labeled as such; otherwise the child's status is shown). If there are no goals or decisions, `build/3` returns `nil` and nothing is injected.

### The decision tools

The system prompt advertises four tools the agent can call:

- **`add_goal`** -- record a new goal or objective.
- **`record_decision`** -- record a decision and optionally link it to a goal.
- **`record_outcome`** -- record the outcome of a decision or action.
- **`query_decisions`** -- query active goals, recent decisions, or graph paths.

The agent is instructed to use these proactively: record goals at the start of a complex task, decisions as it makes them, and outcomes when it observes results.

## Core API

`Nous.Decisions` is a thin, stateless facade over a store module. Every function takes the store module as its first argument and the opaque `state` as its second, threading an updated `state` back out on writes.

### Writes

```elixir
# Add a node
node = Node.new(%{type: :goal, label: "Implement auth"})
{:ok, state} = Decisions.add_node(Store.ETS, state, node)

# Add an edge
edge = Edge.new(%{from_id: a.id, to_id: b.id, edge_type: :leads_to})
{:ok, state} = Decisions.add_edge(Store.ETS, state, edge)

# Update fields on an existing node (also bumps updated_at)
{:ok, state} = Decisions.update_node(Store.ETS, state, node.id, %{status: :completed})

# Fetch a single node
{:ok, node} = Decisions.get_node(Store.ETS, state, node.id)
```

### Supersede

`supersede/5` retires an old node in favor of a new one. It marks the old node `:superseded` (optionally recording a `rationale` on it) and adds a `:supersedes` edge from the new node to the old node:

```elixir
{:ok, state} =
  Decisions.supersede(Store.ETS, state, old_id, new_id, "Better approach found")
```

The `rationale` argument is optional (defaults to `nil`). See the [Gotchas](#gotchas) below — this operation is **not atomic**.

### Queries

```elixir
# All active goal nodes
{:ok, goals} = Decisions.active_goals(Store.ETS, state)

# Recent decision nodes, newest first (default limit: 10)
{:ok, decisions} = Decisions.recent_decisions(Store.ETS, state, limit: 5)
```

Both delegate to the store's `query/3` callback. Queries always return `{:ok, list}`, returning an empty list when there are no results — they do not error on "not found".

### Config validation

`validate_config/1` applies the same defaults the plugin uses and enforces that `:store` is present:

```elixir
{:ok, config}  = Decisions.validate_config(%{store: Nous.Decisions.Store.ETS})
{:error, _msg} = Decisions.validate_config(%{})
# => {:error, ":store is required in decisions_config"}
```

On success it returns the config with `auto_inject: true`, `inject_strategy: :first_only`, and `decision_limit: 5` filled in where unset.

## Deprecated graph-traversal helpers

Three traversal helpers on `Nous.Decisions` are **deprecated**. They remain as thin wrappers around `query/3`, but you should call the store directly instead:

| Deprecated helper | Replacement |
|-------------------|-------------|
| `path_between(mod, state, from_id, to_id)` | `mod.query(state, :path_between, from_id: ..., to_id: ...)` |
| `descendants(mod, state, node_id)` | `mod.query(state, :descendants, node_id: ...)` |
| `ancestors(mod, state, node_id)` | `mod.query(state, :ancestors, node_id: ...)` |

```elixir
# Deprecated:
{:ok, path} = Decisions.path_between(Store.ETS, state, from_id, to_id)

# Preferred:
{:ok, path} = Store.ETS.query(state, :path_between, from_id: from_id, to_id: to_id)
```

- `:path_between` returns the nodes along the shortest path between two nodes, or an empty list if none exists.
- `:descendants` returns every node reachable from a node (following outgoing edges).
- `:ancestors` returns every node that can reach a node (following incoming edges).

## Store Backends

Both backends implement the `Nous.Decisions.Store` behaviour. The behaviour requires `init/1`, `add_node/2`, `update_node/3`, `get_node/2`, `delete_node/2`, `add_edge/2`, `get_edges/3`, and `query/3`. Every backend must support the same five query types: `:active_goals`, `:recent_decisions`, `:path_between`, `:descendants`, and `:ancestors`.

| Backend | Graph Queries | External Deps |
|---------|---------------|---------------|
| `Store.ETS` | In-memory BFS traversal | None |
| `Store.DuckDB` | DuckPGQ path matching | `duckdbex` |

### ETS (zero-dependency)

Best for development, testing, and ephemeral agents. No configuration:

```elixir
{:ok, state} = Nous.Decisions.Store.ETS.init([])
```

It creates two unnamed ETS tables (one for nodes, one for edges) so multiple instances can coexist. The tables are `:public` so the several processes that share a session's `state` — the agent loop plus tool tasks — can all write. Type/status predicates (such as `:active_goals`) are pushed into ETS via a partial-map match spec rather than copying the whole table and filtering in Elixir. Graph queries build an adjacency index once per traversal and then run BFS, giving O(V+E) per traversal.

**Ownership and lifetime:** this store is intentionally *run-scoped*. `init/1` hands the table references back in `state`; the caller threads them through `ctx` for the session; the tables are reclaimed when the owning process exits. There is no supervised owner and no cross-run persistence — that is the design, not a leak. If you need cross-write atomicity or a lifetime longer than the session, put a serializing owner process in front of it.

### DuckDB (DuckPGQ)

Best for persistence and efficient graph queries over larger graphs. Add the dependency to `mix.exs`:

```elixir
{:duckdbex, "~> 0.3"}
```

Initialize with an optional file path (defaults to in-memory):

```elixir
{:ok, state} = Nous.Decisions.Store.DuckDB.init(path: "/tmp/decisions.duckdb")

# Or in-memory (default):
{:ok, state} = Nous.Decisions.Store.DuckDB.init([])
```

It creates `decision_nodes` and `decision_edges` tables plus a DuckPGQ property graph named `decisions`, and runs `:path_between`, `:descendants`, and `:ancestors` as `GRAPH_TABLE`/`MATCH` queries (bounded path lengths). Node `metadata` is stored as a JSON column; on read, keys are atomized only when they already exist as atoms (unknown keys stay as binaries), so user-supplied metadata can never trigger atom exhaustion.

If `duckdbex` is not compiled in, the module falls back to a stub whose every callback returns:

```elixir
{:error, "Duckdbex is not available. Add {:duckdbex, \"~> 0.3\"} to your dependencies."}
```

## Gotchas

### `supersede/5` is not atomic

`supersede/5` performs two separate backend writes — `update_node` then `add_edge`. If the update succeeds but the edge write fails (a network blip, lock contention, or a NIF failure on DuckDB), the old node is left marked `:superseded` with **no `:supersedes` edge** connecting it to the new node. There is no automatic rollback. The `Store` behaviour does not currently expose a transaction primitive; once it does, this operation should be wrapped in one. Until then, if you superseded and later cannot find the linking edge, this partial-failure window is the likely cause.

### The traversal helpers are deprecated

`path_between/4`, `descendants/3`, and `ancestors/3` on `Nous.Decisions` emit deprecation warnings. They are kept only as wrappers; call the store's `query/3` directly with the corresponding query type (see [Deprecated graph-traversal helpers](#deprecated-graph-traversal-helpers)). The non-deprecated query helpers `active_goals/2` and `recent_decisions/3` are fine to keep using.

### Queries never error on "missing"

Query callbacks always return `{:ok, list}` — an empty list means "no matches", not a failure. Match on the list, not on `{:error, :not_found}`, for query results. `get_node/3` is the exception: it returns `{:error, :not_found}` for a missing ID.

### ETS state is ephemeral

The ETS backend lives and dies with its owning process. Do not expect a graph built in one run to be visible in the next; use the DuckDB backend with a file `:path` if you need persistence.

## Related guides

- [Memory System](memory.md) -- persistent, searchable agent memory with hybrid text + vector search.

# Memory System

The Nous memory system gives agents persistent, searchable memory across conversations. Agents can store facts, recall context, and build up knowledge over time — with hybrid text + vector search, temporal decay, importance weighting, and flexible scoping.

## Overview

The memory system has three layers:

- **Data Layer** -- `Entry` (struct), `Store` (behaviour + backends)
- **Search Layer** -- `Search` (orchestrator), `Scoring` (RRF merge, temporal decay, composite scoring)
- **Integration Layer** -- `Plugins.Memory` (auto-injection plugin), `Memory.Tools` (agent tools: remember, recall, forget)

No GenServers. Everything is plain modules and structs, with state passed through function arguments.

## Quick Start

The simplest setup uses the ETS store with keyword-only search (no external deps):

```elixir
alias Nous.Memory.{Entry, Store, Search}

# 1. Initialize the store
{:ok, store} = Store.ETS.init([])

# 2. Store some memories
entry = Entry.new(%{content: "User prefers dark mode", importance: 0.8})
{:ok, store} = Store.ETS.store(store, entry)

entry2 = Entry.new(%{content: "Project uses Phoenix LiveView", importance: 0.7})
{:ok, store} = Store.ETS.store(store, entry2)

# 3. Search
{:ok, results} = Search.search(Store.ETS, store, "dark mode preferences")

for {entry, score} <- results do
  IO.puts("[#{Float.round(score, 3)}] #{entry.content}")
end
# => [0.742] User prefers dark mode
# => [0.583] Project uses Phoenix LiveView
```

Or wire memory directly into an agent with the plugin:

```elixir
agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Memory],
  deps: %{memory_config: %{store: Nous.Memory.Store.ETS}}
)

# The agent now has `remember`, `recall`, and `forget` tools,
# and relevant memories are auto-injected before each request.
{:ok, result} = Nous.run(agent, "My favorite color is blue. Remember that.")
{:ok, result2} = Nous.run(agent, "What's my favorite color?", context: result.context)
```

See `examples/memory/basic_ets.exs` for a complete runnable version.

## Store Backends

Three backends ship with Nous. All implement the `Nous.Memory.Store` behaviour, which is
public — see [Bringing Your Own Backend](#bringing-your-own-backend).

| Backend | Text Search | Vector Search | External Deps |
|---------|-------------|---------------|---------------|
| `Store.ETS` | Jaro distance | None | None |
| `Store.SQLite` | FTS5 (BM25) | Cosine similarity, scanned in Elixir | `exqlite` |
| `Store.DuckDB` | `ILIKE` substring match | `list_cosine_similarity`, scanned in SQL | `duckdbex` |

No shipped backend performs *indexed* (ANN) vector search — both vector-capable stores
compare the query against every row that has an embedding. At the corpus sizes agent
memory usually reaches (thousands to low tens of thousands of entries) a scan is a
perfectly reasonable answer, but it is a scan: cost grows linearly with the number of
embedded entries, not logarithmically.

### ETS (In-Memory)

Best for: development, testing, ephemeral agents.

```elixir
{:ok, store} = Nous.Memory.Store.ETS.init([])
```

No configuration needed. Text search uses `String.jaro_distance/2` for fuzzy matching. No vector search support -- embedding fields are stored but not searchable. Data is lost when the process ends.

### SQLite

Best for: single-node persistence, production with moderate data, BM25 text search.

Add to `mix.exs`:

```elixir
{:exqlite, "~> 0.27"}
```

Initialize with a file path:

```elixir
{:ok, store} = Nous.Memory.Store.SQLite.init(path: "/tmp/memories.db")

# Or in-memory (default):
{:ok, store} = Nous.Memory.Store.SQLite.init(path: ":memory:")
```

SQLite uses FTS5 with Porter stemming and unicode tokenization for text search. BM25 scoring is handled natively by SQLite. Vector search is a full scan: embeddings are stored as JSON-encoded blobs and `search_vector/3` computes cosine similarity in Elixir over every row with a non-null embedding. No vector extension (`sqlite-vec` or otherwise) is loaded.

See `examples/memory/sqlite_full.exs`.

### DuckDB

Best for: analytics workloads, large-scale data, native array embeddings.

Add to `mix.exs`:

```elixir
{:duckdbex, "~> 0.3"}
```

Initialize:

```elixir
{:ok, store} = Nous.Memory.Store.DuckDB.init(path: "/tmp/memories.duckdb")
```

DuckDB stores embeddings in native `DOUBLE[]` array columns and ranks `search_vector/3` with `list_cosine_similarity` in SQL — again a scan over every embedded row, not the VSS/HNSW extension. Text search is an `ILIKE '%query%'` substring match scored in Elixir by normalized occurrence count: no stemming, no BM25. `init/1` does attempt `INSTALL fts` / `LOAD fts`, but it discards the result and no query uses the extension, so treat FTS as absent.

See `examples/memory/duckdb_full.exs`.

## Bringing Your Own Backend

The three stores above are not privileged. Nothing in the memory system knows a backend's
name — the plugin, the memory tools and `Nous.Memory.Search` all dispatch on the module
they were handed. A store you write in your own application is therefore a first-class
citizen, and it is the supported way to reach an exotic backend (a Tantivy index, an HNSW
library, a vector database, your company's search cluster) without waiting on Nous to
vendor a dependency for it.

Put `@behaviour Nous.Memory.Store` on a module and implement the seven required callbacks:
`init/1`, `store/2`, `fetch/2`, `delete/2`, `update/3`, `search_text/3`, `list/2`.

```elixir
defmodule MyApp.Memory.Store.Tantivy do
  @behaviour Nous.Memory.Store

  alias Nous.Memory.Store.Results

  @impl true
  def init(opts) do
    index = MyApp.Tantivy.open(Keyword.fetch!(opts, :index_path))
    entries = :ets.new(:my_entries, [:set, :public])
    {:ok, %{index: index, entries: entries}}
  end

  @impl true
  def store(%{index: index, entries: entries} = state, entry) do
    true = :ets.insert(entries, {entry.id, entry})
    :ok = MyApp.Tantivy.add(index, entry.id, entry.content)
    {:ok, state}
  end

  @impl true
  def fetch(%{entries: entries}, id) do
    case :ets.lookup(entries, id) do
      [{^id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def search_text(%{index: index, entries: entries}, query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    hits = MyApp.Tantivy.search(index, query, limit)

    {:ok,
     Results.rank(
       hits,
       entries,
       Keyword.get(opts, :scope, %{}),
       Keyword.get(opts, :min_score, 0.0),
       limit
     )}
  end

  # delete/2, update/3 and list/2 elided — see Nous.Memory.Store.ETS for the shortest
  # complete implementation of all seven.
end
```

Then hand the module to the plugin. Nothing else changes:

```elixir
{:ok, state} = MyApp.Memory.Store.Tantivy.init(index_path: "/var/lib/myapp/index")

agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Memory],
  deps: %{
    memory_config: %{
      store: MyApp.Memory.Store.Tantivy,
      store_state: state
    }
  }
)
```

### The state contract

`init/1` returns an opaque `state` term. Nous never inspects it; it threads the value back
into every other callback and keeps whatever the *last* callback returned. Callbacks that
mutate therefore return `{:ok, new_state}` even when the underlying store is a mutable
handle and the term never actually changes — both `Store.ETS` and the SQL stores hand back
the same term.

A run-scoped state (ETS tables owned by the calling process, a connection opened in
`init/1`) is a valid and intentional design. There is no supervised owner and no
cross-run sharing unless your backend arranges it.

### Vector search is optional, and feature-detected

`search_vector/3` is the only optional callback. Its absence is **feature-detected, not
rescued**: `Nous.Memory.Search` calls `function_exported?(store, :search_vector, 3)` and
degrades to text-only search when the function is not there.

So a text-only backend simply does not define it. Do **not** define it and return an
error — that turns "this backend has no vector search" from a quiet capability check into
a runtime failure the search path will surface to the model.

### Return a similarity, not a distance

`Nous.Memory.Search` merges text and vector results and applies `:min_score` and the
scoring weights to whatever numbers a backend returns, so **a similarity and a distance
are not interchangeable**. Hand back a distance and your results rank backwards while
every callback still looks correct and every test that only checks shapes still passes.
Normalise to a similarity where larger is better (`Store.ETS` uses Jaro, 0..1; the SQL
stores use cosine similarity) before returning.

Both search callbacks return `{:ok, [{entry, score}]}` — highest score first, already
filtered by `:scope` and `:min_score`, already truncated to `:limit`. All search and list
callbacks accept a `:scope` option: a map of `Nous.Memory.Entry` fields to filter on.

### The shared retrieval tail

A backend owns its own retrieval, but index-plus-entry-table backends all finish the same
way. `Nous.Memory.Store.Results` is public for exactly that reason:

- `Results.rank(hits, table, scope, min_score, limit)` takes the `%{id: id, score: score}`
  maps your index returns, hydrates each id from an ETS entry table, drops out-of-scope
  entries, cuts anything at or below `min_score`, sorts descending and truncates to
  `limit`. Ids with no surviving row are dropped — the index and the side table are
  written separately, so an id can outlive its entry.
- `Results.filter_by_scope/2` and `Results.all_entries/1` are available on their own if
  you only need a piece of it.

If your backend is an index plus an entry table, `rank/5` is the whole back half of
`search_text/3`.

When a backend does keep an index and an entry table separately, order the writes so that
a failure leaves the entry absent from **both** rather than indexed but unreadable (or the
reverse). A torn write should degrade to a miss, never to a wrong result.

### Run the conformance suite

`Nous.Memory.Store.Conformance` is the contract suite Nous runs against its own backends,
and it ships in `lib/` so that out-of-tree stores can `use` it:

```elixir
defmodule MyApp.Memory.Store.TantivyConformanceTest do
  use Nous.Memory.Store.Conformance,
    store: MyApp.Memory.Store.Tantivy,
    init_opts: [index_path: "/tmp/test_index"]
end
```

That is the same battery the built-in stores are held to. `Nous.Memory.Store.ETS` is the
reference implementation — dependency-free and short enough to read in one sitting — and
`examples/memory/postgresql_full.exs` is a complete out-of-tree store (PostgreSQL with
`tsvector` and `pgvector`) written against this behaviour.

## Search & Scoring

### Text Search

Every backend that implements `search_text/3` provides keyword-based retrieval. The quality varies by backend:

- **ETS** -- `String.jaro_distance/2` (fuzzy character-level similarity). Suitable for small datasets.
- **SQLite** -- FTS5 with BM25 scoring and Porter stemming. Handles word variations ("deploy" matches "deployment").
- **DuckDB** -- `ILIKE '%query%'` substring match, scored by normalized occurrence count. No stemming; the whole query must appear literally.

Text search always works, even without an embedding provider configured.

### Vector Search

Vector search requires two things: an embedding provider, and a store that implements the optional `search_vector/3`. Of the shipped backends that means `Store.SQLite` or `Store.DuckDB` — both by scanning every embedded row, neither with an ANN index. `Store.ETS` does not implement it at all, so with an ETS store the search orchestrator degrades to text-only regardless of the embedding provider.

Three embedding providers are included:

**OpenAI** (cloud, 1536 dimensions):

```elixir
# Uses text-embedding-3-small by default
config = %{
  embedding: Nous.Memory.Embedding.OpenAI,
  embedding_opts: %{api_key: "sk-..."}  # or set OPENAI_API_KEY env var
}
```

Options: `:api_key`, `:model` (default: `"text-embedding-3-small"`), `:base_url`.

**Local / Ollama** (local, 768 dimensions):

```elixir
# Works with Ollama, vLLM, LMStudio, or any OpenAI-compatible endpoint
config = %{
  embedding: Nous.Memory.Embedding.Local,
  embedding_opts: %{
    base_url: "http://localhost:11434/v1",  # Ollama default
    model: "nomic-embed-text"               # default model
  }
}
```

Options: `:base_url` (default: `"http://localhost:11434/v1"`), `:model` (default: `"nomic-embed-text"`), `:dimension` (default: 768), `:api_key`.

**Bumblebee** (on-device, 1024 dimensions):

```elixir
# Zero API calls, fully offline. First run downloads the model (~1.2GB).
config = %{
  embedding: Nous.Memory.Embedding.Bumblebee
}
```

Requires deps: `{:bumblebee, "~> 0.6"}` and `{:exla, "~> 0.9"}`. Default model: `Alibaba-NLP/gte-Qwen2-0.6B-instruct`.

See `examples/memory/local_bumblebee.exs`.

**Custom providers**: Implement the `Nous.Memory.Embedding` behaviour (`embed/2`, `dimension/0`, and optionally `embed_batch/2`).

### Hybrid Search (BM25 + Vector)

When both text and vector search are available, the `Search` module runs them in parallel and merges results using **Reciprocal Rank Fusion (RRF)**.

RRF formula: `score(d) = sum(1 / (k + rank(d)))` across both result lists, where `k` defaults to 60. This produces a single ranked list that balances keyword precision with semantic understanding.

```elixir
# Hybrid search with an embedding provider
{:ok, results} = Search.search(
  Store.SQLite, store, "deployment process",
  Nous.Memory.Embedding.OpenAI,
  scope: %{agent_id: "assistant"},
  limit: 5
)
```

When no embedding provider is configured, the system silently falls back to text-only search. It never fails due to a missing embedding provider.

### Scoring & Decay

After retrieval and merging, every result goes through two scoring stages.

**Temporal decay** penalizes old entries:

```
decayed_score = score * exp(-lambda * hours_since_last_access)
```

- `decay_lambda` controls the rate (default: `0.001`). Higher values penalize older entries more aggressively.
- Entries marked `evergreen: true` are exempt from decay.

**Composite score** combines three signals:

```
composite = w_relevance * relevance + w_importance * importance + w_recency * recency
```

Default weights: `relevance: 0.5, importance: 0.3, recency: 0.2`. Recency is a separate exponential decay based on `last_accessed_at`.

When temporal decay is active and you have not explicitly set recency weights, the recency weight is automatically set to `0.0` to avoid double-penalizing old entries.

**Tuning weights:**

```elixir
# Favor importance over relevance
Search.search(Store.ETS, store, "query", nil,
  scoring_weights: [relevance: 0.3, importance: 0.5, recency: 0.2],
  decay_lambda: 0.005  # faster decay
)
```

## Agent Integration

### Memory Plugin

`Nous.Plugins.Memory` is the primary integration point. It handles initialization, tool registration, auto-injection, and optional auto-update.

```elixir
agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Memory],
  deps: %{
    memory_config: %{
      # Required
      store: Nous.Memory.Store.ETS,

      # Optional -- embedding
      embedding: Nous.Memory.Embedding.OpenAI,
      embedding_opts: %{api_key: "sk-..."},

      # Optional -- scoping
      agent_id: "my_agent",
      user_id: "user_123",
      namespace: "project_x",
      default_search_scope: :agent,  # :agent | :user | :session | :global

      # Optional -- auto-injection
      auto_inject: true,              # inject relevant memories before requests (default: true)
      inject_strategy: :first_only,   # :first_only | :every_iteration
      inject_limit: 5,                # max memories to inject (default: 5)
      inject_min_score: 0.3,          # minimum score threshold (default: 0.3)

      # Optional -- scoring
      scoring_weights: [relevance: 0.5, importance: 0.3, recency: 0.2],
      decay_lambda: 0.001
    }
  }
)
```

The plugin automatically:
1. Calls `store.init/1` during plugin initialization
2. Registers `remember`, `recall`, and `forget` tools
3. Injects a system prompt explaining the memory tools to the agent
4. Before each request, searches for relevant memories and appends them as a system message

### Memory Tools

The plugin provides three tools the agent can call:

- **`remember`** -- Store information. Parameters: `content` (required), `type` (`"semantic"` | `"episodic"` | `"procedural"`), `importance` (0.0-1.0), `evergreen` (boolean), `metadata` (object).
- **`recall`** -- Search memories. Parameters: `query` (required), `type` (optional filter), `limit` (default: 5). Updates `access_count` and `last_accessed_at` on returned entries.
- **`forget`** -- Delete a memory by `id`.

You can also use `Nous.Memory.Tools` functions directly if you need programmatic access outside the plugin:

```elixir
# These require a ctx with memory_config in deps
Nous.Memory.Tools.remember(ctx, %{"content" => "fact to store"})
Nous.Memory.Tools.recall(ctx, %{"query" => "search term"})
Nous.Memory.Tools.forget(ctx, %{"id" => "memory_id"})
```

### Auto-Update Memory

Instead of relying on the agent to explicitly call `remember`, you can enable automatic memory updates. After each `Nous.run/3`, a reflection step analyzes the conversation and outputs memory operations (remember, update, forget):

```elixir
agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Memory],
  deps: %{
    memory_config: %{
      store: Nous.Memory.Store.ETS,
      auto_update_memory: true,
      auto_update_every: 1,              # run reflection every N runs (default: 1)
      reflection_model: "openai:gpt-4o-mini",  # cheaper model for reflection
      reflection_max_tokens: 500,
      reflection_max_messages: 20,       # max conversation messages to include
      reflection_max_memories: 50        # max existing memories to include
    }
  }
)

{:ok, result} = Nous.run(agent, "My name is Alice and I'm a data scientist.")
# Memory automatically stored after run completes

{:ok, result2} = Nous.run(agent, "Actually I switched to ML engineering.",
  context: result.context
)
# Previous memory updated (not duplicated)
```

See `examples/memory/auto_update.exs` for a full runnable demo.

### Cross-Agent Memory

Multiple agents can share a single store while maintaining isolated views through scoping fields: `agent_id`, `session_id`, `user_id`, and `namespace`.

```elixir
# Shared store
{:ok, store} = Store.ETS.init([])

# Agent A stores with its scope
entry = Entry.new(%{
  content: "User prefers dark mode",
  agent_id: "agent_a",
  user_id: "user_1"
})
{:ok, store} = Store.ETS.store(store, entry)

# Agent B stores with its scope
entry2 = Entry.new(%{
  content: "Recommended fly.io for hosting",
  agent_id: "agent_b",
  user_id: "user_1"
})
{:ok, store} = Store.ETS.store(store, entry2)

# Scoped search -- only agent_a's memories
{:ok, results} = Search.search(Store.ETS, store, "preferences", nil,
  scope: %{agent_id: "agent_a"}
)

# User-scoped search -- all agents, one user
{:ok, results} = Search.search(Store.ETS, store, "preferences", nil,
  scope: %{user_id: "user_1"}
)

# Global search -- everything
{:ok, results} = Search.search(Store.ETS, store, "preferences", nil,
  scope: :global
)
```

The `default_search_scope` config option controls how scopes are built automatically:

| Scope | Fields used |
|-------|-------------|
| `:agent` (default) | `agent_id`, `user_id` |
| `:user` | `user_id` only |
| `:session` | `agent_id`, `session_id`, `user_id` |
| `:global` | No filtering |

See `examples/memory/cross_agent.exs`.

### Building Scopes Programmatically

`Nous.Memory.Scope` is the module behind the table above. It turns a config map into the scope value that `Search.search/5` and the store callbacks expect:

- `Nous.Memory.Scope.build/1` -- reads `:default_search_scope` from a config map and returns either `:global` or a map of scoping fields. `:session` yields `agent_id` + `session_id` + `user_id`, `:user` yields `user_id`, and `:agent` (or anything unrecognised) yields `agent_id` + `user_id`.
- `Nous.Memory.Scope.from_fields/2` -- builds a scope from an explicit field list instead of a preset. Both functions return `:global` when none of the requested fields have a value in the config, so an unscoped config never silently produces an empty-map filter.

`Nous.Plugins.Memory` and `Nous.Memory.Tools` call `build/1` for you, so you only reach for this module directly when you query a store outside the agent loop -- a background job, a LiveView, a custom tool -- and want exactly the scope the agent would have used:

```elixir
config = %{agent_id: "assistant", user_id: "alice", default_search_scope: :agent}

scope = Nous.Memory.Scope.build(config)
#=> %{agent_id: "assistant", user_id: "alice"}

{:ok, results} = Search.search(Store.ETS, store, "preferences", nil, scope: scope)

# Or pick the fields yourself:
Nous.Memory.Scope.from_fields(config, [:user_id])
#=> %{user_id: "alice"}
```

## Walkthrough: Building a Remembering Agent

A complete end-to-end example. This uses only ETS (no external deps).

```elixir
alias Nous.Memory.{Entry, Store, Search}

# 1. Create an ETS store and populate it with some knowledge
{:ok, store} = Store.ETS.init([])

seed_memories = [
  Entry.new(%{
    content: "User's name is Alice",
    importance: 0.9,
    agent_id: "assistant",
    user_id: "alice"
  }),
  Entry.new(%{
    content: "Alice works on the billing team",
    importance: 0.7,
    agent_id: "assistant",
    user_id: "alice"
  }),
  Entry.new(%{
    content: "Deploy process: mix release, then docker build, then push to fly.io",
    type: :procedural,
    importance: 0.8,
    evergreen: true,
    agent_id: "assistant",
    user_id: "alice"
  })
]

store = Enum.reduce(seed_memories, store, fn entry, s ->
  {:ok, s} = Store.ETS.store(s, entry)
  s
end)

# 2. Configure the memory plugin
memory_config = %{
  store: Store.ETS,
  store_state: store,        # pass pre-populated store state
  agent_id: "assistant",
  user_id: "alice",
  auto_inject: true,
  inject_limit: 3,
  inject_min_score: 0.3,
  scoring_weights: [relevance: 0.5, importance: 0.3, recency: 0.2]
}

# 3. Create an agent with memory
agent = Nous.new("openai:gpt-4o",
  plugins: [Nous.Plugins.Memory],
  instructions: "You are a helpful assistant with persistent memory.",
  deps: %{memory_config: memory_config}
)

# 4. The agent stores new facts via the `remember` tool
{:ok, result} = Nous.run(agent, "I just got promoted to team lead. Remember that!")
IO.puts(result.output)

# 5. In a new conversation turn, the agent recalls facts
# Relevant memories are auto-injected before the request
{:ok, result2} = Nous.run(agent, "What do you know about me?",
  context: result.context
)
IO.puts(result2.output)
# The agent can reference: name, team, promotion, deploy process

# 6. Inspect search results with scores
config = result2.context.deps[:memory_config]
{:ok, results} = Search.search(
  config[:store], config[:store_state], "Alice role",
  nil,
  scope: %{agent_id: "assistant", user_id: "alice"},
  limit: 5
)

IO.puts("\nSearch results for 'Alice role':")
for {entry, score} <- results do
  IO.puts("  [#{Float.round(score, 3)}] (#{entry.type}) #{entry.content}")
end
```

## Advanced Topics

### Custom Store Backends

See [Bringing Your Own Backend](#bringing-your-own-backend) above: implement
`@behaviour Nous.Memory.Store`, pass the module as `:store`, and hold yourself to the
contract with `use Nous.Memory.Store.Conformance`.

### Embedding Dimension Mismatches

Your embedding provider dimension must match your store's vector configuration. Common dimensions:

| Provider | Dimension |
|----------|-----------|
| OpenAI `text-embedding-3-small` | 1536 |
| Local / Ollama `nomic-embed-text` | 768 |
| Bumblebee `gte-Qwen2-0.6B-instruct` | 1024 |

No shipped store takes an `embedding_dimension` option — none of them declare a vector width up front, and embeddings are persisted at whatever length the provider produced. The dimensions still have to agree: if you point a new provider at a store populated by an old one, `Store.SQLite` scores every length-mismatched row `0.0`, so old entries silently vanish from vector results rather than erroring. Re-embed the corpus when you change providers, or give each provider its own store.

### Memory Entry Lifecycle

Each `Entry` tracks:

- `access_count` -- incremented each time the entry is returned by `recall`. Useful for identifying frequently-accessed memories.
- `last_accessed_at` -- updated on each `recall`. Drives temporal decay and recency scoring.
- `updated_at` -- set when the entry is modified via `update/3`.
- `created_at` -- set once at creation time.

### Memory Types

Entries have a `:type` field (`:semantic`, `:episodic`, or `:procedural`):

- **Semantic** (default) -- Facts and knowledge ("User prefers dark mode").
- **Episodic** -- Events and experiences ("Had a meeting about the migration on Monday").
- **Procedural** -- How-to and processes ("To deploy: run mix release then docker build").

Types can be used as search filters: `Search.search(mod, state, query, nil, type: :procedural)`.

### Namespaces

Use the `:namespace` field to organize memories into groups without changing the scoping logic:

```elixir
Entry.new(%{
  content: "API rate limit is 100 req/min",
  namespace: "api_docs",
  agent_id: "assistant"
})
```

You can then filter by namespace in scope: `scope: %{namespace: "api_docs"}`.

## Examples

Working examples are in the `examples/memory/` directory:

| File | Description |
|------|-------------|
| `basic_ets.exs` | Minimal ETS setup, store and search |
| `sqlite_full.exs` | SQLite with FTS5 BM25 search |
| `duckdb_full.exs` | DuckDB with native array embeddings |
| `postgresql_full.exs` | A complete out-of-tree `Nous.Memory.Store` (PostgreSQL + pgvector) |
| `local_bumblebee.exs` | On-device embeddings with Bumblebee |
| `cross_agent.exs` | Multi-agent shared memory with scoping |
| `auto_update.exs` | Automatic memory updates after each run |

Run any example with:

```bash
mix run examples/memory/basic_ets.exs
```

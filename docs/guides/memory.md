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

Six backends are available. All implement the `Nous.Memory.Store` behaviour.

| Backend | Text Search | Vector Search | External Deps |
|---------|-------------|---------------|---------------|
| `Store.ETS` | Jaro distance | No | None |
| `Store.SQLite` | FTS5 (BM25) | Cosine similarity | `exqlite` |
| `Store.DuckDB` | ILIKE / FTS extension | `list_cosine_similarity` | `duckdbex` |
| `Store.Muninn` | Tantivy BM25 | No | `muninn` |
| `Store.Zvec` | No | HNSW/IVF | `zvec` |
| `Store.Hybrid` | Tantivy BM25 | HNSW/IVF | `muninn` + `zvec` |

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

SQLite uses FTS5 with Porter stemming and unicode tokenization for text search. BM25 scoring is handled natively by SQLite. Vector search is implemented via in-Elixir cosine similarity over JSON-encoded embedding blobs.

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

DuckDB stores embeddings in native `DOUBLE[]` array columns and uses `list_cosine_similarity` for vector search. Text search uses ILIKE as a fallback (the FTS extension is loaded if available but not required).

See `examples/memory/duckdb_full.exs`.

### Muninn (Tantivy)

Best for: production BM25 text search without vector needs.

Add to `mix.exs`:

```elixir
{:muninn, "~> 0.4"}
```

Initialize:

```elixir
{:ok, store} = Nous.Memory.Store.Muninn.init(index_path: "/tmp/muninn_index")
```

Uses Tantivy (Rust-based search engine) via Muninn for high-quality BM25 text search. Entry data is stored in ETS alongside the Tantivy index. Does not support `search_vector/3`.

### Hybrid (Muninn + Zvec)

Best for: production with both BM25 text search and vector similarity search.

Add to `mix.exs`:

```elixir
{:muninn, "~> 0.4"},
{:zvec, "~> 0.1"}
```

Initialize:

```elixir
{:ok, store} = Nous.Memory.Store.Hybrid.init(
  muninn_config: %{index_path: "/tmp/muninn_index"},
  zvec_config: %{
    collection_path: "/tmp/zvec_collection",
    embedding_dimension: 1536  # must match your embedding provider
  }
)
```

The Hybrid store coordinates two backends: Muninn handles `search_text/3` (Tantivy BM25) and Zvec handles `search_vector/3` (HNSW/IVF). A shared ETS table is the source of truth for entry data. When you call `Search.search/5`, the search orchestrator runs both backends in parallel and merges results via RRF.

See `examples/memory/hybrid_full.exs`.

### Zvec (Vector-Only)

Best for: pure semantic search when you always have embeddings and don't need keyword matching.

Add to `mix.exs`:

```elixir
{:zvec, "~> 0.1"}
```

Initialize:

```elixir
{:ok, store} = Nous.Memory.Store.Zvec.init(
  collection_path: "/tmp/zvec_collection",
  embedding_dimension: 1536
)
```

Vector-only backend. Does not implement `search_text/3`. All entries must include embeddings.

## Search & Scoring

### Text Search

Every backend that implements `search_text/3` provides keyword-based retrieval. The quality varies by backend:

- **ETS** -- `String.jaro_distance/2` (fuzzy character-level similarity). Suitable for small datasets.
- **SQLite** -- FTS5 with BM25 scoring and Porter stemming. Handles word variations ("deploy" matches "deployment").
- **DuckDB** -- ILIKE-based matching as fallback, FTS extension if available.
- **Muninn/Hybrid** -- Tantivy BM25 (same algorithm as Elasticsearch/Lucene). Best for production.

Text search always works, even without an embedding provider configured.

### Vector Search

Vector search requires two things: an embedding provider and a store that implements `search_vector/3` (SQLite, DuckDB, Zvec, or Hybrid).

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

Implement the `Nous.Memory.Store` behaviour:

```elixir
defmodule MyApp.Memory.Store.Redis do
  @behaviour Nous.Memory.Store

  @impl true
  def init(opts), do: # connect to Redis, return {:ok, state}

  @impl true
  def store(state, %Entry{} = entry), do: # persist entry, return {:ok, state}

  @impl true
  def fetch(state, id), do: # return {:ok, entry} | {:error, :not_found}

  @impl true
  def delete(state, id), do: # return {:ok, state}

  @impl true
  def update(state, id, updates), do: # return {:ok, state}

  @impl true
  def search_text(state, query, opts), do: # return {:ok, [{entry, score}]}

  @impl true
  def list(state, opts), do: # return {:ok, [entry]}

  # Optional -- implement for vector search support:
  # @impl true
  # def search_vector(state, embedding, opts), do: # return {:ok, [{entry, score}]}
end
```

The `search_vector/3` callback is optional. The search orchestrator checks for it at runtime via `function_exported?/3` and falls back to text-only when it is not available.

### Embedding Dimension Mismatches

Your embedding provider dimension must match your store's vector configuration. Common dimensions:

| Provider | Dimension |
|----------|-----------|
| OpenAI `text-embedding-3-small` | 1536 |
| Local / Ollama `nomic-embed-text` | 768 |
| Bumblebee `gte-Qwen2-0.6B-instruct` | 1024 |

When using `Store.Hybrid` or `Store.Zvec`, set `embedding_dimension` in the init options to match. If dimensions mismatch, vector search will return incorrect results or errors.

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
| `hybrid_full.exs` | Muninn + Zvec hybrid search |
| `local_bumblebee.exs` | On-device embeddings with Bumblebee |
| `cross_agent.exs` | Multi-agent shared memory with scoping |
| `auto_update.exs` | Automatic memory updates after each run |

Run any example with:

```bash
mix run examples/memory/basic_ets.exs
```

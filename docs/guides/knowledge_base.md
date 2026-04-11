# Knowledge Base Guide

LLM-compiled personal knowledge base system. Raw documents get ingested, compiled by an LLM into structured markdown wiki entries with summaries, backlinks, cross-references, and semantic search.

Inspired by [Karpathy's vision](https://x.com/karpathy) of knowledge bases where LLMs serve as the compiler — transforming unstructured documents into a structured, interconnected wiki.

## Architecture

```
Raw Documents  →  LLM Compiler  →  Wiki Entries  →  Search / Q&A / Generate
  (markdown,       (extracts         (structured       (semantic search,
   text, URLs)      concepts,         articles with     backlinks,
                    compiles)         [[wiki-links]])   reports)
```

**Three usage modes:**

| Mode | Best For | Entry Point |
|------|----------|-------------|
| **Plugin** | Interactive — add KB tools to any agent | `Nous.Plugins.KnowledgeBase` |
| **Agent Behaviour** | KB-specialized agent with reasoning tools | `Nous.Agents.KnowledgeBaseAgent` |
| **Workflow** | Batch operations (ingest, health check) | `Nous.KnowledgeBase.Workflows` |

## Quick Start — Plugin Mode

The simplest way to add knowledge base capabilities to an agent:

```elixir
agent = Nous.Agent.new("openai:gpt-4",
  plugins: [Nous.Plugins.KnowledgeBase],
  deps: %{
    kb_config: %{
      store: Nous.KnowledgeBase.Store.ETS,
      kb_id: "my_kb"
    }
  }
)

# Ingest a document
{:ok, r1} = Nous.run(agent, """
Ingest this article:

# Understanding GenServers
GenServers are the workhorse of OTP. They provide a client-server abstraction
where the server runs as a separate process...
""")

# Query the knowledge base
{:ok, r2} = Nous.run(agent, "What do we know about GenServers?", context: r1.context)

# Generate a report
{:ok, r3} = Nous.run(agent, "Generate a summary report of all OTP concepts", context: r2.context)
```

### With Semantic Search

Add an embedding provider for vector-based search:

```elixir
agent = Nous.Agent.new("openai:gpt-4",
  plugins: [Nous.Plugins.KnowledgeBase],
  deps: %{
    kb_config: %{
      store: Nous.KnowledgeBase.Store.ETS,
      kb_id: "my_kb",
      embedding: Nous.Memory.Embedding.OpenAI,
      embedding_opts: %{api_key: System.get_env("OPENAI_API_KEY")}
    }
  }
)
```

### Composing with Memory

The KB plugin works alongside `Nous.Plugins.Memory`:

```elixir
agent = Nous.Agent.new("openai:gpt-4",
  plugins: [Nous.Plugins.Memory, Nous.Plugins.KnowledgeBase],
  deps: %{
    memory_config: %{store: Nous.Memory.Store.ETS},
    kb_config: %{store: Nous.KnowledgeBase.Store.ETS, kb_id: "my_kb"}
  }
)
```

Memory stores personal/episodic information; the knowledge base stores compiled reference material.

## Agent Behaviour Mode

For a KB-specialized agent with additional reasoning tools:

```elixir
agent = Nous.Agent.new("openai:gpt-4",
  behaviour_module: Nous.Agents.KnowledgeBaseAgent,
  plugins: [Nous.Plugins.KnowledgeBase],
  deps: %{kb_config: %{store: Nous.KnowledgeBase.Store.ETS, kb_id: "my_kb"}}
)
```

The `KnowledgeBaseAgent` adds 4 reasoning tools on top of the 9 standard KB tools:

| Tool | Purpose |
|------|---------|
| `kb_plan_compilation` | Plan which entries to create from documents |
| `kb_verify_entry` | Cross-check an entry against source documents |
| `kb_suggest_links` | Suggest links between entries |
| `kb_summarize_topic` | Synthesize across multiple entries |

## Workflow Mode

For batch operations without an interactive agent:

### Batch Ingest

```elixir
config = %{
  store: Nous.KnowledgeBase.Store.ETS,
  kb_id: "my_kb"
}

{:ok, state} = Nous.KnowledgeBase.ingest(
  [
    %{title: "GenServer Guide", content: "...", doc_type: :markdown},
    %{title: "Supervisor Patterns", content: "...", doc_type: :markdown}
  ],
  kb_config: config
)
```

### Health Check

```elixir
{:ok, state} = Nous.KnowledgeBase.health_check(kb_config: config)
report = state.data.health_report
# => %HealthReport{issues: [...], coverage_score: 0.85, ...}
```

### Incremental Update

```elixir
{:ok, state} = Nous.KnowledgeBase.incremental_update(
  [%{title: "Updated Article", content: "..."}],
  kb_config: config
)
```

### Output Generation

```elixir
{:ok, state} = Nous.KnowledgeBase.generate_output(
  "executive_summary",
  kb_config: config
)
```

## Data Model

### Documents

Raw source material before compilation:

```elixir
%Nous.KnowledgeBase.Document{
  id: "doc_abc123",
  title: "Understanding GenServers",
  content: "...",
  doc_type: :markdown,        # :markdown | :text | :url | :pdf | :html
  status: :compiled,          # :pending | :processing | :compiled | :failed
  checksum: "sha256:...",
  compiled_entry_ids: ["entry_1", "entry_2"],
  kb_id: "my_kb"
}
```

### Entries

Compiled wiki articles — the core unit of the knowledge base:

```elixir
%Nous.KnowledgeBase.Entry{
  id: "entry_1",
  title: "GenServer",
  slug: "genserver",
  content: "GenServer is the core [[otp]] abstraction for...",
  summary: "Client-server abstraction for stateful processes",
  entry_type: :concept,       # :article | :concept | :summary | :index | :glossary
  concepts: ["genserver", "otp", "processes"],
  tags: ["elixir", "otp"],
  confidence: 0.95,
  source_doc_ids: ["doc_abc123"],
  kb_id: "my_kb"
}
```

### Links

Typed directional connections between entries:

```elixir
%Nous.KnowledgeBase.Link{
  source_id: "entry_1",
  target_id: "entry_2",
  link_type: :related,        # :related | :subtopic | :prerequisite | :contradicts | :extends | :references
  label: "GenServer implements OTP behaviour"
}
```

### Health Reports

Audit results from health checks:

```elixir
%Nous.KnowledgeBase.HealthReport{
  total_entries: 42,
  total_links: 128,
  total_documents: 15,
  coverage_score: 0.85,
  freshness_score: 0.92,
  coherence_score: 0.78,
  issues: [
    %{type: :orphan, entry_id: "entry_5", severity: :medium,
      description: "No incoming links", suggested_action: "Add links from related entries"}
  ]
}
```

## Tools Reference

The plugin provides 9 tools to agents:

| Tool | Description |
|------|-------------|
| `kb_search` | Search entries by query, tags, or entry type |
| `kb_read` | Read a specific entry by slug or ID |
| `kb_list` | List all entries with optional filters |
| `kb_ingest` | Ingest a raw document into the KB |
| `kb_add_entry` | Add a compiled wiki entry |
| `kb_link` | Create a typed link between entries |
| `kb_backlinks` | Find all entries linking to a given entry |
| `kb_health_check` | Audit the KB for issues |
| `kb_generate` | Generate reports, summaries, or slides from KB content |

## Store Backends

### ETS (built-in)

Zero-dependency in-memory backend. Suitable for development, testing, and single-node deployments:

```elixir
%{store: Nous.KnowledgeBase.Store.ETS}
```

Features: Jaro-distance text search, optional vector search with embeddings, scoped by `kb_id`.

### Custom Backends

Implement the `Nous.KnowledgeBase.Store` behaviour (15 callbacks) for custom backends:

```elixir
defmodule MyApp.KBStore.Postgres do
  @behaviour Nous.KnowledgeBase.Store

  @impl true
  def init(opts), do: ...

  @impl true
  def store_entry(state, entry), do: ...

  # ... 13 more callbacks
end
```

## Configuration Reference

All configuration is passed via `deps[:kb_config]`:

| Key | Required | Description |
|-----|----------|-------------|
| `:store` | Yes | Store backend module |
| `:kb_id` | No | Namespace for this knowledge base |
| `:store_opts` | No | Options passed to `store.init/1` |
| `:embedding` | No | Embedding provider module |
| `:embedding_opts` | No | Embedding provider options |
| `:compiler_model` | No | Model for workflow LLM steps (default: `"openai:gpt-4o-mini"`) |

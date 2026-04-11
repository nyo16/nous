defmodule Nous.KnowledgeBase do
  @moduledoc """
  LLM-compiled personal knowledge base system.

  Inspired by Karpathy's vision: raw documents get ingested, an LLM compiles
  them into a markdown wiki with summaries, backlinks, and cross-references.
  You can Q&A over it, generate outputs, and run health checks.

  ## Quick Start — Plugin Mode

  Add the KB plugin to any agent for interactive use:

      agent = Nous.Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.KnowledgeBase],
        deps: %{
          kb_config: %{
            store: Nous.KnowledgeBase.Store.ETS,
            kb_id: "my_kb"
          }
        }
      )

      {:ok, result} = Nous.Agent.run(agent, "Ingest this article: ...")
      {:ok, result} = Nous.Agent.run(agent, "What do we know about GenServers?")

  ## Quick Start — Workflow Mode

  For batch operations, use the workflow API:

      # Batch ingest
      {:ok, state} = Nous.KnowledgeBase.ingest(
        [%{title: "Article 1", content: "..."}],
        kb_config: config
      )

      # Health check
      {:ok, state} = Nous.KnowledgeBase.health_check(kb_config: config)

  ## Quick Start — Agent Behaviour Mode

  For a KB-specialized agent:

      agent = Nous.Agent.new("openai:gpt-4",
        behaviour_module: Nous.Agents.KnowledgeBaseAgent,
        plugins: [Nous.Plugins.KnowledgeBase],
        deps: %{kb_config: %{store: Nous.KnowledgeBase.Store.ETS, kb_id: "my_kb"}}
      )

  ## Architecture

  The KB system has four composable layers:

  1. **Data model & store** — `Document`, `Entry`, `Link`, `HealthReport` structs
     with a pluggable `Store` behaviour (ETS, SQLite, etc.)
  2. **Plugin & tools** — `Nous.Plugins.KnowledgeBase` integrates with any agent,
     providing 9 tools (search, read, ingest, add_entry, link, backlinks, list,
     health_check, generate)
  3. **Workflows** — Pre-built DAG pipelines for ingest, incremental update,
     health check, and output generation
  4. **Agent behaviour** — `Nous.Agents.KnowledgeBaseAgent` for specialized
     KB curation and reasoning
  """

  alias Nous.KnowledgeBase.Workflows

  @doc """
  Ingest documents through the full compilation pipeline.

  ## Options

    * `:kb_config` - Required. Knowledge base configuration map.
    * `:compiler_model` - Model for compilation (default: "openai:gpt-4o-mini")
    * `:embedding` - Embedding provider module
    * `:embedding_opts` - Embedding options
  """
  def ingest(documents, opts) do
    pipeline = Workflows.build_ingest_pipeline(opts)
    kb_config = Keyword.fetch!(opts, :kb_config)
    Nous.Workflow.run(pipeline, %{documents: documents, kb_config: kb_config}, opts)
  end

  @doc """
  Incrementally update the knowledge base with new or changed documents.
  """
  def incremental_update(documents, opts) do
    pipeline = Workflows.build_incremental_pipeline(opts)
    kb_config = Keyword.fetch!(opts, :kb_config)
    Nous.Workflow.run(pipeline, %{documents: documents, kb_config: kb_config}, opts)
  end

  @doc """
  Run a health check audit on the knowledge base.
  """
  def health_check(opts) do
    pipeline = Workflows.build_health_check_pipeline(opts)
    kb_config = Keyword.fetch!(opts, :kb_config)
    Nous.Workflow.run(pipeline, %{kb_config: kb_config}, opts)
  end

  @doc """
  Generate structured output from the knowledge base.

  ## Parameters

    * `output_type` - `:report`, `:summary`, or `:slides`
    * `opts` - Must include `:kb_config` and `:topic`
  """
  def generate(output_type, opts) do
    pipeline = Workflows.build_output_pipeline(opts)
    kb_config = Keyword.fetch!(opts, :kb_config)
    topic = Keyword.fetch!(opts, :topic)

    Nous.Workflow.run(
      pipeline,
      %{topic: topic, output_type: output_type, kb_config: kb_config},
      opts
    )
  end

  # ---------------------------------------------------------------------------
  # Direct store access (no LLM needed)
  # ---------------------------------------------------------------------------

  @doc """
  Search knowledge base entries directly.
  """
  def search(store_mod, store_state, query, opts \\ []) do
    store_mod.search_entries(store_state, query, opts)
  end

  @doc """
  Get a specific entry by slug or ID.
  """
  def get_entry(store_mod, store_state, slug_or_id) do
    case store_mod.fetch_entry_by_slug(store_state, slug_or_id) do
      {:ok, _} = result -> result
      {:error, :not_found} -> store_mod.fetch_entry(store_state, slug_or_id)
    end
  end

  @doc """
  List all entries, optionally filtered.
  """
  def list_entries(store_mod, store_state, opts \\ []) do
    store_mod.list_entries(store_state, opts)
  end

  @doc """
  List all documents, optionally filtered.
  """
  def list_documents(store_mod, store_state, opts \\ []) do
    store_mod.list_documents(store_state, opts)
  end

  @doc """
  Get backlinks for an entry.
  """
  def backlinks(store_mod, store_state, entry_id) do
    store_mod.backlinks(store_state, entry_id)
  end

  @doc """
  Get related entries (connected by any link direction).
  """
  def related_entries(store_mod, store_state, entry_id, opts \\ []) do
    store_mod.related_entries(store_state, entry_id, opts)
  end
end

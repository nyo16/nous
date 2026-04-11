defmodule Nous.Plugins.KnowledgeBase do
  @moduledoc """
  Plugin for LLM-compiled knowledge base with wiki-style entries.

  Provides tools for agents to ingest documents, compile wiki entries,
  search and query the knowledge base, and run health checks.

  ## Usage

      # Minimal — ETS store
      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.KnowledgeBase],
        deps: %{kb_config: %{store: Nous.KnowledgeBase.Store.ETS, kb_id: "my_kb"}}
      )

      # With embeddings for semantic search
      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.KnowledgeBase],
        deps: %{
          kb_config: %{
            store: Nous.KnowledgeBase.Store.ETS,
            kb_id: "my_kb",
            embedding: Nous.Memory.Embedding.OpenAI,
            embedding_opts: %{api_key: "sk-..."}
          }
        }
      )

  ## Composition with Memory Plugin

  The KB plugin composes cleanly with `Nous.Plugins.Memory`:

      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Memory, Nous.Plugins.KnowledgeBase],
        deps: %{
          memory_config: %{store: Nous.Memory.Store.ETS},
          kb_config: %{store: Nous.KnowledgeBase.Store.ETS, kb_id: "my_kb"}
        }
      )

  ## Configuration (via `deps[:kb_config]`)

  **Required:**
    * `:store` - Store backend module (e.g. `Nous.KnowledgeBase.Store.ETS`)

  **Optional — store:**
    * `:store_opts` - Options passed to `store.init/1`
    * `:kb_id` - Namespace for this knowledge base

  **Optional — embedding:**
    * `:embedding` - Embedding provider module (reuses `Nous.Memory.Embedding.*`)
    * `:embedding_opts` - Options passed to embedding provider

  **Optional — auto-injection:**
    * `:auto_inject` - Auto-inject relevant KB entries before each request (default: true)
    * `:inject_strategy` - `:first_only` (default) or `:every_iteration`
    * `:inject_limit` - Max entries to inject (default: 3)
    * `:inject_min_score` - Minimum score for injection (default: 0.3)

  **Optional — compilation:**
    * `:compiler_model` - Model string for compilation LLM calls
    * `:auto_compile` - Auto-compile pending documents after runs (default: false)
  """

  @behaviour Nous.Plugin

  require Logger

  alias Nous.KnowledgeBase.Tools

  @impl true
  def init(_agent, ctx) do
    config = ctx.deps[:kb_config] || %{}
    store_mod = config[:store]

    unless store_mod do
      Logger.warning(
        "Nous.Plugins.KnowledgeBase: No :store configured in deps[:kb_config]. " <>
          "Knowledge base tools will not function."
      )

      ctx
    else
      store_opts = Map.get(config, :store_opts, [])
      store_opts = if is_map(store_opts), do: Map.to_list(store_opts), else: store_opts

      case store_mod.init(store_opts) do
        {:ok, store_state} ->
          updated_config =
            config
            |> Map.put(:store_state, store_state)
            |> Map.put_new(:auto_inject, true)
            |> Map.put_new(:inject_strategy, :first_only)
            |> Map.put_new(:inject_limit, 3)
            |> Map.put_new(:inject_min_score, 0.3)
            |> Map.put_new(:auto_compile, false)
            |> Map.put(:_inject_done, false)

          %{ctx | deps: Map.put(ctx.deps, :kb_config, updated_config)}

        {:error, reason} ->
          Logger.error("Nous.Plugins.KnowledgeBase: Store init failed: #{inspect(reason)}")
          ctx
      end
    end
  end

  @impl true
  def tools(_agent, _ctx) do
    Tools.all_tools()
  end

  @impl true
  def system_prompt(_agent, ctx) do
    config = ctx.deps[:kb_config] || %{}

    if config[:store_state] do
      """
      ## Knowledge Base

      You have access to a curated knowledge base wiki. Use these tools:
      - `kb_search` — Search the wiki for relevant entries
      - `kb_read` — Read a specific entry by slug or ID
      - `kb_ingest` — Add a raw document for LLM compilation
      - `kb_add_entry` — Directly create or update a wiki entry
      - `kb_link` — Create a link between entries
      - `kb_backlinks` — Find entries linking to a given entry
      - `kb_list` — List entries filtered by tag/concept/type
      - `kb_health_check` — Audit the wiki for issues
      - `kb_generate` — Generate a report or summary from entries

      When answering questions, search the knowledge base first. Use [[slug]] format \
      for wiki-links between entries. Cite which entries you used in your answer.\
      """
    end
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    config = ctx.deps[:kb_config] || %{}

    should_inject? =
      config[:auto_inject] == true &&
        config[:store_state] != nil &&
        should_inject_this_iteration?(config)

    if should_inject? do
      ctx = inject_relevant_entries(ctx, config)
      updated_config = Map.put(config, :_inject_done, true)
      ctx = %{ctx | deps: Map.put(ctx.deps, :kb_config, updated_config)}
      {ctx, tools}
    else
      {ctx, tools}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp should_inject_this_iteration?(config) do
    case config[:inject_strategy] do
      :every_iteration -> true
      _ -> config[:_inject_done] != true
    end
  end

  defp inject_relevant_entries(ctx, config) do
    query = latest_user_query(ctx.messages)

    if query do
      store_mod = config[:store]
      store_state = config[:store_state]
      limit = config[:inject_limit] || 3
      min_score = config[:inject_min_score] || 0.3

      search_opts = [
        limit: limit,
        min_score: min_score,
        kb_id: config[:kb_id]
      ]

      case store_mod.search_entries(store_state, query, search_opts) do
        {:ok, []} ->
          ctx

        {:ok, results} ->
          kb_text =
            results
            |> Enum.map(fn {entry, score} ->
              summary = entry.summary || String.slice(entry.content, 0, 200)
              "- [[#{entry.slug}]] #{entry.title} (score: #{Float.round(score, 3)}): #{summary}"
            end)
            |> Enum.join("\n")

          kb_msg = Nous.Message.system("[Relevant Knowledge]\n#{kb_text}")
          %{ctx | messages: ctx.messages ++ [kb_msg]}

        _ ->
          ctx
      end
    else
      ctx
    end
  end

  defp latest_user_query(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :user, content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end
end

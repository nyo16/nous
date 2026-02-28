defmodule Nous.Plugins.Memory do
  @moduledoc """
  Plugin for persistent agent memory with hybrid search.

  Provides tools for agents to remember, recall, and forget information
  across conversations. Supports text-based keyword search and optional
  vector-based semantic search when an embedding provider is configured.

  ## Usage

      # Minimal — ETS store, keyword-only search
      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Memory],
        deps: %{memory_config: %{store: Nous.Memory.Store.ETS}}
      )

      # With embeddings for semantic search
      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Memory],
        deps: %{
          memory_config: %{
            store: Nous.Memory.Store.ETS,
            embedding: Nous.Memory.Embedding.OpenAI,
            embedding_opts: %{api_key: "sk-..."}
          }
        }
      )

  ## Configuration (via `deps[:memory_config]`)

  **Required:**
    * `:store` - Store backend module (e.g. `Nous.Memory.Store.ETS`)

  **Optional — store:**
    * `:store_opts` - Options passed to `store.init/1`

  **Optional — embedding:**
    * `:embedding` - Embedding provider module (e.g. `Nous.Memory.Embedding.OpenAI`)
    * `:embedding_opts` - Options passed to embedding provider

  **Optional — scoping:**
    * `:agent_id` - Tag memories with this agent ID
    * `:session_id` - Tag memories with this session ID
    * `:user_id` - Tag memories with this user ID
    * `:namespace` - Arbitrary namespace grouping
    * `:default_search_scope` - `:agent` (default), `:user`, `:session`, or `:global`

  **Optional — auto-injection:**
    * `:auto_inject` - Auto-inject relevant memories before each request (default: true)
    * `:inject_strategy` - `:first_only` (default) or `:every_iteration`
    * `:inject_limit` - Max memories to inject (default: 5)
    * `:inject_min_score` - Minimum score for injection (default: 0.3)

  **Optional — scoring:**
    * `:scoring_weights` - `[relevance: 0.5, importance: 0.3, recency: 0.2]`
    * `:decay_lambda` - Temporal decay rate (default: 0.001)
  """

  @behaviour Nous.Plugin

  require Logger

  alias Nous.Memory.{Search, Tools}

  @impl true
  def init(_agent, ctx) do
    config = ctx.deps[:memory_config] || %{}
    store_mod = config[:store]

    unless store_mod do
      Logger.warning(
        "Nous.Plugins.Memory: No :store configured in deps[:memory_config]. " <>
          "Memory tools will not function."
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
            |> Map.put_new(:inject_limit, 5)
            |> Map.put_new(:inject_min_score, 0.3)
            |> Map.put_new(:decay_lambda, 0.001)
            |> Map.put_new(:default_search_scope, :agent)
            |> Map.put(:_inject_done, false)

          %{ctx | deps: Map.put(ctx.deps, :memory_config, updated_config)}

        {:error, reason} ->
          Logger.error("Nous.Plugins.Memory: Store init failed: #{inspect(reason)}")
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
    config = ctx.deps[:memory_config] || %{}

    if config[:store_state] do
      """
      ## Memory

      You have access to a persistent memory system. Use these tools:
      - `remember` — Store important facts, user preferences, decisions, or context for later.
      - `recall` — Search your memory for relevant information before answering questions.
      - `forget` — Remove a specific memory by ID.

      When the user tells you something important about themselves or their preferences, \
      proactively use `remember` to store it. When answering questions, consider using `recall` \
      first to check if you have relevant memories.\
      """
    end
  end

  @impl true
  def before_request(_agent, ctx, tools) do
    config = ctx.deps[:memory_config] || %{}

    should_inject? =
      config[:auto_inject] == true &&
        config[:store_state] != nil &&
        should_inject_this_iteration?(config)

    if should_inject? do
      ctx = inject_relevant_memories(ctx, config)
      # Mark injection as done for :first_only strategy
      updated_config = Map.put(config, :_inject_done, true)
      ctx = %{ctx | deps: Map.put(ctx.deps, :memory_config, updated_config)}
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
      # :first_only is default
      _ -> config[:_inject_done] != true
    end
  end

  defp inject_relevant_memories(ctx, config) do
    # Find the latest user message
    query = latest_user_query(ctx.messages)

    if query do
      store_mod = config[:store]
      store_state = config[:store_state]
      embedding_provider = config[:embedding]
      embedding_opts = Map.get(config, :embedding_opts, [])

      embedding_opts =
        if is_map(embedding_opts), do: Map.to_list(embedding_opts), else: embedding_opts

      limit = config[:inject_limit] || 5
      min_score = config[:inject_min_score] || 0.3

      scope =
        case config[:default_search_scope] do
          :global -> :global
          :session -> scope_from_config(config, [:agent_id, :session_id, :user_id])
          :user -> scope_from_config(config, [:user_id])
          _ -> scope_from_config(config, [:agent_id, :user_id])
        end

      search_opts = [
        scope: scope,
        limit: limit,
        min_score: min_score,
        scoring_weights: config[:scoring_weights] || [],
        decay_lambda: config[:decay_lambda] || 0.001,
        embedding_opts: embedding_opts
      ]

      case Search.search(store_mod, store_state, query, embedding_provider, search_opts) do
        {:ok, []} ->
          ctx

        {:ok, results} ->
          memory_text =
            results
            |> Enum.map(fn {entry, score} ->
              "- [#{entry.type}] (score: #{Float.round(score, 3)}) #{entry.content}"
            end)
            |> Enum.join("\n")

          memory_msg =
            Nous.Message.system("[Relevant Memories]\n#{memory_text}")

          %{ctx | messages: ctx.messages ++ [memory_msg]}
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

  defp scope_from_config(config, fields) do
    fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(config, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> :global
      scope -> scope
    end
  end
end

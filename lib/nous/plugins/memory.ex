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

  alias Nous.Memory.{Embedding, Entry, Search, Tools}

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
            |> Map.put_new(:auto_update_memory, false)
            |> Map.put_new(:auto_update_every, 1)
            |> Map.put_new(:reflection_max_tokens, 1000)
            |> Map.put_new(:reflection_max_messages, 20)
            |> Map.put_new(:reflection_max_memories, 50)
            |> Map.put_new(:_run_count, 0)

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

  @impl true
  def after_run(agent, _result, ctx) do
    config = ctx.deps[:memory_config] || %{}

    if config[:auto_update_memory] == true && config[:store_state] != nil do
      run_count = (config[:_run_count] || 0) + 1
      auto_update_every = config[:auto_update_every] || 1

      ctx =
        if rem(run_count, auto_update_every) == 0 do
          do_memory_reflection(agent, ctx, config)
        else
          ctx
        end

      # Always persist the updated run count
      updated_config = Map.put(ctx.deps[:memory_config] || config, :_run_count, run_count)
      %{ctx | deps: Map.put(ctx.deps, :memory_config, updated_config)}
    else
      ctx
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_memory_reflection(agent, ctx, config) do
    store_mod = config[:store]
    store_state = config[:store_state]
    max_messages = config[:reflection_max_messages] || 20
    max_memories = config[:reflection_max_memories] || 50
    max_tokens = config[:reflection_max_tokens] || 1000

    # Determine model for reflection: explicit config, or fall back to agent's model
    reflection_model =
      config[:reflection_model] ||
        "#{agent.model.provider}:#{agent.model.model}"

    if reflection_model do
      # 1. Format recent conversation messages (skip system messages)
      conversation_text = format_conversation(ctx.messages, max_messages)

      # 2. Fetch existing memories
      scope = build_memory_scope(config)

      existing_memories =
        case store_mod.list(store_state, scope: scope, limit: max_memories) do
          {:ok, entries} -> entries
          _ -> []
        end

      memories_text = format_existing_memories(existing_memories)

      # 3. Build reflection prompt and call LLM
      prompt = build_reflection_prompt(conversation_text, memories_text)

      case Nous.LLM.generate_text(reflection_model, prompt,
             system: reflection_system_prompt(),
             max_tokens: max_tokens,
             temperature: 0.0
           ) do
        {:ok, response_text} ->
          apply_reflection_operations(ctx, config, response_text)

        {:error, reason} ->
          Logger.warning("Memory auto-update reflection failed: #{inspect(reason)}")
          ctx
      end
    else
      ctx
    end
  end

  defp format_conversation(messages, max_messages) do
    messages
    |> Enum.reject(fn msg -> msg.role == :system end)
    |> Enum.take(-max_messages)
    |> Enum.map(fn msg ->
      role = msg.role |> to_string() |> String.capitalize()
      content = if is_binary(msg.content), do: msg.content, else: inspect(msg.content)
      "#{role}: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp format_existing_memories([]), do: "No existing memories."

  defp format_existing_memories(entries) do
    entries
    |> Enum.map(fn entry ->
      "[#{entry.id}] (#{entry.type}, importance: #{entry.importance}) #{entry.content}"
    end)
    |> Enum.join("\n")
  end

  defp build_memory_scope(config) do
    case config[:default_search_scope] do
      :global -> :global
      :session -> scope_from_config(config, [:agent_id, :session_id, :user_id])
      :user -> scope_from_config(config, [:user_id])
      _ -> scope_from_config(config, [:agent_id, :user_id])
    end
  end

  defp reflection_system_prompt do
    """
    You are a memory management assistant. Analyze the conversation and existing memories, \
    then output a JSON array of memory operations. Each operation is an object with these fields:

    - "action": one of "remember", "update", or "forget"
    - "content": the memory content (required for "remember" and "update")
    - "type": one of "semantic", "episodic", "procedural" (default: "semantic")
    - "importance": a float 0.0–1.0 (default: 0.5)
    - "id": the memory ID (required for "update" and "forget")

    Rules:
    - Only output the JSON array, nothing else. No markdown fences.
    - "remember" creates a new memory.
    - "update" modifies an existing memory's content (provide the id).
    - "forget" deletes an outdated or incorrect memory (provide the id).
    - Be selective. Only store information worth remembering long-term.
    - Prefer updating existing memories over creating duplicates.
    - If there is nothing worth remembering, output an empty array: []
    """
  end

  defp build_reflection_prompt(conversation_text, memories_text) do
    """
    ## Recent Conversation
    #{conversation_text}

    ## Existing Memories
    #{memories_text}

    Based on the conversation above, what memory operations should be performed? \
    Output a JSON array of operations.
    """
  end

  @doc false
  def apply_reflection_operations(ctx, config, response_text) do
    case parse_reflection_json(response_text) do
      {:ok, operations} when is_list(operations) ->
        Enum.reduce(operations, ctx, fn op, acc_ctx ->
          apply_single_operation(acc_ctx, config, op)
        end)

      _ ->
        Logger.warning("Memory auto-update: failed to parse reflection response")
        ctx
    end
  end

  defp parse_reflection_json(text) do
    # Strip potential markdown fences
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()

    case JSON.decode(cleaned) do
      {:ok, parsed} when is_list(parsed) -> {:ok, parsed}
      {:ok, _} -> {:error, :not_an_array}
      {:error, _} = err -> err
    end
  end

  defp apply_single_operation(ctx, config, %{"action" => "remember"} = op) do
    store_mod = config[:store]
    store_state = (ctx.deps[:memory_config] || config)[:store_state]
    content = op["content"]

    unless content do
      ctx
    else
      embedding = maybe_embed(config, content)

      entry =
        Entry.new(%{
          content: content,
          type: parse_memory_type(op["type"]),
          importance: op["importance"] || 0.5,
          embedding: embedding,
          agent_id: config[:agent_id],
          session_id: config[:session_id],
          user_id: config[:user_id],
          namespace: config[:namespace]
        })

      case store_mod.store(store_state, entry) do
        {:ok, new_state} ->
          Logger.debug("Memory auto-update: remembered #{entry.id} — #{content}")
          updated_config = Map.put(ctx.deps[:memory_config] || config, :store_state, new_state)
          %{ctx | deps: Map.put(ctx.deps, :memory_config, updated_config)}

        {:error, reason} ->
          Logger.warning("Memory auto-update: store failed: #{inspect(reason)}")
          ctx
      end
    end
  end

  defp apply_single_operation(ctx, config, %{"action" => "update", "id" => id} = op)
       when is_binary(id) do
    store_mod = config[:store]
    store_state = (ctx.deps[:memory_config] || config)[:store_state]
    content = op["content"]

    updates =
      %{}
      |> then(fn m -> if content, do: Map.put(m, :content, content), else: m end)
      |> then(fn m ->
        if op["importance"], do: Map.put(m, :importance, op["importance"]), else: m
      end)
      |> then(fn m ->
        if op["type"], do: Map.put(m, :type, parse_memory_type(op["type"])), else: m
      end)

    # Re-embed if content changed
    updates =
      if content do
        case maybe_embed(config, content) do
          nil -> updates
          emb -> Map.put(updates, :embedding, emb)
        end
      else
        updates
      end

    case store_mod.update(store_state, id, updates) do
      {:ok, new_state} ->
        Logger.debug("Memory auto-update: updated #{id}")
        updated_config = Map.put(ctx.deps[:memory_config] || config, :store_state, new_state)
        %{ctx | deps: Map.put(ctx.deps, :memory_config, updated_config)}

      {:error, reason} ->
        Logger.warning("Memory auto-update: update failed for #{id}: #{inspect(reason)}")
        ctx
    end
  end

  defp apply_single_operation(ctx, config, %{"action" => "forget", "id" => id})
       when is_binary(id) do
    store_mod = config[:store]
    store_state = (ctx.deps[:memory_config] || config)[:store_state]

    case store_mod.delete(store_state, id) do
      {:ok, new_state} ->
        Logger.debug("Memory auto-update: forgot #{id}")
        updated_config = Map.put(ctx.deps[:memory_config] || config, :store_state, new_state)
        %{ctx | deps: Map.put(ctx.deps, :memory_config, updated_config)}

      {:error, reason} ->
        Logger.warning("Memory auto-update: forget failed for #{id}: #{inspect(reason)}")
        ctx
    end
  end

  defp apply_single_operation(ctx, _config, op) do
    Logger.warning("Memory auto-update: unrecognized operation: #{inspect(op)}")
    ctx
  end

  defp maybe_embed(config, content) do
    embedding_provider = config[:embedding]
    embedding_opts = config[:embedding_opts] || []

    if embedding_provider do
      case Embedding.embed(embedding_provider, content, embedding_opts) do
        {:ok, emb} -> emb
        {:error, _} -> nil
      end
    end
  end

  defp parse_memory_type("semantic"), do: :semantic
  defp parse_memory_type("episodic"), do: :episodic
  defp parse_memory_type("procedural"), do: :procedural
  defp parse_memory_type(_), do: :semantic

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

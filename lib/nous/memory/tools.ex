defmodule Nous.Memory.Tools do
  @moduledoc """
  Agent tools for memory operations: remember, recall, forget.

  Follows the `Nous.Tools.ResearchNotes` pattern — each tool receives `ctx`
  via `takes_ctx: true` and returns `{:ok, result, ContextUpdate.new()}`.
  """

  alias Nous.Memory.{Embedding, Entry, Scope, Search}
  alias Nous.RunContext
  alias Nous.Tool
  alias Nous.Tool.ContextUpdate

  @typedoc """
  Every tool here answers `{:ok, result, context_update}`.

  Failures are reported as `%{status: "error", message: ...}` inside the result
  rather than as an error tuple: the agent should see a message it can act on,
  not a tool call that blew up.
  """
  @type tool_result :: {:ok, map(), ContextUpdate.t()}

  @doc """
  Returns all memory tools as a list.
  """
  @spec all_tools() :: [Tool.t()]
  def all_tools do
    [remember_tool(), recall_tool(), forget_tool()]
  end

  # ---------------------------------------------------------------------------
  # Tool definitions
  # ---------------------------------------------------------------------------

  defp remember_tool do
    %Tool{
      name: "remember",
      description:
        "Store a memory for later recall. Use this to remember important facts, user preferences, decisions, or any information that should persist across conversations.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The information to remember"
          },
          "type" => %{
            "type" => "string",
            "enum" => ["semantic", "episodic", "procedural"],
            "description" =>
              "Memory type: semantic (facts/knowledge), episodic (events/experiences), procedural (how-to/processes). Default: semantic"
          },
          "importance" => %{
            "type" => "number",
            "description" => "Importance score 0.0-1.0 (default: 0.5)"
          },
          "evergreen" => %{
            "type" => "boolean",
            "description" => "If true, this memory is exempt from temporal decay (default: false)"
          },
          "metadata" => %{
            "type" => "object",
            "description" => "Arbitrary tags/metadata to attach to this memory"
          }
        },
        "required" => ["content"]
      },
      function: &__MODULE__.remember/2,
      takes_ctx: true
    }
  end

  defp recall_tool do
    %Tool{
      name: "recall",
      description:
        "Search memories for relevant information. Use this to retrieve previously stored facts, preferences, or context.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "What to search for in memory"
          },
          "type" => %{
            "type" => "string",
            "enum" => ["semantic", "episodic", "procedural"],
            "description" => "Filter by memory type (optional)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of memories to return (default: 5)"
          }
        },
        "required" => ["query"]
      },
      function: &__MODULE__.recall/2,
      takes_ctx: true
    }
  end

  defp forget_tool do
    %Tool{
      name: "forget",
      description: "Delete a specific memory by its ID.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "The ID of the memory to forget"
          }
        },
        "required" => ["id"]
      },
      function: &__MODULE__.forget/2,
      takes_ctx: true
    }
  end

  # ---------------------------------------------------------------------------
  # Tool implementations
  # ---------------------------------------------------------------------------

  @spec remember(RunContext.t(), map()) :: tool_result()
  def remember(ctx, args) do
    case memory_store(ctx) do
      {:ok, config, store_mod, store_state} ->
        do_remember(config, store_mod, store_state, args)

      :error ->
        {:ok, %{status: "error", message: "Memory system not initialized"}, ContextUpdate.new()}
    end
  end

  @spec recall(RunContext.t(), map()) :: tool_result()
  def recall(ctx, args) do
    case memory_store(ctx) do
      {:ok, config, store_mod, store_state} ->
        do_recall(config, store_mod, store_state, args)

      :error ->
        {:ok, %{status: "error", message: "Memory system not initialized", memories: []},
         ContextUpdate.new()}
    end
  end

  @spec forget(RunContext.t(), map()) :: tool_result()
  def forget(ctx, args) do
    case memory_store(ctx) do
      {:ok, config, store_mod, store_state} ->
        do_forget(config, store_mod, store_state, args)

      :error ->
        {:ok, %{status: "error", message: "Memory system not initialized"}, ContextUpdate.new()}
    end
  end

  defp do_remember(config, store_mod, store_state, args) do
    entry = build_entry(config, args)

    case store_mod.store(store_state, entry) do
      {:ok, new_state} ->
        {:ok,
         %{
           status: "remembered",
           id: entry.id,
           content: entry.content,
           type: to_string(entry.type),
           importance: entry.importance
         }, store_state_update(config, new_state)}

      {:error, reason} ->
        {:ok, %{status: "error", message: "Failed to store memory: #{inspect(reason)}"},
         ContextUpdate.new()}
    end
  end

  defp do_recall(config, store_mod, store_state, args) do
    query = Map.fetch!(args, "query")

    search_opts = [
      scope: build_search_scope(config),
      limit: Map.get(args, "limit", 5),
      type: parse_type_opt(Map.get(args, "type")),
      scoring_weights: config[:scoring_weights] || [],
      decay_lambda: config[:decay_lambda] || 0.001,
      embedding_opts: config[:embedding_opts] || []
    ]

    case Search.search(store_mod, store_state, query, config[:embedding], search_opts) do
      {:ok, results} ->
        new_state = touch_recalled(store_mod, store_state, results)
        memories = Enum.map(results, &format_memory/1)

        {:ok, %{status: "found", count: length(memories), memories: memories},
         store_state_update(config, new_state)}

      {:error, reason} ->
        {:ok, %{status: "error", message: "Memory search failed: #{inspect(reason)}"},
         ContextUpdate.new()}
    end
  end

  defp do_forget(config, store_mod, store_state, args) do
    id = Map.fetch!(args, "id")

    case store_mod.delete(store_state, id) do
      {:ok, new_state} ->
        {:ok, %{status: "forgotten", id: id}, store_state_update(config, new_state)}

      {:error, reason} ->
        {:ok, %{status: "error", message: "Failed to forget: #{inspect(reason)}"},
         ContextUpdate.new()}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # All three tools share one precondition: a store module and its state on
  # `ctx.deps[:memory_config]`. Reported as `:error` rather than raised so an
  # agent whose memory plugin never initialized gets a message back instead of a
  # crashed tool call.
  defp memory_store(ctx) do
    config = ctx.deps[:memory_config] || %{}
    store_mod = config[:store_mod] || config[:store]
    store_state = config[:store_state]

    if store_mod && store_state do
      {:ok, config, store_mod, store_state}
    else
      :error
    end
  end

  # Stores are value-passing: every write hands back a new state that has to
  # reach the next tool call via the run context.
  defp store_state_update(config, store_state) do
    ContextUpdate.new()
    |> ContextUpdate.set(:memory_config, Map.put(config, :store_state, store_state))
  end

  defp build_entry(config, args) do
    content = Map.fetch!(args, "content")

    Entry.new(%{
      content: content,
      type: parse_type(Map.get(args, "type", "semantic")),
      importance: Map.get(args, "importance", 0.5),
      evergreen: Map.get(args, "evergreen", false),
      embedding: maybe_embed(config[:embedding], content, config[:embedding_opts] || []),
      metadata: Map.get(args, "metadata", %{}),
      agent_id: config[:agent_id],
      session_id: config[:session_id],
      user_id: config[:user_id],
      namespace: config[:namespace]
    })
  end

  # No provider configured, or the provider failed: store the entry without a
  # vector and let recall fall back to text-only search.
  defp maybe_embed(nil, _content, _opts), do: nil

  defp maybe_embed(provider, content, opts) do
    case Embedding.embed(provider, content, opts) do
      {:ok, embedding} -> embedding
      {:error, _reason} -> nil
    end
  end

  # Bump access_count/last_accessed_at for everything recalled. A failed update
  # is dropped rather than failing the recall: the caller already has the
  # results, and access stats are advisory.
  defp touch_recalled(store_mod, store_state, results) do
    Enum.reduce(results, store_state, fn {entry, _score}, state ->
      updates = %{access_count: entry.access_count + 1, last_accessed_at: DateTime.utc_now()}

      case store_mod.update(state, entry.id, updates) do
        {:ok, new_state} -> new_state
        {:error, _reason} -> state
      end
    end)
  end

  defp format_memory({entry, score}) do
    %{
      id: entry.id,
      content: entry.content,
      type: to_string(entry.type),
      importance: entry.importance,
      score: Float.round(score, 4),
      created_at: DateTime.to_iso8601(entry.created_at),
      metadata: entry.metadata
    }
  end

  defp parse_type("semantic"), do: :semantic
  defp parse_type("episodic"), do: :episodic
  defp parse_type("procedural"), do: :procedural
  defp parse_type(_), do: :semantic

  defp parse_type_opt(nil), do: nil
  defp parse_type_opt(type), do: parse_type(type)

  defp build_search_scope(config), do: Scope.build(config)
end

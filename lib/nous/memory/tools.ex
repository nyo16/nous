defmodule Nous.Memory.Tools do
  @moduledoc """
  Agent tools for memory operations: remember, recall, forget.

  Follows the `Nous.Tools.ResearchNotes` pattern — each tool receives `ctx`
  via `takes_ctx: true` and returns `{:ok, result, ContextUpdate.new()}`.
  """

  alias Nous.Memory.{Embedding, Entry, Search}
  alias Nous.Tool
  alias Nous.Tool.ContextUpdate

  @doc """
  Returns all memory tools as a list.
  """
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

  def remember(ctx, args) do
    config = ctx.deps[:memory_config] || %{}
    store_mod = config[:store_mod] || config[:store]
    store_state = config[:store_state]

    unless store_mod && store_state do
      {:ok, %{status: "error", message: "Memory system not initialized"}, ContextUpdate.new()}
    else
      content = Map.fetch!(args, "content")
      type = parse_type(Map.get(args, "type", "semantic"))
      importance = Map.get(args, "importance", 0.5)
      evergreen = Map.get(args, "evergreen", false)
      metadata = Map.get(args, "metadata", %{})

      # Generate embedding if provider configured
      embedding_provider = config[:embedding]
      embedding_opts = config[:embedding_opts] || []

      embedding =
        if embedding_provider do
          case Embedding.embed(embedding_provider, content, embedding_opts) do
            {:ok, emb} -> emb
            {:error, _} -> nil
          end
        end

      entry =
        Entry.new(%{
          content: content,
          type: type,
          importance: importance,
          evergreen: evergreen,
          embedding: embedding,
          metadata: metadata,
          agent_id: config[:agent_id],
          session_id: config[:session_id],
          user_id: config[:user_id],
          namespace: config[:namespace]
        })

      case store_mod.store(store_state, entry) do
        {:ok, new_state} ->
          updated_config = Map.put(config, :store_state, new_state)

          {:ok,
           %{
             status: "remembered",
             id: entry.id,
             content: content,
             type: to_string(type),
             importance: importance
           }, ContextUpdate.new() |> ContextUpdate.set(:memory_config, updated_config)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Failed to store memory: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    end
  end

  def recall(ctx, args) do
    config = ctx.deps[:memory_config] || %{}
    store_mod = config[:store_mod] || config[:store]
    store_state = config[:store_state]

    unless store_mod && store_state do
      {:ok, %{status: "error", message: "Memory system not initialized", memories: []},
       ContextUpdate.new()}
    else
      query = Map.fetch!(args, "query")
      type = parse_type_opt(Map.get(args, "type"))
      limit = Map.get(args, "limit", 5)

      embedding_provider = config[:embedding]
      embedding_opts = config[:embedding_opts] || []
      scope = build_search_scope(config)
      scoring_weights = config[:scoring_weights] || []
      decay_lambda = config[:decay_lambda] || 0.001

      search_opts = [
        scope: scope,
        limit: limit,
        type: type,
        scoring_weights: scoring_weights,
        decay_lambda: decay_lambda,
        embedding_opts: embedding_opts
      ]

      case Search.search(store_mod, store_state, query, embedding_provider, search_opts) do
        {:ok, results} ->
          # Update access count for returned entries
          store_state =
            Enum.reduce(results, store_state, fn {entry, _score}, state ->
              case store_mod.update(state, entry.id, %{
                     access_count: entry.access_count + 1,
                     last_accessed_at: DateTime.utc_now()
                   }) do
                {:ok, new_state} -> new_state
                {:error, _} -> state
              end
            end)

          updated_config = Map.put(config, :store_state, store_state)

          formatted =
            Enum.map(results, fn {entry, score} ->
              %{
                id: entry.id,
                content: entry.content,
                type: to_string(entry.type),
                importance: entry.importance,
                score: Float.round(score, 4),
                created_at: DateTime.to_iso8601(entry.created_at),
                metadata: entry.metadata
              }
            end)

          {:ok, %{status: "found", count: length(formatted), memories: formatted},
           ContextUpdate.new() |> ContextUpdate.set(:memory_config, updated_config)}
      end
    end
  end

  def forget(ctx, args) do
    config = ctx.deps[:memory_config] || %{}
    store_mod = config[:store_mod] || config[:store]
    store_state = config[:store_state]

    unless store_mod && store_state do
      {:ok, %{status: "error", message: "Memory system not initialized"}, ContextUpdate.new()}
    else
      id = Map.fetch!(args, "id")

      case store_mod.delete(store_state, id) do
        {:ok, new_state} ->
          updated_config = Map.put(config, :store_state, new_state)

          {:ok, %{status: "forgotten", id: id},
           ContextUpdate.new() |> ContextUpdate.set(:memory_config, updated_config)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Failed to forget: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_type("semantic"), do: :semantic
  defp parse_type("episodic"), do: :episodic
  defp parse_type("procedural"), do: :procedural
  defp parse_type(_), do: :semantic

  defp parse_type_opt(nil), do: nil
  defp parse_type_opt(type), do: parse_type(type)

  defp build_search_scope(config) do
    case config[:default_search_scope] do
      :global ->
        :global

      :session ->
        scope_from_fields(config, [:agent_id, :session_id, :user_id])

      :user ->
        scope_from_fields(config, [:user_id])

      # :agent or default
      _ ->
        scope_from_fields(config, [:agent_id, :user_id])
    end
  end

  defp scope_from_fields(config, fields) do
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

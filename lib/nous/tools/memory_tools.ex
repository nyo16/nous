defmodule Nous.Tools.MemoryTools do
  @moduledoc """
  Built-in tools for agent memory management.

  MemoryTools allows AI agents to store and recall information, enabling
  both short-term (session-based) and long-term (persistent) memory.

  ## Setup

  ### Short-term Memory (Context-based)

  For simple use cases where memory only needs to persist within a session:

      agent = Nous.new("openai:gpt-4",
        instructions: "You have memory. Use it to remember important information.",
        tools: [
          &MemoryTools.store_memory/2,
          &MemoryTools.recall_memories/2,
          &MemoryTools.list_memories/2,
          &MemoryTools.forget_memory/2
        ]
      )

      {:ok, result} = Nous.run(agent, "Remember my name is Alice")

  Memories are stored in `ctx.deps[:memories]` and persist across turns
  within the same session.

  ### Long-term Memory (Persistent)

  For persistent memory across sessions, use a Memory Manager:

      {:ok, manager} = Nous.Memory.Manager.start_link(
        agent_id: "my_assistant",
        store: {Nous.Memory.Stores.RocksdbStore, path: "~/.nous/memory"}
      )

      {:ok, result} = Nous.run(agent, "Remember my name is Alice",
        deps: %{memory_manager: manager}
      )

  When a `memory_manager` is present in deps, tools use it for persistence.

  ## How It Works

  1. Tools check for `ctx.deps[:memory_manager]` (persistent store)
  2. Fall back to `ctx.deps[:memories]` (context-only storage)
  3. Return `__update_context__` to update context-based memories
  4. Memory Manager handles persistence automatically

  """

  alias Nous.Memory

  @doc """
  Store a memory for later recall.

  ## Arguments

  - content: The memory content (required) - can be "content", "text", or "memory"
  - tags: List of tags for categorization (optional, default: [])
  - importance: Priority level - "low", "medium", "high", "critical" (default: "medium")
  - metadata: Additional key-value data (optional)

  ## Returns

  - success: true/false
  - memory: The stored memory
  - message: Confirmation message
  - __update_context__: Context updates for short-term storage
  """
  def store_memory(ctx, args) do
    content =
      Map.get(args, "content") ||
        Map.get(args, "text") ||
        Map.get(args, "memory")

    tags = parse_tags(Map.get(args, "tags", []))
    importance = parse_importance(Map.get(args, "importance", "medium"))
    metadata = Map.get(args, "metadata", %{})

    if !content || content == "" do
      %{
        success: false,
        error: "Memory content is required"
      }
    else
      case ctx.deps[:memory_manager] do
        nil ->
          # Context-only storage
          store_in_context(ctx, content, tags, importance, metadata)

        manager ->
          # Persistent storage
          store_in_manager(manager, content, tags, importance, metadata)
      end
    end
  end

  @doc """
  Recall memories matching a query.

  ## Arguments

  - query: Search query (required) - can be "query", "search", or "text"
  - tags: Filter by tags (optional)
  - limit: Maximum number of results (default: 5)
  - importance: Filter by minimum importance level (optional)

  ## Returns

  - success: true/false
  - memories: List of matching memories
  - count: Number of results
  - message: Summary message
  """
  def recall_memories(ctx, args) do
    query =
      Map.get(args, "query") ||
        Map.get(args, "search") ||
        Map.get(args, "text") ||
        ""

    tags = parse_tags(Map.get(args, "tags"))
    limit = Map.get(args, "limit", 5)
    importance = parse_importance(Map.get(args, "importance"))

    case ctx.deps[:memory_manager] do
      nil ->
        # Search in context
        recall_from_context(ctx, query, tags, limit, importance)

      manager ->
        # Search via manager
        recall_from_manager(manager, query, tags, limit, importance)
    end
  end

  @doc """
  List all stored memories with optional filtering.

  ## Arguments

  - tags: Filter by tags (optional)
  - importance: Filter by minimum importance level (optional)
  - limit: Maximum number of results (optional)

  ## Returns

  - success: true/false
  - memories: List of memories
  - count: Total count
  - by_importance: Count by importance level
  """
  def list_memories(ctx, args) do
    tags = parse_tags(Map.get(args, "tags"))
    importance = parse_importance(Map.get(args, "importance"))
    limit = Map.get(args, "limit")

    case ctx.deps[:memory_manager] do
      nil ->
        list_from_context(ctx, tags, importance, limit)

      manager ->
        list_from_manager(manager, tags, importance, limit)
    end
  end

  @doc """
  Forget (delete) a specific memory by ID.

  ## Arguments

  - id: Memory ID (required)

  ## Returns

  - success: true/false
  - message: Confirmation or error message
  - __update_context__: Context updates for short-term storage
  """
  def forget_memory(ctx, args) do
    id = Map.get(args, "id")

    if !id do
      %{
        success: false,
        error: "Memory ID is required"
      }
    else
      case ctx.deps[:memory_manager] do
        nil ->
          forget_from_context(ctx, id)

        manager ->
          forget_from_manager(manager, id)
      end
    end
  end

  @doc """
  Clear all memories with optional filtering.

  ## Arguments

  - tags: Only clear memories with these tags (optional)
  - confirm: Must be true to actually clear (safety check)

  ## Returns

  - success: true/false
  - count: Number of memories cleared
  - message: Confirmation message
  - __update_context__: Context updates for short-term storage
  """
  def clear_memories(ctx, args) do
    confirm = Map.get(args, "confirm", false)
    tags = parse_tags(Map.get(args, "tags"))

    if confirm != true and confirm != "true" do
      %{
        success: false,
        error: "Set confirm: true to clear memories"
      }
    else
      case ctx.deps[:memory_manager] do
        nil ->
          clear_from_context(ctx, tags)

        manager ->
          clear_from_manager(manager, tags)
      end
    end
  end

  @doc """
  Returns all memory tools as a list for easy inclusion.

  ## Example

      agent = Nous.new("openai:gpt-4",
        tools: Nous.Tools.MemoryTools.all()
      )

  """
  def all do
    [
      &store_memory/2,
      &recall_memories/2,
      &list_memories/2,
      &forget_memory/2,
      &clear_memories/2
    ]
  end

  # Private: Context-based storage

  defp store_in_context(ctx, content, tags, importance, metadata) do
    memories = ctx.deps[:memories] || []

    memory = %{
      id: generate_id(),
      content: content,
      tags: tags,
      importance: importance,
      metadata: metadata,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      access_count: 0
    }

    updated_memories = [memory | memories]

    %{
      success: true,
      memory: memory,
      message: "Memory stored: #{truncate(content, 50)}",
      __update_context__: %{memories: updated_memories}
    }
  end

  defp recall_from_context(ctx, query, tags, limit, importance) do
    memories = ctx.deps[:memories] || []

    results =
      memories
      |> filter_by_tags(tags)
      |> filter_by_importance(importance)
      |> search_by_query(query)
      |> Enum.take(limit)
      |> Enum.map(&touch_memory/1)

    # Update access tracking
    updated_memories = update_accessed_memories(memories, results)

    %{
      success: true,
      memories: results,
      count: length(results),
      message:
        if(length(results) > 0,
          do: "Found #{length(results)} memories",
          else: "No memories found matching query"
        ),
      __update_context__: %{memories: updated_memories}
    }
  end

  defp list_from_context(ctx, tags, importance, limit) do
    memories = ctx.deps[:memories] || []

    filtered =
      memories
      |> filter_by_tags(tags)
      |> filter_by_importance(importance)
      |> then(fn m -> if limit, do: Enum.take(m, limit), else: m end)

    %{
      success: true,
      memories: filtered,
      count: length(filtered),
      by_importance: count_by_importance(memories)
    }
  end

  defp forget_from_context(ctx, id) do
    memories = ctx.deps[:memories] || []

    case Enum.find(memories, &(&1.id == id || to_string(&1.id) == to_string(id))) do
      nil ->
        %{
          success: false,
          error: "Memory not found with id: #{id}",
          available_ids: Enum.map(memories, & &1.id)
        }

      memory ->
        updated_memories = Enum.reject(memories, &(&1.id == memory.id))

        %{
          success: true,
          message: "Memory forgotten: #{truncate(memory.content, 50)}",
          __update_context__: %{memories: updated_memories}
        }
    end
  end

  defp clear_from_context(ctx, tags) do
    memories = ctx.deps[:memories] || []

    {to_clear, to_keep} =
      if tags && tags != [] do
        Enum.split_with(memories, fn m ->
          Enum.any?(tags, &(&1 in m.tags))
        end)
      else
        {memories, []}
      end

    %{
      success: true,
      count: length(to_clear),
      message: "Cleared #{length(to_clear)} memories",
      __update_context__: %{memories: to_keep}
    }
  end

  # Private: Manager-based storage

  defp store_in_manager(manager, content, tags, importance, metadata) do
    case Nous.Memory.Manager.store(manager, content,
           tags: tags,
           importance: importance,
           metadata: metadata
         ) do
      {:ok, memory} ->
        %{
          success: true,
          memory: Memory.to_map(memory),
          message: "Memory stored: #{truncate(content, 50)}"
        }

      {:error, reason} ->
        %{
          success: false,
          error: "Failed to store memory: #{inspect(reason)}"
        }
    end
  end

  defp recall_from_manager(manager, query, tags, limit, importance) do
    opts =
      [limit: limit]
      |> maybe_add(:tags, tags)
      |> maybe_add(:importance, importance)

    case Nous.Memory.Manager.recall(manager, query, opts) do
      {:ok, memories} ->
        %{
          success: true,
          memories: Enum.map(memories, &Memory.to_map/1),
          count: length(memories),
          message:
            if(length(memories) > 0,
              do: "Found #{length(memories)} memories",
              else: "No memories found matching query"
            )
        }

      {:error, reason} ->
        %{
          success: false,
          error: "Failed to recall memories: #{inspect(reason)}"
        }
    end
  end

  defp list_from_manager(manager, tags, importance, limit) do
    opts =
      []
      |> maybe_add(:tags, tags)
      |> maybe_add(:importance, importance)
      |> maybe_add(:limit, limit)

    case Nous.Memory.Manager.list(manager, opts) do
      {:ok, memories} ->
        %{
          success: true,
          memories: Enum.map(memories, &Memory.to_map/1),
          count: length(memories),
          by_importance: count_by_importance_structs(memories)
        }

      {:error, reason} ->
        %{
          success: false,
          error: "Failed to list memories: #{inspect(reason)}"
        }
    end
  end

  defp forget_from_manager(manager, id) do
    case Nous.Memory.Manager.forget(manager, id) do
      :ok ->
        %{
          success: true,
          message: "Memory forgotten"
        }

      {:error, reason} ->
        %{
          success: false,
          error: "Failed to forget memory: #{inspect(reason)}"
        }
    end
  end

  defp clear_from_manager(manager, tags) do
    opts = if tags && tags != [], do: [tags: tags], else: []

    case Nous.Memory.Manager.clear(manager, opts) do
      {:ok, count} ->
        %{
          success: true,
          count: count,
          message: "Cleared #{count} memories"
        }

      {:error, reason} ->
        %{
          success: false,
          error: "Failed to clear memories: #{inspect(reason)}"
        }
    end
  end

  # Private helper functions

  defp generate_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp parse_tags(nil), do: nil
  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(tags) when is_binary(tags), do: String.split(tags, ",", trim: true)

  defp parse_importance(nil), do: nil
  defp parse_importance("low"), do: :low
  defp parse_importance("medium"), do: :medium
  defp parse_importance("high"), do: :high
  defp parse_importance("critical"), do: :critical
  defp parse_importance(atom) when is_atom(atom), do: atom
  defp parse_importance(_), do: :medium

  defp filter_by_tags(memories, nil), do: memories
  defp filter_by_tags(memories, []), do: memories

  defp filter_by_tags(memories, tags) do
    Enum.filter(memories, fn memory ->
      memory_tags = memory.tags || memory[:tags] || []
      Enum.any?(tags, &(&1 in memory_tags))
    end)
  end

  defp filter_by_importance(memories, nil), do: memories

  defp filter_by_importance(memories, min_importance) do
    min_level = importance_level(min_importance)

    Enum.filter(memories, fn memory ->
      memory_importance = memory.importance || memory[:importance] || :medium
      importance_level(memory_importance) >= min_level
    end)
  end

  defp importance_level(:low), do: 1
  defp importance_level(:medium), do: 2
  defp importance_level(:high), do: 3
  defp importance_level(:critical), do: 4

  defp search_by_query(memories, ""), do: memories
  defp search_by_query(memories, nil), do: memories

  defp search_by_query(memories, query) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/\s+/, trim: true)

    memories
    |> Enum.map(fn memory ->
      content = memory.content || memory[:content] || ""
      content_lower = String.downcase(content)

      score =
        cond do
          String.contains?(content_lower, query_lower) -> 1.0
          Enum.any?(query_words, &String.contains?(content_lower, &1)) -> 0.5
          true -> 0.0
        end

      {memory, score}
    end)
    |> Enum.filter(fn {_memory, score} -> score > 0 end)
    |> Enum.sort_by(fn {_memory, score} -> score end, :desc)
    |> Enum.map(fn {memory, _score} -> memory end)
  end

  defp touch_memory(memory) when is_map(memory) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    access_count = (memory[:access_count] || memory.access_count || 0) + 1

    memory
    |> Map.put(:accessed_at, now)
    |> Map.put(:access_count, access_count)
  end

  defp update_accessed_memories(all_memories, accessed_memories) do
    accessed_ids = MapSet.new(Enum.map(accessed_memories, & &1.id))

    Enum.map(all_memories, fn memory ->
      if MapSet.member?(accessed_ids, memory.id) do
        Enum.find(accessed_memories, &(&1.id == memory.id))
      else
        memory
      end
    end)
  end

  defp count_by_importance(memories) do
    %{
      low: Enum.count(memories, &((&1.importance || &1[:importance]) == :low)),
      medium: Enum.count(memories, &((&1.importance || &1[:importance]) == :medium)),
      high: Enum.count(memories, &((&1.importance || &1[:importance]) == :high)),
      critical: Enum.count(memories, &((&1.importance || &1[:importance]) == :critical))
    }
  end

  defp count_by_importance_structs(memories) do
    %{
      low: Enum.count(memories, &(&1.importance == :low)),
      medium: Enum.count(memories, &(&1.importance == :medium)),
      high: Enum.count(memories, &(&1.importance == :high)),
      critical: Enum.count(memories, &(&1.importance == :critical))
    }
  end

  defp truncate(string, max_length) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length) <> "..."
    else
      string
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, []), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end

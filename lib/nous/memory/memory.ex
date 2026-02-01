defmodule Nous.Memory do
  @moduledoc """
  Memory struct representing a stored memory in the agent's memory system.

  Memories have tiers that represent their lifecycle:
  - `:working` - Active in current session, not yet persisted
  - `:short_term` - Recently accessed, persisted but may decay
  - `:long_term` - Consolidated important memories
  - `:archived` - Low-relevance memories kept for reference

  ## Fields

  - `id` - Unique identifier
  - `content` - The actual memory content (text)
  - `tags` - List of tags for categorization
  - `metadata` - Arbitrary key-value data
  - `importance` - Priority level (`:low`, `:medium`, `:high`, `:critical`)
  - `source` - Origin of memory (`:conversation`, `:user`, `:system`)
  - `tier` - Memory tier (`:working`, `:short_term`, `:long_term`, `:archived`)
  - `created_at` - When the memory was created
  - `accessed_at` - When the memory was last accessed
  - `access_count` - Number of times the memory has been recalled
  - `decay_score` - Current relevance score (0.0 - 1.0)
  - `consolidated_at` - When promoted to long-term (nil if not consolidated)
  - `summary` - Compressed version for archived memories
  - `embedding` - Vector embedding for semantic search (nil if not computed)

  ## Example

      memory = Nous.Memory.new("User prefers dark mode",
        tags: ["preference", "ui"],
        importance: :medium
      )

  """

  @type importance :: :low | :medium | :high | :critical
  @type source :: :conversation | :user | :system
  @type tier :: :working | :short_term | :long_term | :archived

  @type t :: %__MODULE__{
          id: term(),
          content: String.t(),
          tags: [String.t()],
          metadata: map(),
          importance: importance(),
          source: source(),
          tier: tier(),
          created_at: DateTime.t(),
          accessed_at: DateTime.t(),
          access_count: non_neg_integer(),
          decay_score: float(),
          consolidated_at: DateTime.t() | nil,
          summary: String.t() | nil,
          embedding: [float()] | nil
        }

  @enforce_keys [:id, :content]
  defstruct [
    :id,
    :content,
    :consolidated_at,
    :summary,
    :embedding,
    tags: [],
    metadata: %{},
    importance: :medium,
    source: :conversation,
    tier: :working,
    created_at: nil,
    accessed_at: nil,
    access_count: 0,
    decay_score: 1.0
  ]

  @doc """
  Create a new memory with the given content and options.

  ## Options

  - `:id` - Custom ID (auto-generated if not provided)
  - `:tags` - List of tags (default: [])
  - `:metadata` - Arbitrary metadata map (default: %{})
  - `:importance` - `:low`, `:medium`, `:high`, or `:critical` (default: `:medium`)
  - `:source` - `:conversation`, `:user`, or `:system` (default: `:conversation`)
  - `:tier` - `:working`, `:short_term`, `:long_term`, or `:archived` (default: `:working`)

  ## Example

      memory = Nous.Memory.new("Important fact",
        tags: ["fact", "important"],
        importance: :high,
        metadata: %{context: "user stated directly"}
      )

  """
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      content: content,
      tags: Keyword.get(opts, :tags, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      importance: Keyword.get(opts, :importance, :medium),
      source: Keyword.get(opts, :source, :conversation),
      tier: Keyword.get(opts, :tier, :working),
      created_at: now,
      accessed_at: now,
      access_count: 0,
      decay_score: 1.0
    }
  end

  @doc """
  Mark a memory as accessed, updating `accessed_at` and incrementing `access_count`.

  This also boosts the decay score based on the importance level.
  """
  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = memory) do
    boost = importance_boost(memory.importance)

    %{
      memory
      | accessed_at: DateTime.utc_now(),
        access_count: memory.access_count + 1,
        decay_score: min(1.0, memory.decay_score + boost)
    }
  end

  @doc """
  Update memory fields with the given map of changes.

  Returns an updated memory with the `accessed_at` timestamp refreshed.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = memory, changes) when is_map(changes) do
    memory
    |> Map.merge(changes)
    |> Map.put(:accessed_at, DateTime.utc_now())
  end

  @doc """
  Check if a memory matches the given tag filter.

  Returns true if the memory has any of the specified tags,
  or if the tag filter is empty/nil.
  """
  @spec matches_tags?(t(), [String.t()] | nil) :: boolean()
  def matches_tags?(%__MODULE__{}, nil), do: true
  def matches_tags?(%__MODULE__{}, []), do: true

  def matches_tags?(%__MODULE__{tags: memory_tags}, filter_tags) do
    Enum.any?(filter_tags, &(&1 in memory_tags))
  end

  @doc """
  Check if a memory matches the given importance level filter.

  Returns true if the memory's importance is at or above the specified level,
  or if the filter is nil.
  """
  @spec matches_importance?(t(), importance() | nil) :: boolean()
  def matches_importance?(%__MODULE__{}, nil), do: true

  def matches_importance?(%__MODULE__{importance: memory_importance}, min_importance) do
    importance_level(memory_importance) >= importance_level(min_importance)
  end

  @doc """
  Convert a memory to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = memory) do
    %{
      id: memory.id,
      content: memory.content,
      tags: memory.tags,
      metadata: memory.metadata,
      importance: memory.importance,
      source: memory.source,
      tier: memory.tier,
      created_at: DateTime.to_iso8601(memory.created_at),
      accessed_at: DateTime.to_iso8601(memory.accessed_at),
      access_count: memory.access_count,
      decay_score: memory.decay_score,
      consolidated_at:
        if(memory.consolidated_at, do: DateTime.to_iso8601(memory.consolidated_at)),
      summary: memory.summary
    }
  end

  @doc """
  Create a memory from a map (e.g., loaded from storage).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map[:id] || map["id"],
      content: map[:content] || map["content"],
      tags: map[:tags] || map["tags"] || [],
      metadata: map[:metadata] || map["metadata"] || %{},
      importance: parse_atom(map[:importance] || map["importance"], :medium),
      source: parse_atom(map[:source] || map["source"], :conversation),
      tier: parse_atom(map[:tier] || map["tier"], :working),
      created_at: parse_datetime(map[:created_at] || map["created_at"]),
      accessed_at: parse_datetime(map[:accessed_at] || map["accessed_at"]),
      access_count: map[:access_count] || map["access_count"] || 0,
      decay_score: map[:decay_score] || map["decay_score"] || 1.0,
      consolidated_at: parse_datetime(map[:consolidated_at] || map["consolidated_at"]),
      summary: map[:summary] || map["summary"],
      embedding: map[:embedding] || map["embedding"]
    }
  end

  # Private functions

  defp generate_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp importance_level(:low), do: 1
  defp importance_level(:medium), do: 2
  defp importance_level(:high), do: 3
  defp importance_level(:critical), do: 4

  defp importance_boost(:low), do: 0.05
  defp importance_boost(:medium), do: 0.1
  defp importance_boost(:high), do: 0.15
  defp importance_boost(:critical), do: 0.2

  defp parse_atom(nil, default), do: default
  defp parse_atom(value, _default) when is_atom(value), do: value
  defp parse_atom(value, _default) when is_binary(value), do: String.to_existing_atom(value)

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end
end

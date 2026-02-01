defmodule Nous.Memory.Search.Simple do
  @moduledoc """
  Simple text-matching search backend for the memory system.

  This search backend provides basic search functionality:
  - Substring matching (case-insensitive)
  - Tag filtering
  - Importance filtering
  - Relevance scoring based on match position and frequency

  ## Usage

      {:ok, search} = Simple.start_link()

      # Index a memory
      memory = Nous.Memory.new("User prefers dark mode", tags: ["preference"])
      :ok = Simple.index(search, memory)

      # Search
      {:ok, results} = Simple.search(search, "dark mode", limit: 5)
      # Returns [%{memory: %Memory{}, score: 0.85, highlights: [...]}]

  ## Scoring

  The relevance score (0.0 - 1.0) is calculated based on:
  - Whether the query appears in the content (higher weight)
  - The position of the match (earlier = higher score)
  - Importance level boost

  ## Note

  For more advanced search capabilities (full-text, semantic, hybrid),
  consider using `TantivySearch`, `VectorSearch`, or `HybridSearch`.

  """

  @behaviour Nous.Memory.Search

  use GenServer

  alias Nous.Memory

  # Client API

  @impl Nous.Memory.Search
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Nous.Memory.Search
  def index(search, %Memory{} = memory) do
    GenServer.call(search, {:index, memory})
  end

  @impl Nous.Memory.Search
  def search(search, query, opts \\ []) do
    GenServer.call(search, {:search, query, opts})
  end

  @impl Nous.Memory.Search
  def delete(search, id) do
    GenServer.call(search, {:delete, id})
  end

  @impl Nous.Memory.Search
  def update(search, %Memory{} = memory) do
    GenServer.call(search, {:update, memory})
  end

  @impl Nous.Memory.Search
  def clear(search) do
    GenServer.call(search, :clear)
  end

  @impl Nous.Memory.Search
  def supports?(_search, feature) do
    feature in [:text_matching]
  end

  # Server Callbacks

  @impl GenServer
  def init(_opts) do
    # Store memories in a map for fast lookup
    {:ok, %{memories: %{}}}
  end

  @impl GenServer
  def handle_call({:index, memory}, _from, state) do
    memories = Map.put(state.memories, memory.id, memory)
    {:reply, :ok, %{state | memories: memories}}
  end

  def handle_call({:search, query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    tags = Keyword.get(opts, :tags)
    importance = Keyword.get(opts, :importance)
    include_highlights = Keyword.get(opts, :include_highlights, false)

    results =
      state.memories
      |> Map.values()
      |> filter_by_tags(tags)
      |> filter_by_importance(importance)
      |> score_and_rank(query, include_highlights)
      |> Enum.take(limit)

    {:reply, {:ok, results}, state}
  end

  def handle_call({:delete, id}, _from, state) do
    memories = Map.delete(state.memories, id)
    {:reply, :ok, %{state | memories: memories}}
  end

  def handle_call({:update, memory}, _from, state) do
    memories = Map.put(state.memories, memory.id, memory)
    {:reply, :ok, %{state | memories: memories}}
  end

  def handle_call(:clear, _from, state) do
    count = map_size(state.memories)
    {:reply, {:ok, count}, %{state | memories: %{}}}
  end

  # Private functions

  defp filter_by_tags(memories, nil), do: memories
  defp filter_by_tags(memories, []), do: memories

  defp filter_by_tags(memories, tags) do
    Enum.filter(memories, fn memory ->
      Enum.any?(tags, &(&1 in memory.tags))
    end)
  end

  defp filter_by_importance(memories, nil), do: memories

  defp filter_by_importance(memories, min_importance) do
    Enum.filter(memories, fn memory ->
      Memory.matches_importance?(memory, min_importance)
    end)
  end

  defp score_and_rank(memories, query, include_highlights) do
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/\s+/, trim: true)

    # Empty query returns all memories with equal score
    if query_lower == "" do
      Enum.map(memories, fn memory ->
        build_result(memory, 1.0, [], include_highlights)
      end)
    else
      memories
      |> Enum.map(fn memory ->
        {score, highlights} = calculate_score(memory, query_lower, query_words)
        build_result(memory, score, highlights, include_highlights)
      end)
      |> Enum.filter(fn result -> result.score > 0 end)
      |> Enum.sort_by(& &1.score, :desc)
    end
  end

  defp calculate_score(memory, query_lower, query_words) do
    content_lower = String.downcase(memory.content)

    # Full query match score
    full_match_score =
      if query_lower != "" and String.contains?(content_lower, query_lower) do
        # Higher score for earlier matches
        position = :binary.match(content_lower, query_lower)

        case position do
          {start, _len} -> 0.5 * (1 - start / max(String.length(content_lower), 1))
          :nomatch -> 0
        end
      else
        0
      end

    # Individual word matches
    word_scores =
      Enum.map(query_words, fn word ->
        if String.contains?(content_lower, word), do: 0.3 / length(query_words), else: 0
      end)

    word_match_score = Enum.sum(word_scores)

    # Tag match bonus
    tag_score =
      if Enum.any?(memory.tags, fn tag ->
           tag_lower = String.downcase(tag)
           String.contains?(tag_lower, query_lower) or String.contains?(query_lower, tag_lower)
         end) do
        0.1
      else
        0
      end

    # Importance boost
    importance_boost = importance_multiplier(memory.importance)

    # Calculate total score
    base_score = full_match_score + word_match_score + tag_score
    final_score = min(1.0, base_score * importance_boost)

    # Generate highlights
    highlights =
      if final_score > 0 do
        generate_highlights(memory.content, query_words)
      else
        []
      end

    {final_score, highlights}
  end

  defp build_result(memory, score, highlights, include_highlights) do
    result = %{
      memory: memory,
      score: Float.round(score, 3)
    }

    if include_highlights do
      Map.put(result, :highlights, highlights)
    else
      Map.put(result, :highlights, nil)
    end
  end

  defp importance_multiplier(:low), do: 0.9
  defp importance_multiplier(:medium), do: 1.0
  defp importance_multiplier(:high), do: 1.1
  defp importance_multiplier(:critical), do: 1.2

  defp generate_highlights(content, query_words) do
    # Find positions of query words and extract surrounding context
    content_lower = String.downcase(content)

    query_words
    |> Enum.flat_map(fn word ->
      case :binary.match(content_lower, word) do
        {start, len} ->
          # Extract context around the match
          context_start = max(0, start - 20)
          context_end = min(String.length(content), start + len + 20)
          snippet = String.slice(content, context_start, context_end - context_start)

          prefix = if context_start > 0, do: "...", else: ""
          suffix = if context_end < String.length(content), do: "...", else: ""

          [prefix <> snippet <> suffix]

        :nomatch ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(3)
  end
end

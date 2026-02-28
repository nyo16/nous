defmodule Nous.Memory.Search do
  @moduledoc """
  Hybrid search orchestrator for the memory system.

  Runs text and vector searches in parallel, merges results via Reciprocal Rank
  Fusion, applies temporal decay and composite scoring, and returns the top N
  results.

  When no embedding provider is configured, falls back to text-only search.
  """

  alias Nous.Memory.{Embedding, Entry, Scoring}

  @type search_opts :: [
          scope: map() | :global,
          limit: pos_integer(),
          min_score: float(),
          type: Entry.memory_type() | nil,
          scoring_weights: keyword(),
          decay_lambda: float(),
          now: DateTime.t()
        ]

  @doc """
  Search memories using hybrid text + vector retrieval.

  ## Options

    * `:scope` - Map of scoping fields to filter by, or `:global` for no filtering
    * `:limit` - Maximum results to return (default: 10)
    * `:min_score` - Minimum composite score threshold (default: 0.0)
    * `:type` - Filter by memory type (`:semantic`, `:episodic`, `:procedural`)
    * `:scoring_weights` - Override default `[relevance: 0.5, importance: 0.3, recency: 0.2]`
    * `:decay_lambda` - Temporal decay rate (default: 0.001)
  """
  @spec search(module(), term(), String.t(), module() | nil, keyword()) ::
          {:ok, [{Entry.t(), float()}]}
  def search(store_mod, store_state, query, embedding_provider \\ nil, opts \\ []) do
    scope = Keyword.get(opts, :scope, %{})
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    type = Keyword.get(opts, :type)
    scoring_weights = Keyword.get(opts, :scoring_weights, [])
    decay_lambda = Keyword.get(opts, :decay_lambda, 0.001)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    embedding_opts = Keyword.get(opts, :embedding_opts, [])

    store_opts =
      [scope: normalize_scope(scope), limit: limit * 3]
      |> maybe_add_type(type)

    # Step 1: Text search
    {:ok, text_results} = store_mod.search_text(store_state, query, store_opts)

    # Step 2: Vector search (if embedding provider configured and store supports it)
    vector_results =
      if embedding_provider && supports_vector?(store_mod) do
        case Embedding.embed(embedding_provider, query, embedding_opts) do
          {:ok, query_embedding} ->
            {:ok, results} = store_mod.search_vector(store_state, query_embedding, store_opts)
            results

          {:error, _reason} ->
            []
        end
      else
        []
      end

    # Step 3: Merge results
    merged =
      if Enum.empty?(vector_results) do
        text_results
      else
        Scoring.rrf_merge(text_results, vector_results)
      end

    # Step 4 & 5: Apply temporal decay and composite scoring
    scored =
      merged
      |> Enum.map(fn {entry, relevance} ->
        decayed = Scoring.temporal_decay(relevance, entry, decay_lambda: decay_lambda, now: now)
        composite = Scoring.composite_score(decayed, entry, weights: scoring_weights, now: now)
        {entry, composite}
      end)

    # Step 6: Sort, filter, and take top N
    results =
      scored
      |> Enum.filter(fn {_entry, score} -> score >= min_score end)
      |> filter_by_type(type)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  defp normalize_scope(:global), do: %{}
  defp normalize_scope(scope) when is_map(scope), do: scope
  defp normalize_scope(_), do: %{}

  defp maybe_add_type(opts, nil), do: opts
  defp maybe_add_type(opts, type), do: Keyword.put(opts, :type, type)

  defp filter_by_type(results, nil), do: results

  defp filter_by_type(results, type) do
    Enum.filter(results, fn {entry, _score} -> entry.type == type end)
  end

  defp supports_vector?(store_mod) do
    Code.ensure_loaded(store_mod)
    function_exported?(store_mod, :search_vector, 3)
  end
end

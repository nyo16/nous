defmodule Nous.Memory.Search do
  @moduledoc """
  Hybrid search orchestrator for the memory system.

  Runs text and vector searches in parallel, merges results via Reciprocal Rank
  Fusion, applies temporal decay and composite scoring, and returns the top N
  results.

  When no embedding provider is configured, falls back to text-only search.
  """

  require Logger

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
          {:ok, [{Entry.t(), float()}]} | {:error, term()}
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

    # Kick off embedding concurrently with the text search. The embedding is a
    # network round-trip that does NOT touch the store, so it overlaps the text
    # scan (cutting the embedding RTT off the critical path) without two
    # processes sharing the store connection. search_vector still runs
    # sequentially after both complete, keeping all store access single-process
    # — safe for SQL backends whose connection isn't concurrency-safe.
    embed_task =
      if embedding_provider && supports_vector?(store_mod) do
        Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
          Embedding.embed(embedding_provider, query, embedding_opts)
        end)
      end

    # Step 1: Text search (in this process, concurrent with the embed task)
    case store_mod.search_text(store_state, query, store_opts) do
      {:ok, text_results} ->
        query_embedding = await_embedding(embed_task)

        do_search(text_results, query_embedding, store_mod, store_state,
          store_opts: store_opts,
          limit: limit,
          min_score: min_score,
          type: type,
          scoring_weights: scoring_weights,
          decay_lambda: decay_lambda,
          now: now
        )

      error ->
        # Don't leak the embed task if the text search failed.
        if embed_task, do: Task.shutdown(embed_task, :brutal_kill)
        error
    end
  end

  # Await the concurrently-running embedding task, converting every failure mode
  # (error tuple, crash, timeout) to nil → vector search is skipped, mirroring
  # the previous fail-open behaviour.
  defp await_embedding(nil), do: nil

  defp await_embedding(task) do
    case Task.yield(task, 30_000) || Task.shutdown(task) do
      {:ok, {:ok, embedding}} ->
        embedding

      {:ok, {:error, reason}} ->
        Logger.warning("Embedding failed: #{inspect(reason)}")
        nil

      {:exit, reason} ->
        Logger.warning("Embedding task crashed: #{inspect(reason)}")
        nil

      nil ->
        Logger.warning("Embedding timed out")
        nil
    end
  end

  defp do_search(text_results, query_embedding, store_mod, store_state, opts) do
    store_opts = Keyword.fetch!(opts, :store_opts)
    limit = Keyword.fetch!(opts, :limit)
    min_score = Keyword.fetch!(opts, :min_score)
    type = Keyword.fetch!(opts, :type)
    scoring_weights = Keyword.fetch!(opts, :scoring_weights)
    decay_lambda = Keyword.fetch!(opts, :decay_lambda)
    now = Keyword.fetch!(opts, :now)

    # Step 2: Vector search (only if the embedding succeeded and the store
    # supports it). Runs sequentially here — single-process store access.
    vector_results =
      if query_embedding && supports_vector?(store_mod) do
        case store_mod.search_vector(store_state, query_embedding, store_opts) do
          {:ok, results} ->
            results

          {:error, reason} ->
            Logger.warning("Vector search failed: #{inspect(reason)}")
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
        # RRF scores are tiny (peak ~2/61 ≈ 0.033). Feeding them straight into
        # composite_score/min_score made relevance negligible and broke min_score
        # thresholds tuned for the text-only (jaro 0-1) scale. Rescale to 0-1.
        text_results
        |> Scoring.rrf_merge(vector_results)
        |> normalize_relevance()
      end

    # Step 4: Apply temporal decay to relevance, then composite scoring
    # Note: temporal_decay penalizes old entries on the relevance score.
    # composite_score has its own recency weight, so we set recency weight to 0
    # when temporal decay is active to avoid double-penalizing old entries.
    effective_weights =
      if decay_lambda > 0 && scoring_weights[:recency] == nil do
        Keyword.put(scoring_weights, :recency, 0.0)
      else
        scoring_weights
      end

    scored =
      merged
      |> Enum.map(fn {entry, relevance} ->
        decayed = Scoring.temporal_decay(relevance, entry, decay_lambda: decay_lambda, now: now)
        composite = Scoring.composite_score(decayed, entry, weights: effective_weights, now: now)
        {entry, composite}
      end)

    # Step 6: Sort, filter, and take top N. min_score + type filters are folded
    # into a single predicate (one pass instead of two).
    results =
      scored
      |> Enum.filter(fn {entry, score} ->
        score >= min_score and (is_nil(type) or entry.type == type)
      end)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  # Rescale relevance scores so the top result maps to 1.0 (preserving relative
  # gaps), bringing RRF output onto the same 0-1 scale as text-only relevance.
  defp normalize_relevance([]), do: []

  defp normalize_relevance([{_entry, first} | _] = scored) do
    # Single reduce for the max (no intermediate score list), then one map to
    # rescale — folds the old map+max+map into two passes.
    max = Enum.reduce(scored, first, fn {_entry, score}, acc -> max(score, acc) end)

    if max > 0 do
      Enum.map(scored, fn {entry, score} -> {entry, score / max} end)
    else
      scored
    end
  end

  defp normalize_scope(:global), do: %{}
  defp normalize_scope(scope) when is_map(scope), do: scope
  defp normalize_scope(_), do: %{}

  defp maybe_add_type(opts, nil), do: opts
  defp maybe_add_type(opts, type), do: Keyword.put(opts, :type, type)

  defp supports_vector?(store_mod) do
    Code.ensure_loaded(store_mod)
    function_exported?(store_mod, :search_vector, 3)
  end
end

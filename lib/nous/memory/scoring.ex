defmodule Nous.Memory.Scoring do
  @moduledoc """
  Pure scoring functions for memory retrieval ranking.
  """

  alias Nous.Memory.Entry

  @doc """
  Reciprocal Rank Fusion merge of two ranked result lists.

  RRF formula: score(d) = sum(1 / (k + rank(d))) across all lists where d appears.
  """
  def rrf_merge(list_a, list_b, opts \\ []) do
    k = Keyword.get(opts, :k, 60)

    scores_a = rank_scores(list_a, k)
    scores_b = rank_scores(list_b, k)

    all_ids = MapSet.union(MapSet.new(Map.keys(scores_a)), MapSet.new(Map.keys(scores_b)))

    entries_by_id =
      Map.merge(
        Map.new(list_a, fn {entry, _} -> {entry.id, entry} end),
        Map.new(list_b, fn {entry, _} -> {entry.id, entry} end)
      )

    all_ids
    |> Enum.map(fn id ->
      rrf_score = Map.get(scores_a, id, 0.0) + Map.get(scores_b, id, 0.0)
      {Map.fetch!(entries_by_id, id), rrf_score}
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
  end

  defp rank_scores(results, k) do
    results
    |> Enum.with_index(1)
    |> Map.new(fn {{entry, _score}, rank} ->
      {entry.id, 1.0 / (k + rank)}
    end)
  end

  @doc """
  Apply temporal decay to a relevance score.

  decay = exp(-lambda * hours_since_access)
  Returns original score if entry is evergreen.
  """
  def temporal_decay(score, %Entry{evergreen: true}, _opts), do: score

  def temporal_decay(score, %Entry{} = entry, opts) do
    lambda = Keyword.get(opts, :decay_lambda, 0.001)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    hours = DateTime.diff(now, entry.last_accessed_at, :second) / 3600.0
    decay = :math.exp(-lambda * max(hours, 0.0))

    score * decay
  end

  @doc """
  Compute composite score combining relevance, importance, and recency.

  Default weights: relevance: 0.5, importance: 0.3, recency: 0.2
  """
  def composite_score(relevance, %Entry{} = entry, opts \\ []) do
    weights = Keyword.get(opts, :weights, relevance: 0.5, importance: 0.3, recency: 0.2)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    w_relevance = Keyword.get(weights, :relevance, 0.5)
    w_importance = Keyword.get(weights, :importance, 0.3)
    w_recency = Keyword.get(weights, :recency, 0.2)

    # Recency: exponential decay of hours since last access, normalized to 0-1
    hours = DateTime.diff(now, entry.last_accessed_at, :second) / 3600.0
    recency = :math.exp(-0.01 * max(hours, 0.0))

    w_relevance * relevance + w_importance * entry.importance + w_recency * recency
  end
end

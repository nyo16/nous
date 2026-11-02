defmodule Nous.Eval.Stats.Bootstrap do
  @moduledoc """
  Seeded paired cluster bootstrap (Koehn 2004, "Statistical Significance
  Tests for Machine Translation Evaluation", §6; resampling unit per Miller
  2024).

  Each replicate draws as many clusters as there are, with replacement, and
  evaluates a paired statistic on the drawn clusters. Because one draw
  serves both arms, the candidate–baseline correlation is kept. The cluster
  is the case, or a group of cases sharing a scenario/template when cases
  are not independent. Per-case values should already be reduced over the
  k samples (case means); metrics that are not case means (pass^k, F1,
  average precision) are recomputed per replicate by a custom statistic.

  ## Determinism

  Random draws come only from `:rand.uniform_s/2` on an explicit
  `:rand.seed_s(:exsss, seed)` state (never the process dictionary, never
  `normal_s`, whose output is platform-dependent). The algorithm is pinned
  to `:exsss` because `:default` may change between OTP releases.

  Replicates are split into `:streams` independent streams; stream `s`
  starts from the seeded state advanced by `s` calls of `:rand.jump/1`
  (2^64 draws each, so streams never overlap). The output depends only on
  `{seed, resamples, streams}`: running the streams concurrently
  (`:max_concurrency > 1`) gives results identical to running them
  serially. Persist `:seed`, `:algorithm`, `:resamples` and `:streams` from
  the result with any comparison so it can be reproduced.

  Percentile intervals undercover at small n (Bowyer et al. 2025); flag
  results with few clusters as such.
  """

  import Nous.Eval.Stats.Guards

  alias Nous.Eval.Stats.Special

  @typedoc """
  One cluster of paired items. With the default `:mean_difference`
  statistic each item is `{candidate, baseline}` (numbers, e.g. per-case
  means); with a custom statistic items can be any term.
  """
  @type cluster :: [term()]

  @typedoc "A function from the items of the drawn clusters to a number."
  @type statistic :: :mean_difference | ([term()] -> number())

  @type result :: %{
          required(:estimate) => float(),
          required(:ci) => Nous.Eval.Stats.ci(),
          required(:se) => float(),
          required(:p_le_0) => float(),
          required(:p_ge_0) => float(),
          required(:clusters) => pos_integer(),
          required(:resamples) => pos_integer(),
          required(:streams) => pos_integer(),
          required(:seed) => integer() | {integer(), integer(), integer()},
          required(:algorithm) => :exsss,
          required(:confidence) => float(),
          optional(:replicates) => [float()]
        }

  @doc """
  Paired cluster bootstrap of `statistic` over `clusters`.

  `clusters` is a list of clusters; each cluster is a non-empty list of
  paired items (see `t:cluster/0`). At least two clusters are required.

  Options:

    * `:seed` - **required**; an integer or a 3-tuple of integers
    * `:resamples` - number of replicates B, default `10_000`
    * `:statistic` - `:mean_difference` (default: mean of candidate minus
      mean of baseline over all drawn items) or a function receiving the
      flat list of drawn items and returning a number
    * `:confidence` - percentile interval level, default `0.95`
    * `:streams` - number of jumped random streams, default `8`
    * `:max_concurrency` - streams evaluated at once, default `1` (serial,
      in the calling process); results do not depend on it. A custom
      statistic runs in task processes when this is above 1.
    * `:keep_replicates` - include `:replicates` (in stream order) in the
      result, default `false`

  Result keys: `:estimate` (statistic on the original data), `:ci`
  (type-7 percentiles of the replicates), `:se` (standard deviation of the
  replicates), `:p_le_0` / `:p_ge_0` (share of replicates `<= 0` / `>= 0`,
  the one-sided "no improvement" / "no regression" shares), plus the
  reproducibility keys `:seed`, `:algorithm`, `:resamples`, `:streams`.

  Errors: `{:error, :seed_required}`, `{:error, :insufficient_clusters}`,
  `{:error, :empty_cluster}`, `{:error, :invalid_values}` (non-numeric
  pairs for `:mean_difference`), `{:error, {:invalid_statistic, value}}`
  when a custom statistic returns a non-number, and
  `{:error, {:invalid_option, key}}`.

  ## Examples

      iex> clusters = [[{1.0, 0.0}], [{1.0, 1.0}], [{0.5, 0.0}], [{1.0, 0.5}]]
      iex> {:ok, r} = Nous.Eval.Stats.Bootstrap.paired_cluster(clusters, seed: 42, resamples: 200)
      iex> {r.estimate, r.resamples, r.algorithm}
      {0.5, 200, :exsss}
  """
  @spec paired_cluster([cluster()], keyword()) ::
          {:ok, result()}
          | {:error,
             :seed_required
             | :insufficient_clusters
             | :empty_cluster
             | :invalid_values
             | :invalid_confidence
             | {:invalid_statistic, term()}
             | {:invalid_option, atom()}}
  def paired_cluster(clusters, opts) when is_list(clusters) and is_list(opts) do
    with {:ok, seed} <- seed_opt(opts),
         {:ok, resamples} <- pos_int_opt(opts, :resamples, 10_000),
         {:ok, streams} <- pos_int_opt(opts, :streams, 8),
         {:ok, concurrency} <- pos_int_opt(opts, :max_concurrency, 1),
         {:ok, conf} <- confidence(opts),
         :ok <- check_clusters(clusters),
         {:ok, evaluator} <- evaluator(Keyword.get(opts, :statistic, :mean_difference), clusters),
         {:ok, estimate} <- evaluate(evaluator, Enum.to_list(0..(length(clusters) - 1))) do
      replicates =
        clusters
        |> length()
        |> run_streams(seed, resamples, streams, concurrency, evaluator)

      with {:ok, replicates} <- check_replicates(replicates) do
        {:ok,
         summarize(replicates, estimate, conf)
         |> Map.merge(%{
           clusters: length(clusters),
           resamples: resamples,
           streams: streams,
           seed: seed,
           algorithm: :exsss,
           confidence: conf
         })
         |> maybe_keep(replicates, Keyword.get(opts, :keep_replicates, false))}
      end
    end
  end

  def paired_cluster(_clusters, _opts), do: {:error, :invalid_values}

  defp seed_opt(opts) do
    case Keyword.fetch(opts, :seed) do
      {:ok, seed} when is_integer(seed) ->
        {:ok, seed}

      {:ok, {a, b, c} = seed} when is_integer(a) and is_integer(b) and is_integer(c) ->
        {:ok, seed}

      {:ok, _} ->
        {:error, {:invalid_option, :seed}}

      :error ->
        {:error, :seed_required}
    end
  end

  defp check_clusters(clusters) do
    cond do
      length(clusters) < 2 -> {:error, :insufficient_clusters}
      not Enum.all?(clusters, &is_list/1) -> {:error, :invalid_values}
      Enum.any?(clusters, &(&1 == [])) -> {:error, :empty_cluster}
      true -> :ok
    end
  end

  # An evaluator maps a list of drawn cluster indices (0-based) to a value.
  # The default statistic works on per-cluster sums so a replicate costs
  # O(clusters) instead of O(items).
  defp evaluator(:mean_difference, clusters) do
    if Enum.all?(clusters, fn cluster -> Enum.all?(cluster, &numeric_pair?/1) end) do
      sums =
        clusters
        |> Enum.map(fn cluster ->
          Enum.reduce(cluster, {0.0, 0.0, 0}, fn {cand, base}, {sc, sb, n} ->
            {sc + cand, sb + base, n + 1}
          end)
        end)
        |> List.to_tuple()

      {:ok,
       fn indices ->
         {sc, sb, n} =
           Enum.reduce(indices, {0.0, 0.0, 0}, fn i, {sc, sb, n} ->
             {c, b, k} = elem(sums, i)
             {sc + c, sb + b, n + k}
           end)

         (sc - sb) / n
       end}
    else
      {:error, :invalid_values}
    end
  end

  defp evaluator(fun, clusters) when is_function(fun, 1) do
    tuple = List.to_tuple(clusters)
    {:ok, fn indices -> fun.(Enum.flat_map(indices, &elem(tuple, &1))) end}
  end

  defp evaluator(_other, _clusters), do: {:error, {:invalid_option, :statistic}}

  defp numeric_pair?({cand, base}) when is_number(cand) and is_number(base), do: true
  defp numeric_pair?(_), do: false

  defp evaluate(evaluator, indices) do
    case evaluator.(indices) do
      v when is_number(v) -> {:ok, v / 1}
      other -> {:error, {:invalid_statistic, other}}
    end
  end

  defp run_streams(m, seed, resamples, streams, concurrency, evaluator) do
    states = :exsss |> :rand.seed_s(seed) |> Stream.iterate(&:rand.jump/1) |> Enum.take(streams)
    sizes = stream_sizes(resamples, streams)
    work = Enum.zip(states, sizes)
    run = fn {state, size} -> run_stream(state, size, m, evaluator) end

    if concurrency == 1 do
      Enum.flat_map(work, run)
    else
      work
      |> Task.async_stream(run, max_concurrency: concurrency, ordered: true, timeout: :infinity)
      |> Enum.flat_map(fn {:ok, replicates} -> replicates end)
    end
  end

  # Contiguous blocks: the first rem(B, S) streams get one extra replicate.
  defp stream_sizes(resamples, streams) do
    base = div(resamples, streams)
    extra = rem(resamples, streams)
    for s <- 0..(streams - 1), do: base + if(s < extra, do: 1, else: 0)
  end

  defp run_stream(_state, 0, _m, _evaluator), do: []

  defp run_stream(state, size, m, evaluator) do
    {replicates, _state} =
      Enum.map_reduce(1..size, state, fn _, st ->
        {indices, st} = draw(m, m, st, [])
        {evaluator.(indices), st}
      end)

    replicates
  end

  defp draw(0, _m, state, acc), do: {acc, state}

  defp draw(left, m, state, acc) do
    {i, state} = :rand.uniform_s(m, state)
    draw(left - 1, m, state, [i - 1 | acc])
  end

  defp check_replicates(replicates) do
    case Enum.find(replicates, &(not is_number(&1))) do
      nil -> {:ok, Enum.map(replicates, &(&1 / 1))}
      other -> {:error, {:invalid_statistic, other}}
    end
  end

  defp summarize(replicates, estimate, conf) do
    sorted = replicates |> Enum.sort() |> List.to_tuple()
    tail = (1 - conf) / 2
    b = tuple_size(sorted)
    mean = Enum.sum(replicates) / b

    se =
      if b < 2,
        do: 0.0,
        else: :math.sqrt(Enum.reduce(replicates, 0.0, &((&1 - mean) ** 2 + &2)) / (b - 1))

    %{
      estimate: estimate,
      ci: {Special.tuple_quantile(sorted, tail), Special.tuple_quantile(sorted, 1 - tail)},
      se: se,
      p_le_0: Enum.count(replicates, &(&1 <= 0)) / b,
      p_ge_0: Enum.count(replicates, &(&1 >= 0)) / b
    }
  end

  defp maybe_keep(result, replicates, true), do: Map.put(result, :replicates, replicates)
  defp maybe_keep(result, _replicates, _), do: result
end

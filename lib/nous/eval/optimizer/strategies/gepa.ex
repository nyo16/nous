defmodule Nous.Eval.Optimizer.Strategies.GEPA do
  @moduledoc """
  Reflective evolution with a Pareto pool (GEPA, Agrawal et al. 2025).

  Each step:

    1. **Parent** - sampled from the Pareto frontier of the pool over the
       per-case validation scores: a candidate's weight is the number of
       validation cases on which it reaches the best score, after removing
       candidates another one dominates (GEPA Alg. 2). Seeded, so a run is
       reproducible.
    2. **Components** - one component per step in round-robin order
       (default), all of them (`mode: :all`), or a tool's description with
       its parameter descriptions as one group (`mode: :coupled`).
    3. **Minibatch** - the next `minibatch_size` train cases from a seeded,
       epoch-shuffled order.
    4. **Proposal** - the parent is evaluated on the minibatch, the
       reflector proposes new text from those train cases' records, and the
       lint runs.
    5. **Strict improvement** - the child is evaluated on the same
       minibatch and kept only if its summed objective is strictly higher.
    6. **Guard filter** - the guard-tagged cases must not regress
       (`Nous.Eval.Optimizer.Context.feasible/3`); an infeasible child never
       enters the pool, so it can never become a parent.
    7. **Validation** - the child is scored on the whole validation split
       and added to the pool.

  `best/1` is the pool member with the highest mean validation score (ties
  go to the earlier candidate). Every rejected proposal is logged with its
  reason.

  ## Merge

  With `merge: n` (`0` by default, at most 5 in the paper), after an
  accepted child the next step tries a merge first: two pool members that
  are not each other's ancestors and share an ancestor are combined
  component by component (the text from whichever changed it relative to
  the ancestor; the higher-scoring one when both did). No model call. The
  merge is kept when its mean validation score is at least that of both
  sources and it passes the guard filter.
  """

  @behaviour Nous.Eval.Optimizer.Strategy

  alias Nous.Eval.Optimizer.{Candidate, Context, Evaluation}

  @impl true
  def init(%Candidate{} = seed, %Context{} = ctx) do
    with {:ok, val} <- Context.evaluate(ctx, seed.profile, ctx.val, "val") do
      seed = %{seed | scores: val.scores, mean: Evaluation.mean(val)}

      {:ok,
       %{
         pool: [seed],
         rng: ctx.rng,
         rr: 0,
         queue: [],
         rejections: [],
         merges_left: ctx.merge,
         try_merge?: false
       }}
    end
  end

  @impl true
  def step(state, %Context{} = ctx) do
    if state.try_merge? and state.merges_left > 0 do
      merge_step(%{state | try_merge?: false}, ctx)
    else
      reflect_step(state, ctx)
    end
  end

  defp reflect_step(state, ctx) do
    {parent, rng} = pareto_sample(state.pool, state.rng)
    {keys, rr} = select_components(ctx, state.rr)
    {batch, queue, rng} = minibatch(state.queue, ctx.train, ctx.minibatch_size, rng)
    state = %{state | rng: rng, rr: rr, queue: queue}

    result =
      with {:ok, before} <- Context.evaluate(ctx, parent.profile, batch, "train"),
           {:ok, updates} <- Context.propose(ctx, parent, before, keys),
           {:ok, child} <- Context.derive(ctx, parent.profile, updates, %{"step" => ctx.step}),
           :ok <- new_candidate(state.pool, child),
           {:ok, after_} <- Context.evaluate(ctx, child, batch, "train"),
           :ok <- improved(before, after_),
           :ok <- Context.feasible(ctx, parent, child),
           {:ok, val} <- Context.evaluate(ctx, child, ctx.val, "val") do
        {:accept,
         %Candidate{
           profile: child,
           parent_id: Candidate.id(parent),
           step: ctx.step,
           scores: val.scores,
           mean: Evaluation.mean(val),
           changed: Map.keys(updates)
         }}
      end

    settle(result, state, ctx, %{parent_id: Candidate.id(parent), components: keys})
  end

  defp settle({:accept, child}, state, _ctx, _info),
    do: {:cont, %{state | pool: state.pool ++ [child], try_merge?: state.merges_left > 0}}

  defp settle({:error, :budget_exhausted}, state, _ctx, _info),
    do: {:halt, :budget_exhausted, state}

  defp settle({:error, {:evaluation_failed, _} = reason}, state, _ctx, _info),
    do: {:halt, reason, state}

  defp settle({:error, reason}, state, ctx, info),
    do:
      {:cont,
       %{
         state
         | rejections: state.rejections ++ [Map.merge(info, %{step: ctx.step, reason: reason})]
       }}

  defp new_candidate(pool, child) do
    if Enum.any?(pool, &(Candidate.id(&1) == child.id)), do: {:error, :duplicate}, else: :ok
  end

  # GEPA's acceptance compares summed minibatch scores, strictly.
  defp improved(before, after_) do
    if Evaluation.total(after_) > Evaluation.total(before),
      do: :ok,
      else: {:error, {:no_improvement, Evaluation.total(before), Evaluation.total(after_)}}
  end

  # ── merge ──────────────────────────────────────────────────────────────

  defp merge_step(state, ctx) do
    case merge_pair(state.pool) do
      nil ->
        reflect_step(state, ctx)

      {a, b, ancestor} ->
        state = %{state | merges_left: state.merges_left - 1}
        updates = merged_components(a, b, ancestor)

        result =
          with {:ok, child} <-
                 Context.derive(ctx, ancestor.profile, updates, %{
                   "step" => ctx.step,
                   "merge" => true
                 }),
               :ok <- new_candidate(state.pool, child),
               :ok <- Context.feasible(ctx, a, child),
               :ok <- Context.feasible(ctx, b, child),
               {:ok, val} <- Context.evaluate(ctx, child, ctx.val, "val"),
               mean = Evaluation.mean(val),
               :ok <-
                 if(mean >= max(a.mean, b.mean),
                   do: :ok,
                   else: {:error, {:merge_not_better, mean}}
                 ) do
            {:accept,
             %Candidate{
               profile: child,
               parent_id: Candidate.id(ancestor),
               merged_from: [Candidate.id(a), Candidate.id(b)],
               step: ctx.step,
               scores: val.scores,
               mean: mean,
               changed: Map.keys(updates)
             }}
          end

        case settle(result, state, ctx, %{
               parent_id: Candidate.id(ancestor),
               components: Map.keys(updates),
               merge: true
             }) do
          {:cont, state} -> {:cont, %{state | try_merge?: false}}
          other -> other
        end
    end
  end

  # The most recent pair that is merge-able: not ancestors of each other,
  # sharing an ancestor, and each changing a component the other did not.
  defp merge_pair(pool) do
    by_id = Map.new(pool, &{Candidate.id(&1), &1})

    pairs =
      for a <- Enum.reverse(pool),
          b <- Enum.reverse(pool),
          Candidate.id(a) < Candidate.id(b),
          do: {a, b}

    Enum.find_value(pairs, fn {a, b} ->
      ancestors_a = ancestors(a, by_id)
      ancestors_b = ancestors(b, by_id)

      with false <- Candidate.id(a) in ancestors_b or Candidate.id(b) in ancestors_a,
           [common | _] <- Enum.filter(ancestors_a, &(&1 in ancestors_b)),
           ancestor = by_id[common],
           true <- desirable?(a, b, ancestor) do
        {a, b, ancestor}
      else
        _ -> nil
      end
    end)
  end

  defp ancestors(candidate, by_id) do
    case candidate.parent_id && by_id[candidate.parent_id] do
      nil -> []
      parent -> [Candidate.id(parent) | ancestors(parent, by_id)]
    end
  end

  defp desirable?(a, b, ancestor) do
    changed_a = diff_keys(a, ancestor)
    changed_b = diff_keys(b, ancestor)
    MapSet.size(MapSet.symmetric_difference(changed_a, changed_b)) > 0
  end

  defp diff_keys(candidate, ancestor) do
    keys = Map.keys(candidate.profile.components) ++ Map.keys(ancestor.profile.components)

    keys
    |> Enum.uniq()
    |> Enum.filter(&(candidate.profile.components[&1] != ancestor.profile.components[&1]))
    |> MapSet.new()
  end

  defp merged_components(a, b, ancestor) do
    changed_a = diff_keys(a, ancestor)
    changed_b = diff_keys(b, ancestor)

    MapSet.union(changed_a, changed_b)
    |> Map.new(fn key ->
      source =
        cond do
          MapSet.member?(changed_a, key) and MapSet.member?(changed_b, key) ->
            if b.mean > a.mean, do: b, else: a

          MapSet.member?(changed_a, key) ->
            a

          true ->
            b
        end

      {key, source.profile.components[key]}
    end)
    |> Map.reject(fn {_key, text} -> is_nil(text) end)
  end

  # ── selection ──────────────────────────────────────────────────────────

  @doc false
  # Pareto parent sampling (GEPA Alg. 2) over the candidates' per-case
  # scores; returns `{candidate, rng}`.
  @spec pareto_sample([Candidate.t()], :rand.state()) :: {Candidate.t(), :rand.state()}
  def pareto_sample([only], rng), do: {only, rng}

  def pareto_sample(pool, rng) do
    weights = pareto_weights(pool)
    total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {pick, rng} = :rand.uniform_s(total, rng)

    {candidate, _} =
      Enum.reduce_while(weights, pick, fn {candidate, weight}, left ->
        if left <= weight, do: {:halt, {candidate, 0}}, else: {:cont, left - weight}
      end)

    {candidate, rng}
  end

  @doc false
  @spec pareto_weights([Candidate.t()]) :: [{Candidate.t(), pos_integer()}]
  def pareto_weights(pool) do
    cases = pool |> Enum.flat_map(&Map.keys(&1.scores)) |> Enum.uniq() |> Enum.sort()

    wins =
      Enum.reduce(cases, %{}, fn case_id, acc ->
        best = pool |> Enum.map(&Map.get(&1.scores, case_id, 0.0)) |> Enum.max()

        pool
        |> Enum.filter(&(Map.get(&1.scores, case_id, 0.0) >= best - 1.0e-12))
        |> Enum.reduce(acc, fn c, acc -> Map.update(acc, Candidate.id(c), 1, &(&1 + 1)) end)
      end)

    frontier = Enum.filter(pool, &Map.has_key?(wins, Candidate.id(&1)))
    kept = Enum.reject(frontier, fn c -> Enum.any?(frontier, &dominates?(&1, c, cases)) end)
    kept = if kept == [], do: pool, else: kept

    Enum.map(kept, &{&1, Map.get(wins, Candidate.id(&1), 1)})
  end

  defp dominates?(a, b, cases) do
    Candidate.id(a) != Candidate.id(b) and
      Enum.all?(cases, &(Map.get(a.scores, &1, 0.0) >= Map.get(b.scores, &1, 0.0))) and
      Enum.any?(cases, &(Map.get(a.scores, &1, 0.0) > Map.get(b.scores, &1, 0.0)))
  end

  defp select_components(%Context{mode: :all, components: keys}, rr), do: {keys, rr}

  defp select_components(%Context{mode: :coupled, components: keys}, rr) do
    groups = keys |> Enum.group_by(&group/1) |> Enum.sort() |> Enum.map(&elem(&1, 1))
    {Enum.at(groups, rem(rr, length(groups))), rr + 1}
  end

  defp select_components(%Context{components: keys}, rr),
    do: {[Enum.at(keys, rem(rr, length(keys)))], rr + 1}

  defp group("tool:" <> rest), do: "tool:" <> (rest |> String.split("#", parts: 2) |> hd())
  defp group(key), do: key

  # The next `size` train cases from a seeded epoch-shuffled order.
  defp minibatch(queue, train, size, rng) do
    size = min(size, length(train))

    {queue, rng} =
      if length(queue) < size do
        {shuffled, rng} = shuffle(train, rng)
        {queue ++ shuffled, rng}
      else
        {queue, rng}
      end

    {batch, rest} = Enum.split(queue, size)
    {batch, rest, rng}
  end

  defp shuffle(list, rng) do
    {keyed, rng} =
      Enum.map_reduce(list, rng, fn item, rng ->
        {x, rng} = :rand.uniform_s(rng)
        {{x, item}, rng}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rng}
  end

  @impl true
  def best(%{pool: pool}) do
    Enum.reduce(pool, fn candidate, best ->
      if candidate.mean > best.mean, do: candidate, else: best
    end)
  end

  @impl true
  def summary(state), do: %{candidates: state.pool, rejections: state.rejections}
end

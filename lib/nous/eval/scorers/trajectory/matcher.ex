defmodule Nous.Eval.Scorers.Trajectory.Matcher do
  @moduledoc false
  # Multiset trajectory matching (research/scorers.md §4.2).
  #
  # Expected entries expand into slots: an entry with `count {min, max}`
  # gives `min` required slots and `max - min` optional ones (capped at the
  # number of actual calls, since more could never match). A slot matches
  # an actual call when names are equal and the arguments match.
  #
  # Order-free modes use a maximum bipartite matching (augmenting paths)
  # rather than greedy first-fit: greedy lets a wildcard entry take the
  # only call a later, more specific entry could have matched. Slots are
  # offered required-first; matchings form a transversal matroid, so this
  # order gives a maximum matching that also matches the most required
  # slots.
  #
  # Ordered modes run a DP over (batch, slot): each batch of actual calls
  # (calls from one model response, or one call each when batches are
  # ignored) takes a contiguous run of slots, matched order-free inside the
  # batch. The DP maximizes (required slots matched, total matched)
  # lexicographically.

  alias Nous.Eval.Scorers.Args
  alias Nous.Eval.Trace.ToolCall

  # Bounds the ordered DP: batches × slots² block matchings.
  @max_ordered_work 2_000_000

  @type entry :: %{
          index: non_neg_integer(),
          name: String.t(),
          args: :any | map(),
          min: non_neg_integer(),
          max: pos_integer()
        }

  @doc """
  Matches `calls` against `entries`. `config` holds `:mode`, `:parallel` and
  the argument config for `Args.diff/4`. Returns `{:ok, result}` or
  `{:error, :too_large}`.
  """
  def run(calls, entries, config) do
    calls = List.to_tuple(calls)
    n = tuple_size(calls)
    slots = slots(entries, n)
    compat = compat(calls, entries, config)

    owner =
      case config.mode do
        mode when mode in [:unordered, :superset, :subset] ->
          {:ok, bipartite(slot_ids(slots), Enum.to_list(0..(n - 1)//1), slots, compat)}

        _ordered ->
          ordered(batches(calls, config.parallel), slots, compat)
      end

    with {:ok, owner} <- owner do
      {:ok, result(owner, calls, slots, entries, compat, config)}
    end
  end

  defp slots(entries, n) do
    entries
    |> Enum.flat_map(fn %{index: j, min: min, max: max} ->
      optional = max(min(max, max(min, n)) - min, 0)
      List.duplicate({j, true}, min) ++ List.duplicate({j, false}, optional)
    end)
    |> List.to_tuple()
  end

  defp slot_ids(slots), do: Enum.to_list(0..(tuple_size(slots) - 1)//1)

  # compat: MapSet of {call_index, entry_index} that match.
  defp compat(calls, entries, config) do
    for i <- 0..(tuple_size(calls) - 1)//1,
        %{index: j} = entry <- entries,
        matches?(elem(calls, i), entry, config),
        into: MapSet.new(),
        do: {i, j}
  end

  defp matches?(%ToolCall{name: name}, %{name: name, args: :any}, _config), do: true

  defp matches?(%ToolCall{name: name, arguments: actual}, %{name: name, args: expected}, config),
    do: Args.match?(name, actual, expected, config.arg_config)

  defp matches?(_call, _entry, _config), do: false

  # ── bipartite ──────────────────────────────────────────────────────────────

  # Returns owner: call index => slot index.
  defp bipartite(slot_ids, call_ids, slots, compat) do
    {required, optional} = Enum.split_with(slot_ids, &elem(elem(slots, &1), 1))

    adj = fn slot ->
      {j, _required?} = elem(slots, slot)
      Enum.filter(call_ids, &MapSet.member?(compat, {&1, j}))
    end

    Enum.reduce(required ++ optional, %{}, fn slot, owner ->
      case augment(slot, adj, owner, %{}) do
        {:ok, owner, _visited} -> owner
        {:fail, _visited} -> owner
      end
    end)
  end

  # `visited` is a plain map used as a set: it is threaded through recursive
  # calls and an accumulator, where an opaque MapSet trips dialyzer.
  defp augment(slot, adj, owner, visited) do
    Enum.reduce_while(adj.(slot), {:fail, visited}, fn call, {:fail, visited} ->
      if Map.has_key?(visited, call) do
        {:cont, {:fail, visited}}
      else
        visited = Map.put(visited, call, true)

        case Map.fetch(owner, call) do
          :error ->
            {:halt, {:ok, Map.put(owner, call, slot), visited}}

          {:ok, other} ->
            case augment(other, adj, owner, visited) do
              {:ok, owner, visited} -> {:halt, {:ok, Map.put(owner, call, slot), visited}}
              {:fail, visited} -> {:cont, {:fail, visited}}
            end
        end
      end
    end)
  end

  # ── ordered ────────────────────────────────────────────────────────────────

  defp batches(calls, parallel) do
    calls
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.chunk_while(
      nil,
      fn {call, i}, acc ->
        key = batch_key(call, parallel, i)

        case acc do
          {^key, ids} -> {:cont, {key, [i | ids]}}
          nil -> {:cont, {key, [i]}}
          {_key, ids} -> {:cont, Enum.reverse(ids), {key, [i]}}
        end
      end,
      fn
        nil -> {:cont, nil}
        {_key, ids} -> {:cont, Enum.reverse(ids), nil}
      end
    )
  end

  defp batch_key(%ToolCall{batch: {run, iteration}}, :unordered_within_batch, _i)
       when is_integer(iteration),
       do: {:batch, run, iteration}

  defp batch_key(_call, _parallel, i), do: {:single, i}

  defp ordered(batches, slots, compat) do
    nb = length(batches)
    s = tuple_size(slots)

    if nb * (s + 1) * (s + 1) > @max_ordered_work do
      {:error, :too_large}
    else
      batches = List.to_tuple(batches)
      init = Map.new(0..s, &{{nb, &1}, {0, 0, s, %{}}})

      table =
        Enum.reduce((nb - 1)..0//-1, init, fn b, table ->
          Enum.reduce(s..0//-1, table, fn k, table ->
            Map.put(table, {b, k}, best(b, k, s, elem(batches, b), slots, compat, table))
          end)
        end)

      {:ok, walk(table, 0, 0, nb, %{})}
    end
  end

  defp best(b, k, s, batch, slots, compat, table) do
    Enum.reduce(k..s, nil, fn k2, best ->
      owner = bipartite(Enum.to_list(k..(k2 - 1)//1), batch, slots, compat)
      {r2, t2, _next, _owner} = Map.fetch!(table, {b + 1, k2})
      r = r2 + Enum.count(owner, fn {_call, slot} -> elem(elem(slots, slot), 1) end)
      t = t2 + map_size(owner)

      case best do
        {br, bt, _, _} when {br, bt} >= {r, t} -> best
        _ -> {r, t, k2, owner}
      end
    end)
  end

  defp walk(_table, b, _k, nb, acc) when b == nb, do: acc

  defp walk(table, b, k, nb, acc) do
    {_r, _t, next, owner} = Map.fetch!(table, {b, k})
    walk(table, b + 1, next, nb, Map.merge(acc, owner))
  end

  # ── result ─────────────────────────────────────────────────────────────────

  defp result(owner, calls, slots, entries, compat, config) do
    n = tuple_size(calls)
    slot_list = Tuple.to_list(slots)
    required_total = Enum.count(slot_list, &elem(&1, 1))
    matched_slots = owner |> Map.values() |> MapSet.new()

    required_matched =
      Enum.count(matched_slots, fn slot -> elem(elem(slots, slot), 1) end)

    total = map_size(owner)

    passed? =
      case config.mode do
        :superset -> required_matched == required_total
        :in_order -> required_matched == required_total
        :subset -> total == n
        _strict_or_unordered -> required_matched == required_total and total == n
      end

    missing = missing(slot_list, matched_slots, entries)
    unmatched = for i <- 0..(n - 1)//1, not is_map_key(owner, i), do: elem(calls, i)

    %{
      passed?: passed?,
      precision: if(n == 0, do: 1.0, else: total / n),
      recall: if(required_total == 0, do: 1.0, else: required_matched / required_total),
      matched:
        owner
        |> Enum.sort()
        |> Enum.map(fn {i, slot} ->
          %{expected: elem(elem(slots, slot), 0), tool_call_id: elem(calls, i).id}
        end),
      missing: missing,
      unexpected: Enum.map(unmatched, &%{tool_call_id: &1.id, name: &1.name}),
      out_of_order: out_of_order(missing, compat, n, config.mode),
      arg_mismatches: arg_mismatches(missing, entries, calls, owner, config)
    }
  end

  defp missing(slot_list, matched_slots, entries) do
    by_entry =
      slot_list
      |> Enum.with_index()
      |> Enum.reject(fn {{_j, required?}, slot} ->
        not required? or MapSet.member?(matched_slots, slot)
      end)
      |> Enum.frequencies_by(fn {{j, _}, _slot} -> j end)

    Enum.flat_map(entries, fn %{index: j, name: name} ->
      case Map.fetch(by_entry, j) do
        {:ok, count} -> [%{expected: j, name: name, count: count}]
        :error -> []
      end
    end)
  end

  defp out_of_order(missing, compat, n, mode) when mode in [:strict, :in_order] do
    for %{expected: j} <- missing,
        Enum.any?(0..(n - 1)//1, &MapSet.member?(compat, {&1, j})),
        do: j
  end

  defp out_of_order(_missing, _compat, _n, _mode), do: []

  defp arg_mismatches(missing, entries, calls, owner, config) do
    by_index = Map.new(entries, &{&1.index, &1})

    Enum.flat_map(missing, fn %{expected: j} ->
      case Map.fetch!(by_index, j) do
        %{args: :any} ->
          []

        %{name: name, args: expected} ->
          candidates =
            for i <- 0..(tuple_size(calls) - 1)//1,
                elem(calls, i).name == name,
                do: {is_map_key(owner, i), elem(calls, i)}

          case Enum.sort_by(candidates, &elem(&1, 0)) do
            [{_matched?, call} | _] ->
              paths = Args.diff(name, call.arguments, expected, config.arg_config)
              if paths == [], do: [], else: [%{expected: j, tool_call_id: call.id, paths: paths}]

            [] ->
              []
          end
      end
    end)
  end
end

defmodule Nous.Memory.Store.Results do
  @moduledoc """
  Result post-processing shared by index-plus-entry-table memory stores.

  A backend owns its own *retrieval* — a jaro scan, an inverted index, a vector
  collection — but they all finish the same way: hydrate the hit ids from an entry
  table, drop out-of-scope entries, cut below `min_score`, sort, truncate. This is
  that tail, and it is public because a `Nous.Memory.Store` implementation living
  outside Nous needs exactly the same back half (see `Nous.Memory.Store`).

  Keeping it as one definition is not cosmetic: it was four copies, and the copy
  that handled scored results was unreachable in three of them, so any scoped
  vector or full-text search raised `BadMapError` (see `filter_by_scope/2`).
  """

  alias Nous.Memory.Entry

  @type scored :: {Entry.t(), number()}

  @doc """
  Every entry in the store's ETS side table, unordered.
  """
  @spec all_entries(:ets.table()) :: [Entry.t()]
  def all_entries(table) do
    :ets.tab2list(table) |> Enum.map(fn {_id, entry} -> entry end)
  end

  @doc """
  Keep only entries whose fields match every key in `scope`.

  Accepts either bare entries or `{entry, score}` pairs; the shape is
  dispatched per element, not per list.

  This used to be three clauses per store, the last of which handled the
  scored shape and was unreachable: the clause above it guarded on
  `is_list/1`, which a list of `{entry, score}` pairs also satisfies. Any
  scoped vector or full-text search therefore reached `Map.get/2` with a
  tuple and raised `BadMapError`.
  """
  @spec filter_by_scope([Entry.t()] | [scored()], map()) :: [Entry.t()] | [scored()]
  def filter_by_scope(entries, scope) when map_size(scope) == 0, do: entries

  def filter_by_scope(entries, scope) do
    Enum.filter(entries, fn
      {entry, _score} -> in_scope?(entry, scope)
      entry -> in_scope?(entry, scope)
    end)
  end

  @doc """
  Turn a backend's scored hits into the store's `{entry, score}` result list.

  `hits` are `%{id: id, score: score}` maps from the search backend. Ids with
  no surviving ETS row are dropped: the index and the side table are written
  separately, so an id can outlive its entry.
  """
  @spec rank([%{id: String.t(), score: number()}], :ets.table(), map(), number(), pos_integer()) ::
          [scored()]
  def rank(hits, table, scope, min_score, limit) do
    hits
    |> Enum.flat_map(fn %{id: id, score: score} ->
      case :ets.lookup(table, id) do
        [{^id, entry}] -> [{entry, score}]
        [] -> []
      end
    end)
    |> filter_by_scope(scope)
    |> Enum.filter(fn {_entry, score} -> score > min_score end)
    |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
    |> Enum.take(limit)
  end

  defp in_scope?(entry, scope) do
    Enum.all?(scope, fn {key, value} -> Map.get(entry, key) == value end)
  end
end

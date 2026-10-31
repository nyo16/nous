defmodule Nous.KnowledgeBase.LinkScope do
  @moduledoc false
  # The links of one knowledge base, for the health check (Nous.KnowledgeBase
  # .Tools) and the health workflow (Nous.KnowledgeBase.Workflows).
  #
  # A store can hold several kb_ids, and links made before kb_link refused
  # cross-KB links (0.18.2) can join two of them. A link belongs to a
  # knowledge base only when BOTH of its ends are entries of it: counting by
  # source alone keeps links into another KB, and treating any link as
  # "linked" hides a KB's orphans behind a foreign link.

  @doc false
  # `{from_entry_id, to_entry_id}` for every link with both ends in `entries`.
  #
  # One scan through the optional `link_endpoints/1` Store callback when the
  # backend has it; otherwise `outlinks/2` per entry, which is
  # O(entries × links) on a naive backend but correct for any of them.
  @spec endpoints(module(), term(), [Nous.KnowledgeBase.Entry.t()]) :: [{String.t(), String.t()}]
  def endpoints(store_mod, store_state, entries) do
    ids = MapSet.new(entries, & &1.id)

    store_mod
    |> all_endpoints(store_state, ids)
    |> Enum.filter(fn {from, to} -> MapSet.member?(ids, from) and MapSet.member?(ids, to) end)
  end

  defp all_endpoints(store_mod, store_state, ids) do
    # Code.ensure_loaded?/1 first: function_exported?/3 is false for a module
    # that has not been loaded yet, which would silently take the slow path
    # even for the first-party ETS store.
    with true <-
           Code.ensure_loaded?(store_mod) and function_exported?(store_mod, :link_endpoints, 1),
         {:ok, pairs} <- store_mod.link_endpoints(store_state) do
      pairs
    else
      _ -> per_entry_endpoints(store_mod, store_state, ids)
    end
  end

  defp per_entry_endpoints(store_mod, store_state, ids) do
    Enum.flat_map(ids, fn id ->
      case store_mod.outlinks(store_state, id) do
        {:ok, links} -> Enum.map(links, &{&1.from_entry_id, &1.to_entry_id})
        _ -> []
      end
    end)
  end
end

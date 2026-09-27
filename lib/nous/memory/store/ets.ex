defmodule Nous.Memory.Store.ETS do
  @moduledoc """
  ETS-backed memory store implementation.

  Uses an unnamed ETS table so multiple instances can coexist.
  Text search uses `String.jaro_distance/2` for fuzzy matching.
  Does not implement `search_vector/3` (no vector support in ETS).
  """

  @behaviour Nous.Memory.Store

  alias Nous.Memory.Entry

  @impl true
  def init(_opts) do
    # read_concurrency only: memory is recalled far more often than it is
    # written, and every search/list is a concurrent read from the agent loop
    # plus its tool tasks. write_concurrency would add a per-scheduler lock
    # stripe to what is effectively a single-writer table.
    table = :ets.new(:memory_store, [:set, :public, read_concurrency: true])
    {:ok, table}
  end

  # Rows are `{id, entry, content_down}`: the downcased content is stored once
  # at write time so search_text/3 does not `String.downcase/1` every row on
  # every query (it was the dominant per-row cost of the jaro scan). It is a
  # tuple element, not an Entry field, so the backend contract is unchanged
  # and nothing outside this module sees it.
  @impl true
  def store(table, %Entry{} = entry) do
    :ets.insert(table, row(entry))
    {:ok, table}
  end

  @impl true
  def fetch(table, id) do
    case :ets.lookup(table, id) do
      [{^id, entry, _content_down}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(table, id) do
    :ets.delete(table, id)
    {:ok, table}
  end

  @impl true
  def update(table, id, updates) do
    case fetch(table, id) do
      {:ok, entry} ->
        now = DateTime.utc_now()
        updated = struct(entry, Map.put(updates, :updated_at, now))
        :ets.insert(table, row(updated))
        {:ok, table}

      error ->
        error
    end
  end

  defp row(%Entry{} = entry), do: {entry.id, entry, String.downcase(entry.content)}

  @impl true
  def search_text(table, query, opts) do
    scope = Keyword.get(opts, :scope, %{})
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    # Downcase the query ONCE, not once per row (it is loop-invariant); the
    # rows carry their own downcased content (see store/2).
    query_down = String.downcase(query)

    results =
      table
      |> scoped_rows(scope)
      |> Enum.map(fn {_id, entry, content_down} ->
        {entry, String.jaro_distance(query_down, content_down)}
      end)
      |> Enum.filter(fn {_entry, score} -> score > min_score end)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  @impl true
  def list(table, opts) do
    scope = Keyword.get(opts, :scope, %{})

    entries =
      table
      |> scoped_rows(scope)
      |> Enum.map(fn {_id, entry, _content_down} -> entry end)
      |> order(Keyword.get(opts, :order))
      |> take(Keyword.get(opts, :limit))

    {:ok, entries}
  end

  defp order(entries, :newest), do: Enum.sort_by(entries, & &1.created_at, {:desc, DateTime})
  defp order(entries, _unspecified), do: entries

  defp take(entries, limit) when is_integer(limit) and limit >= 0, do: Enum.take(entries, limit)
  defp take(entries, _no_limit), do: entries

  # Push the scope filter INTO ETS via a partial-map matchspec, so we only copy
  # (and later jaro-score) the matching rows instead of tab2list-copying the
  # whole table and filtering in Elixir. At 10k entries a scoped search copied
  # ~49 MB (the full table) under tab2list; this drops it to just the matches.
  #
  # An empty scope still copies everything — unavoidable for a full scan, and
  # the documented scaling ceiling for the ETS store. A scope carrying a key
  # that isn't an Entry field can't be pushed down (a partial-map pattern
  # requires the key to exist on the struct), so we fall back to copy+filter to
  # stay behavior-identical.
  # A non-map scope (e.g. :global) means "no scope" — return everything.
  defp scoped_rows(table, scope) when not is_map(scope), do: :ets.tab2list(table)

  defp scoped_rows(table, scope) when map_size(scope) == 0, do: :ets.tab2list(table)

  defp scoped_rows(table, scope) do
    if scope_pushable?(scope) do
      pattern = {:_, Map.put(scope, :__struct__, Entry), :_}
      :ets.select(table, [{pattern, [], [:"$_"]}])
    else
      table |> :ets.tab2list() |> filter_by_scope(scope)
    end
  end

  defp scope_pushable?(scope) do
    entry_fields = %Entry{} |> Map.from_struct() |> Map.keys()
    Enum.all?(Map.keys(scope), &(&1 in entry_fields))
  end

  # Fallback path only — reached when scope is non-empty AND has a non-Entry
  # key (scoped_rows/2 short-circuits the empty-scope case).
  defp filter_by_scope(rows, scope) do
    Enum.filter(rows, fn {_id, entry, _content_down} ->
      Enum.all?(scope, fn {key, value} ->
        Map.get(entry, key) == value
      end)
    end)
  end
end

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
    table = :ets.new(:memory_store, [:set, :public])
    {:ok, table}
  end

  @impl true
  def store(table, %Entry{} = entry) do
    :ets.insert(table, {entry.id, entry})
    {:ok, table}
  end

  @impl true
  def fetch(table, id) do
    case :ets.lookup(table, id) do
      [{^id, entry}] -> {:ok, entry}
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
        :ets.insert(table, {id, updated})
        {:ok, table}

      error ->
        error
    end
  end

  @impl true
  def search_text(table, query, opts) do
    scope = Keyword.get(opts, :scope, %{})
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    results =
      table
      |> scoped_entries(scope)
      |> Enum.map(fn entry ->
        score = String.jaro_distance(String.downcase(query), String.downcase(entry.content))
        {entry, score}
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
      |> scoped_entries(scope)

    {:ok, entries}
  end

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
  defp scoped_entries(table, scope) when not is_map(scope), do: all_entries(table)

  defp scoped_entries(table, scope) when map_size(scope) == 0, do: all_entries(table)

  defp scoped_entries(table, scope) do
    if scope_pushable?(scope) do
      pattern = {:_, Map.put(scope, :__struct__, Entry)}

      table
      |> :ets.select([{pattern, [], [:"$_"]}])
      |> Enum.map(fn {_id, entry} -> entry end)
    else
      table |> all_entries() |> filter_by_scope(scope)
    end
  end

  defp scope_pushable?(scope) do
    entry_fields = %Entry{} |> Map.from_struct() |> Map.keys()
    Enum.all?(Map.keys(scope), &(&1 in entry_fields))
  end

  defp all_entries(table) do
    :ets.tab2list(table) |> Enum.map(fn {_id, entry} -> entry end)
  end

  # Fallback path only — reached when scope is non-empty AND has a non-Entry
  # key (scoped_entries/2 short-circuits the empty-scope case).
  defp filter_by_scope(entries, scope) do
    Enum.filter(entries, fn entry ->
      Enum.all?(scope, fn {key, value} ->
        Map.get(entry, key) == value
      end)
    end)
  end
end

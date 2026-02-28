if Code.ensure_loaded?(Zvec) do
  defmodule Nous.Memory.Store.Zvec do
    @moduledoc """
    Zvec-backed memory store with HNSW/IVF vector similarity search.

    Uses Zvec for vector indexing/search and ETS for full entry storage.
    Does not implement `search_text/3` (vector-only backend).

    Requires optional dep: `{:zvec, "~> 0.1"}`

    ## Options

      * `:collection_path` - filesystem path for Zvec collection files (required)
      * `:embedding_dimension` - vector dimension (default: 1536)
    """

    @behaviour Nous.Memory.Store

    alias Nous.Memory.Entry

    @default_dimension 1536

    @impl true
    def init(opts) do
      collection_path = Keyword.fetch!(opts, :collection_path)
      dimension = Keyword.get(opts, :embedding_dimension, @default_dimension)

      with {:ok, collection} <- Zvec.create_collection(collection_path, dimension: dimension) do
        table = :ets.new(:zvec_store, [:set, :public])
        {:ok, %{collection: collection, entries: table}}
      end
    rescue
      _ ->
        case Zvec.open_collection(collection_path) do
          {:ok, collection} ->
            table = :ets.new(:zvec_store, [:set, :public])
            {:ok, %{collection: collection, entries: table}}

          error ->
            error
        end
    end

    @impl true
    def store(%{collection: collection, entries: table} = state, %Entry{} = entry) do
      :ets.insert(table, {entry.id, entry})

      if entry.embedding do
        :ok = Zvec.add(collection, entry.id, entry.embedding)
      end

      {:ok, state}
    end

    @impl true
    def fetch(%{entries: table}, id) do
      case :ets.lookup(table, id) do
        [{^id, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def delete(%{collection: collection, entries: table} = state, id) do
      :ets.delete(table, id)
      :ok = Zvec.delete(collection, id)
      {:ok, state}
    end

    @impl true
    def update(%{collection: collection, entries: table} = state, id, updates) do
      case fetch(state, id) do
        {:ok, entry} ->
          now = DateTime.utc_now()
          updated = struct(entry, Map.put(updates, :updated_at, now))
          :ets.insert(table, {id, updated})

          if Map.has_key?(updates, :embedding) and updates.embedding do
            :ok = Zvec.delete(collection, id)
            :ok = Zvec.add(collection, id, updated.embedding)
          end

          {:ok, state}

        error ->
          error
      end
    end

    @impl true
    def search_text(%{entries: table}, query, opts) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)
      min_score = Keyword.get(opts, :min_score, 0.0)

      results =
        table
        |> all_entries()
        |> filter_by_scope(scope)
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
    def search_vector(%{collection: collection, entries: table}, embedding, opts) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)
      min_score = Keyword.get(opts, :min_score, 0.0)

      with {:ok, results} <- Zvec.search(collection, embedding, limit: limit * 2) do
        scored_entries =
          results
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

        {:ok, scored_entries}
      end
    end

    @impl true
    def list(%{entries: table}, opts) do
      scope = Keyword.get(opts, :scope, %{})

      entries =
        table
        |> all_entries()
        |> filter_by_scope(scope)

      {:ok, entries}
    end

    defp all_entries(table) do
      :ets.tab2list(table) |> Enum.map(fn {_id, entry} -> entry end)
    end

    defp filter_by_scope(entries, scope) when map_size(scope) == 0, do: entries

    defp filter_by_scope(entries, scope) when is_list(entries) do
      Enum.filter(entries, fn entry ->
        Enum.all?(scope, fn {key, value} ->
          Map.get(entry, key) == value
        end)
      end)
    end

    defp filter_by_scope(scored_entries, scope) do
      Enum.filter(scored_entries, fn {entry, _score} ->
        Enum.all?(scope, fn {key, value} ->
          Map.get(entry, key) == value
        end)
      end)
    end
  end
else
  defmodule Nous.Memory.Store.Zvec do
    @moduledoc """
    Zvec-backed memory store with HNSW/IVF vector similarity search.

    **Not available** - add `{:zvec, "~> 0.1"}` to your deps.
    """

    @behaviour Nous.Memory.Store

    @impl true
    def init(_opts) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def store(_state, _entry) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def fetch(_state, _id) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def delete(_state, _id) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def update(_state, _id, _updates) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def search_text(_state, _query, _opts) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def list(_state, _opts) do
      {:error, "Zvec is not available. Add {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end
  end
end

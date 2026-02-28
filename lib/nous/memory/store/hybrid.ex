if Code.ensure_loaded?(Muninn) and Code.ensure_loaded?(Zvec) do
  defmodule Nous.Memory.Store.Hybrid do
    @moduledoc """
    Hybrid memory store combining Muninn (full-text) and Zvec (vector) search.

    Provides both `search_text/3` (via Muninn BM25) and `search_vector/3` (via Zvec HNSW).
    Uses a shared ETS table as the source of truth for entry data.

    Requires optional deps: `{:muninn, "~> 0.4"}` and `{:zvec, "~> 0.1"}`

    ## Options

      * `:muninn_config` - map with `:index_path` for Muninn index files (required)
      * `:zvec_config` - map with `:collection_path` and optional `:embedding_dimension` (required)
    """

    @behaviour Nous.Memory.Store

    alias Nous.Memory.Entry

    @default_dimension 1536

    @impl true
    def init(opts) do
      muninn_config = Keyword.fetch!(opts, :muninn_config)
      zvec_config = Keyword.fetch!(opts, :zvec_config)

      index_path = Map.fetch!(muninn_config, :index_path)
      collection_path = Map.fetch!(zvec_config, :collection_path)
      dimension = Map.get(zvec_config, :embedding_dimension, @default_dimension)

      schema = %{id: :text, content: :text}

      with {:ok, index} <- open_or_create_index(index_path, schema),
           {:ok, collection} <- open_or_create_collection(collection_path, dimension) do
        table = :ets.new(:hybrid_store, [:set, :public])

        {:ok,
         %{
           muninn: %{index: index},
           zvec: %{collection: collection},
           entries: table
         }}
      end
    end

    @impl true
    def store(
          %{muninn: %{index: index}, zvec: %{collection: collection}, entries: table} = state,
          %Entry{} = entry
        ) do
      :ets.insert(table, {entry.id, entry})

      doc = %{id: entry.id, content: entry.content}
      :ok = Muninn.add_document(index, doc)
      :ok = Muninn.commit(index)

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
    def delete(
          %{muninn: %{index: index}, zvec: %{collection: collection}, entries: table} = state,
          id
        ) do
      :ets.delete(table, id)
      :ok = Muninn.delete_document(index, "id", id)
      :ok = Muninn.commit(index)
      :ok = Zvec.delete(collection, id)
      {:ok, state}
    end

    @impl true
    def update(
          %{muninn: %{index: index}, zvec: %{collection: collection}, entries: table} = state,
          id,
          updates
        ) do
      case fetch(state, id) do
        {:ok, entry} ->
          now = DateTime.utc_now()
          updated = struct(entry, Map.put(updates, :updated_at, now))
          :ets.insert(table, {id, updated})

          if Map.has_key?(updates, :content) do
            :ok = Muninn.delete_document(index, "id", id)
            :ok = Muninn.add_document(index, %{id: id, content: updated.content})
            :ok = Muninn.commit(index)
          end

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
    def search_text(%{muninn: %{index: index}, entries: table}, query, opts) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)
      min_score = Keyword.get(opts, :min_score, 0.0)

      with {:ok, results} <- Muninn.search(index, query, limit: limit * 2) do
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
    def search_vector(%{zvec: %{collection: collection}, entries: table}, embedding, opts) do
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

    defp open_or_create_index(path, schema) do
      case Muninn.create_index(path, schema) do
        {:ok, index} -> {:ok, index}
        {:error, _} -> Muninn.open_index(path)
      end
    end

    defp open_or_create_collection(path, dimension) do
      case Zvec.create_collection(path, dimension: dimension) do
        {:ok, collection} -> {:ok, collection}
        {:error, _} -> Zvec.open_collection(path)
      end
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
  defmodule Nous.Memory.Store.Hybrid do
    @moduledoc """
    Hybrid memory store combining Muninn (full-text) and Zvec (vector) search.

    **Not available** - add `{:muninn, "~> 0.4"}` and `{:zvec, "~> 0.1"}` to your deps.
    """

    @behaviour Nous.Memory.Store

    @impl true
    def init(_opts) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def store(_state, _entry) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def fetch(_state, _id) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def delete(_state, _id) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def update(_state, _id, _updates) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def search_text(_state, _query, _opts) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end

    @impl true
    def list(_state, _opts) do
      {:error,
       "Muninn and/or Zvec are not available. Add {:muninn, \"~> 0.4\"} and {:zvec, \"~> 0.1\"} to your mix.exs deps."}
    end
  end
end

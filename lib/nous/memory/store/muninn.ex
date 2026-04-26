if Code.ensure_loaded?(Muninn) do
  defmodule Nous.Memory.Store.Muninn do
    @moduledoc """
    Muninn-backed memory store with Tantivy full-text search (BM25).

    Uses Muninn for text indexing/search and ETS for full entry storage.
    Does not implement `search_vector/3` (text-only backend).

    Requires optional dep: `{:muninn, "~> 0.4"}`

    ## Options

      * `:index_path` - filesystem path for Muninn index files (required)
    """

    @behaviour Nous.Memory.Store

    require Logger

    alias Nous.Memory.Entry

    @impl true
    def init(opts) do
      index_path = Keyword.fetch!(opts, :index_path)

      schema = %{
        id: :text,
        content: :text
      }

      with {:ok, index} <- Muninn.create_index(index_path, schema) do
        # Unnamed table - named would crash a second concurrent agent.
        table = :ets.new(__MODULE__, [:set, :public])
        {:ok, %{index: index, entries: table}}
      end
    rescue
      e in [MatchError, File.Error, ErlangError, RuntimeError] ->
        Logger.debug(
          "Muninn index create failed (#{Exception.message(e)}), attempting to open existing index"
        )

        case Muninn.open_index(index_path) do
          {:ok, index} ->
            # Unnamed table - named would crash a second concurrent agent.
            table = :ets.new(__MODULE__, [:set, :public])
            {:ok, %{index: index, entries: table}}

          error ->
            error
        end
    end

    @impl true
    def store(%{index: index, entries: table} = state, %Entry{} = entry) do
      doc = %{id: entry.id, content: entry.content}

      with :ok <- Muninn.add_document(index, doc),
           :ok <- Muninn.commit(index) do
        # Only insert into the entry table after the index commit succeeds,
        # so a Muninn write failure leaves a consistent view (entry absent
        # from both index AND entries) instead of MatchError + desynced ETS.
        :ets.insert(table, {entry.id, entry})
        {:ok, state}
      end
    end

    @impl true
    def fetch(%{entries: table}, id) do
      case :ets.lookup(table, id) do
        [{^id, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def delete(%{index: index, entries: table} = state, id) do
      with :ok <- Muninn.delete_document(index, "id", id),
           :ok <- Muninn.commit(index) do
        :ets.delete(table, id)
        {:ok, state}
      end
    end

    @impl true
    def update(%{index: index, entries: table} = state, id, updates) do
      case fetch(state, id) do
        {:ok, entry} ->
          now = DateTime.utc_now()
          updated = struct(entry, Map.put(updates, :updated_at, now))

          if Map.has_key?(updates, :content) do
            # Re-index first; only commit ETS if Muninn succeeds.
            with :ok <- Muninn.delete_document(index, "id", id),
                 :ok <- Muninn.add_document(index, %{id: id, content: updated.content}),
                 :ok <- Muninn.commit(index) do
              :ets.insert(table, {id, updated})
              {:ok, state}
            end
          else
            :ets.insert(table, {id, updated})
            {:ok, state}
          end

        error ->
          error
      end
    end

    @impl true
    def search_text(%{index: index, entries: table}, query, opts) do
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
  defmodule Nous.Memory.Store.Muninn do
    @moduledoc """
    Muninn-backed memory store with Tantivy full-text search (BM25).

    **Not available** - add `{:muninn, "~> 0.4"}` to your deps.
    """

    @behaviour Nous.Memory.Store

    @dialyzer {:nowarn_function,
               init: 1, store: 2, fetch: 2, delete: 2, update: 3, search_text: 3, list: 2}

    @impl true
    def init(_opts) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end

    @impl true
    def store(_state, _entry) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end

    @impl true
    def fetch(_state, _id) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end

    @impl true
    def delete(_state, _id) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end

    @impl true
    def update(_state, _id, _updates) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end

    @impl true
    def search_text(_state, _query, _opts) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end

    @impl true
    def list(_state, _opts) do
      {:error, "Muninn is not available. Add {:muninn, \"~> 0.4\"} to your mix.exs deps."}
    end
  end
end

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
    alias Nous.Memory.Store.Results

    @impl true
    def init(opts) do
      index_path = Keyword.fetch!(opts, :index_path)

      schema = %{
        id: :text,
        content: :text
      }

      # Explicit `try` rather than a function-level `rescue`: the rescue clause
      # needs `index_path`, and a function-level rescue cannot see variables
      # bound in the function body. As written before this it was a hard
      # "undefined variable" compile error — invisible here because the whole
      # arm sits behind `Code.ensure_loaded?(Muninn)` and `muninn` is not
      # installed, so adding the dep would have broken the build.
      try do
        with {:ok, index} <- Muninn.create_index(index_path, schema) do
          # Unnamed table - named would crash a second concurrent agent.
          # read_concurrency: the entries table is a read-side cache for search
          # hydration; writes are one insert per stored entry.
          table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
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
              # read_concurrency for the same reason as the create path above.
              table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
              {:ok, %{index: index, entries: table}}

            error ->
              error
          end
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
    def update(state, id, updates) do
      case fetch(state, id) do
        {:ok, entry} ->
          updated = struct(entry, Map.put(updates, :updated_at, DateTime.utc_now()))
          commit_update(state, id, updated, Map.has_key?(updates, :content))

        error ->
          error
      end
    end

    # Content changed, so the full-text index has to change with it: re-index
    # first and only commit the ETS row if Muninn succeeds, otherwise a failed
    # re-index leaves the index describing content the table no longer holds.
    defp commit_update(%{index: index, entries: table} = state, id, updated, true) do
      with :ok <- Muninn.delete_document(index, "id", id),
           :ok <- Muninn.add_document(index, %{id: id, content: updated.content}),
           :ok <- Muninn.commit(index) do
        :ets.insert(table, {id, updated})
        {:ok, state}
      end
    end

    defp commit_update(%{entries: table} = state, id, updated, false) do
      :ets.insert(table, {id, updated})
      {:ok, state}
    end

    @impl true
    def search_text(%{index: index, entries: table}, query, opts) do
      scope = Keyword.get(opts, :scope, %{})
      limit = Keyword.get(opts, :limit, 10)
      min_score = Keyword.get(opts, :min_score, 0.0)

      with {:ok, results} <- Muninn.search(index, query, limit: limit * 2) do
        {:ok, Results.rank(results, table, scope, min_score, limit)}
      end
    end

    @impl true
    def list(%{entries: table}, opts) do
      scope = Keyword.get(opts, :scope, %{})
      {:ok, table |> Results.all_entries() |> Results.filter_by_scope(scope)}
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

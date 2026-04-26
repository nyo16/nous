defmodule Nous.KnowledgeBase.Store.ETS do
  @moduledoc """
  ETS-backed knowledge base store implementation.

  Uses three unnamed ETS tables (documents, entries, links) so multiple
  instances can coexist. Text search uses `String.jaro_distance/2` for
  fuzzy matching on entry content and title.
  """

  @behaviour Nous.KnowledgeBase.Store

  alias Nous.KnowledgeBase.{Document, Entry, Link}

  @type state :: %{
          documents: :ets.table(),
          entries: :ets.table(),
          links: :ets.table()
        }

  @impl true
  def init(_opts) do
    state = %{
      documents: :ets.new(:kb_documents, [:set, :public]),
      entries: :ets.new(:kb_entries, [:set, :public]),
      links: :ets.new(:kb_links, [:set, :public])
    }

    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Document CRUD
  # ---------------------------------------------------------------------------

  @impl true
  def store_document(state, %Document{} = doc) do
    :ets.insert(state.documents, {doc.id, doc})
    {:ok, state}
  end

  @impl true
  def fetch_document(state, id) do
    case :ets.lookup(state.documents, id) do
      [{^id, doc}] -> {:ok, doc}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def update_document(state, id, updates) do
    case fetch_document(state, id) do
      {:ok, doc} ->
        now = DateTime.utc_now()
        updated = struct(doc, Map.put(updates, :updated_at, now))
        :ets.insert(state.documents, {id, updated})
        {:ok, state}

      error ->
        error
    end
  end

  @impl true
  def list_documents(state, opts) do
    kb_id = Keyword.get(opts, :kb_id)
    status = Keyword.get(opts, :status)

    docs =
      state.documents
      |> all_records()
      |> filter_by_kb_id(kb_id)
      |> maybe_filter(fn doc -> is_nil(status) || doc.status == status end)

    {:ok, docs}
  end

  @impl true
  def delete_document(state, id) do
    :ets.delete(state.documents, id)
    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Entry CRUD + search
  # ---------------------------------------------------------------------------

  @impl true
  def store_entry(state, %Entry{} = entry) do
    :ets.insert(state.entries, {entry.id, entry})
    {:ok, state}
  end

  @impl true
  def fetch_entry(state, id) do
    case :ets.lookup(state.entries, id) do
      [{^id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def fetch_entry_by_slug(state, slug) do
    result =
      state.entries
      |> all_records()
      |> Enum.find(fn entry -> entry.slug == slug end)

    case result do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @impl true
  def update_entry(state, id, updates) do
    case fetch_entry(state, id) do
      {:ok, entry} ->
        now = DateTime.utc_now()
        updated = struct(entry, Map.put(updates, :updated_at, now))
        :ets.insert(state.entries, {id, updated})
        {:ok, state}

      error ->
        error
    end
  end

  @impl true
  def delete_entry(state, id) do
    :ets.delete(state.entries, id)
    {:ok, state}
  end

  @impl true
  def list_entries(state, opts) do
    kb_id = Keyword.get(opts, :kb_id)
    tags = Keyword.get(opts, :tags)
    concepts = Keyword.get(opts, :concepts)
    entry_type = Keyword.get(opts, :entry_type)
    limit = Keyword.get(opts, :limit)

    entries =
      state.entries
      |> all_records()
      |> filter_by_kb_id(kb_id)
      |> maybe_filter(fn entry -> is_nil(entry_type) || entry.entry_type == entry_type end)
      |> maybe_filter(fn entry ->
        is_nil(tags) || Enum.any?(tags, &(&1 in entry.tags))
      end)
      |> maybe_filter(fn entry ->
        is_nil(concepts) || Enum.any?(concepts, &(&1 in entry.concepts))
      end)
      |> maybe_take(limit)

    {:ok, entries}
  end

  @impl true
  def search_entries(state, query, opts) do
    kb_id = Keyword.get(opts, :kb_id)
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    query_down = String.downcase(query)

    results =
      state.entries
      |> all_records()
      |> filter_by_kb_id(kb_id)
      |> Enum.map(fn entry ->
        # Score against both title and content for better matching
        title_score = String.jaro_distance(query_down, String.downcase(entry.title))
        content_score = String.jaro_distance(query_down, String.downcase(entry.content))
        # Weight title matches higher
        score = max(title_score * 1.2, content_score) |> min(1.0)
        {entry, score}
      end)
      |> Enum.filter(fn {_entry, score} -> score > min_score end)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Link CRUD + graph
  # ---------------------------------------------------------------------------

  @impl true
  def store_link(state, %Link{} = link) do
    :ets.insert(state.links, {link.id, link})
    {:ok, state}
  end

  @impl true
  def delete_link(state, id) do
    :ets.delete(state.links, id)
    {:ok, state}
  end

  @impl true
  def backlinks(state, entry_id) do
    links =
      state.links
      |> all_records()
      |> Enum.filter(fn link -> link.to_entry_id == entry_id end)

    {:ok, links}
  end

  @impl true
  def outlinks(state, entry_id) do
    links =
      state.links
      |> all_records()
      |> Enum.filter(fn link -> link.from_entry_id == entry_id end)

    {:ok, links}
  end

  @impl true
  def link_counts_by_source(state) do
    counts =
      state.links
      |> all_records()
      |> Enum.frequencies_by(& &1.from_entry_id)

    {:ok, counts}
  end

  @impl true
  def related_entries(state, entry_id, opts) do
    limit = Keyword.get(opts, :limit, 10)

    # Get all linked entry IDs (both directions)
    linked_ids =
      state.links
      |> all_records()
      |> Enum.flat_map(fn link ->
        cond do
          link.from_entry_id == entry_id -> [link.to_entry_id]
          link.to_entry_id == entry_id -> [link.from_entry_id]
          true -> []
        end
      end)
      |> Enum.uniq()

    # Fetch the actual entries
    entries =
      linked_ids
      |> Enum.map(fn id ->
        case fetch_entry(state, id) do
          {:ok, entry} -> entry
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(limit)

    {:ok, entries}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp all_records(table) do
    :ets.tab2list(table) |> Enum.map(fn {_id, record} -> record end)
  end

  defp filter_by_kb_id(records, nil), do: records

  defp filter_by_kb_id(records, kb_id) do
    Enum.filter(records, fn record -> record.kb_id == kb_id end)
  end

  defp maybe_filter(records, fun), do: Enum.filter(records, fun)

  defp maybe_take(records, nil), do: records
  defp maybe_take(records, limit), do: Enum.take(records, limit)
end

defmodule Nous.KnowledgeBase.Store.ETS do
  @moduledoc """
  ETS-backed knowledge base store implementation.

  Uses four unnamed ETS tables (documents, entries, links, slugs) so multiple
  instances can coexist. Text search uses `String.jaro_distance/2` for
  fuzzy matching on entry content and title.

  ## Ownership & lifetime (read before "fixing" the `:public` tables)

  This store is **intentionally ephemeral and run-scoped**. `init/1` returns the
  table references inside `state`, which the caller threads through `ctx.deps`
  for the life of a knowledge-base session — there is no global registration and
  no supervised owner. When the process holding `state` exits, ETS reclaims the
  tables; that is the designed lifetime, not a leak. Persistence across runs is
  the job of a different `Nous.KnowledgeBase.Store` implementation, not this one.

  The tables are `:public` on purpose: a single KB session is driven from several
  processes (the agent loop plus tool-execution tasks all receive the same
  `state` and read/write it), so a `:protected` table — writable only by the
  process that called `init/1` — would break those cross-process writes. Access
  is gated by *possession of the table reference*, which never leaves the
  session's `ctx`, rather than by an ETS access mode.

  Writes (e.g. `store_entry/2`) are sequences of individual ETS operations, not
  transactions. Operation order is chosen so a torn write degrades safely (a
  stale slug → a miss), but if you need cross-write atomicity, route writes
  through a serializing owner process instead of using this store directly.
  """

  @behaviour Nous.KnowledgeBase.Store

  alias Nous.KnowledgeBase.{Document, Entry, Link}

  @type state :: %{
          documents: :ets.table(),
          entries: :ets.table(),
          links: :ets.table(),
          slugs: :ets.table()
        }

  @impl true
  def init(_opts) do
    state = %{
      documents: :ets.new(:kb_documents, [:set, :public]),
      entries: :ets.new(:kb_entries, [:set, :public]),
      links: :ets.new(:kb_links, [:set, :public]),
      # slug -> id secondary index so fetch_entry_by_slug is O(1) instead of a
      # full table scan (slug lookup is a hot path: kb_read/backlinks/link).
      slugs: :ets.new(:kb_slugs, [:set, :public])
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
      |> scoped_records(kb_id)
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
    # Read the previous slug (if this id is being re-stored under a new one)
    # BEFORE overwriting, so we can retire the stale index entry.
    old_slug =
      case fetch_entry(state, entry.id) do
        {:ok, %Entry{slug: prev}} when prev != entry.slug -> prev
        _ -> nil
      end

    # These are separate ETS ops, not a transaction (see the moduledoc on the
    # per-run ownership model). Ordering bounds the damage of a torn write:
    # write the entry, then point the new slug at it, then drop the old slug —
    # so a live slug never references a missing id. fetch_entry_by_slug/2 also
    # tolerates a stale slug, degrading a torn write to a miss, never a wrong
    # entry.
    :ets.insert(state.entries, {entry.id, entry})
    :ets.insert(state.slugs, {entry.slug, entry.id})
    if old_slug, do: :ets.delete(state.slugs, old_slug)

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
    case :ets.lookup(state.slugs, slug) do
      # fetch_entry handles a stale index (id deleted) by returning :not_found.
      [{^slug, id}] -> fetch_entry(state, id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def update_entry(state, id, updates) do
    case fetch_entry(state, id) do
      {:ok, entry} ->
        now = DateTime.utc_now()
        updated = struct(entry, Map.put(updates, :updated_at, now))

        updated =
          if is_map_key(updates, :title) or is_map_key(updates, :content) do
            Entry.with_downcase_cache(updated)
          else
            updated
          end

        :ets.insert(state.entries, {id, updated})

        if updated.slug != entry.slug do
          :ets.delete(state.slugs, entry.slug)
          :ets.insert(state.slugs, {updated.slug, id})
        end

        {:ok, state}

      error ->
        error
    end
  end

  @impl true
  def delete_entry(state, id) do
    case fetch_entry(state, id) do
      {:ok, entry} -> :ets.delete(state.slugs, entry.slug)
      _ -> :ok
    end

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
      |> scoped_records(kb_id)
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
      |> scoped_records(kb_id)
      |> Enum.map(fn entry ->
        # Score against both title and content for better matching. The || arms
        # cover entries persisted before the *_down cache fields existed.
        title_down = entry.title_down || String.downcase(entry.title)
        content_down = entry.content_down || String.downcase(entry.content)
        title_score = String.jaro_distance(query_down, title_down)
        content_score = String.jaro_distance(query_down, content_down)
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

  # Push the kb_id filter INTO ETS via a partial-map matchspec, so a multi-KB
  # table only copies the target KB's rows instead of tab2list-copying every
  # KB's records and filtering in Elixir. nil kb_id = no scope = full copy
  # (unavoidable). Equivalent to `all_records |> filter_by_kb_id(kb_id)`.
  defp scoped_records(table, nil), do: all_records(table)

  defp scoped_records(table, kb_id) do
    table
    |> :ets.select([{{:_, %{kb_id: kb_id}}, [], [:"$_"]}])
    |> Enum.map(fn {_id, record} -> record end)
  end

  defp maybe_filter(records, fun), do: Enum.filter(records, fun)

  defp maybe_take(records, nil), do: records
  defp maybe_take(records, limit), do: Enum.take(records, limit)
end

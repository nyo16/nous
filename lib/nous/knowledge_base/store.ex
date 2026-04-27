defmodule Nous.KnowledgeBase.Store do
  @moduledoc """
  Storage behaviour for knowledge base backends.

  Defines callbacks for document, entry, and link CRUD operations
  plus search and graph traversal. Follows the same pattern as
  `Nous.Memory.Store` but with wiki-specific operations.

  All list/search callbacks accept a `:kb_id` option for scoping.

  ## State threading caveat

  Several call sites (`kb_link`, `persist_to_store`) read `store_state`
  once and reuse it across multiple write callbacks. This is safe for
  backends where `state` is a mutable handle (the included ETS impl,
  any process-wrapped backend) but **NOT** for purely-functional stores
  that depend on threading the new state through every call. New
  backends must either:

    * use mutable handles in `state` (ETS / process registry / database
      connection ref), OR
    * implement their own concurrency control / write log (the kb code
      cannot guarantee atomicity across multi-step operations).

  This contract may tighten in a future version; for now, prefer
  mutable-handle backends.
  """

  alias Nous.KnowledgeBase.{Document, Entry, Link}

  # --- Document CRUD ---

  @callback init(opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @callback store_document(state :: term(), doc :: Document.t()) ::
              {:ok, term()} | {:error, term()}

  @callback fetch_document(state :: term(), id :: String.t()) ::
              {:ok, Document.t()} | {:error, :not_found}

  @callback update_document(state :: term(), id :: String.t(), updates :: map()) ::
              {:ok, term()} | {:error, term()}

  @callback list_documents(state :: term(), opts :: keyword()) :: {:ok, [Document.t()]}

  @callback delete_document(state :: term(), id :: String.t()) ::
              {:ok, term()} | {:error, term()}

  # --- Entry CRUD + search ---

  @callback store_entry(state :: term(), entry :: Entry.t()) ::
              {:ok, term()} | {:error, term()}

  @callback fetch_entry(state :: term(), id :: String.t()) ::
              {:ok, Entry.t()} | {:error, :not_found}

  @callback fetch_entry_by_slug(state :: term(), slug :: String.t()) ::
              {:ok, Entry.t()} | {:error, :not_found}

  @callback update_entry(state :: term(), id :: String.t(), updates :: map()) ::
              {:ok, term()} | {:error, term()}

  @callback delete_entry(state :: term(), id :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @callback list_entries(state :: term(), opts :: keyword()) :: {:ok, [Entry.t()]}

  @callback search_entries(state :: term(), query :: String.t(), opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}

  # --- Link CRUD + graph ---

  @callback store_link(state :: term(), link :: Link.t()) ::
              {:ok, term()} | {:error, term()}

  @callback delete_link(state :: term(), id :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @callback backlinks(state :: term(), entry_id :: String.t()) :: {:ok, [Link.t()]}

  @callback outlinks(state :: term(), entry_id :: String.t()) :: {:ok, [Link.t()]}

  @callback related_entries(state :: term(), entry_id :: String.t(), opts :: keyword()) ::
              {:ok, [Entry.t()]}

  @doc """
  Optional bulk callback for getting all link counts grouped by source entry.

  Backends that can answer "for every entry, how many outgoing links does
  it have?" with a single scan should implement this for O(L) instead of
  O(E*L) health checks. Falls back to per-entry `outlinks/2` when not
  implemented (the default in the macro below). Returns
  `{:ok, %{entry_id => count}}`.
  """
  @callback link_counts_by_source(state :: term()) ::
              {:ok, %{optional(String.t()) => non_neg_integer()}}

  @optional_callbacks [search_entries: 3, related_entries: 3, link_counts_by_source: 1]
end

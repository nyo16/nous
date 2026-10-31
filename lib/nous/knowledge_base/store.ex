defmodule Nous.KnowledgeBase.Store do
  @moduledoc """
  Storage behaviour for knowledge base backends.

  Defines callbacks for document, entry, and link CRUD operations
  plus search and graph traversal. Follows the same pattern as
  `Nous.Memory.Store` but with wiki-specific operations.

  All list/search callbacks accept a `:kb_id` option for scoping.

  ## Namespace (`kb_id`) isolation

  The agent tools (`Nous.KnowledgeBase.Tools`) never return or modify an
  entry whose `kb_id` differs from the configured one: every point lookup
  (`fetch_entry/2`, `fetch_entry_by_slug/2`) is checked against the
  configured `kb_id` after the fetch, and a mismatch is reported as not
  found. Slugs are derived from titles, so two namespaces sharing a store
  can hold the same slug; implement the optional `fetch_entry_by_slug/3`
  so a lookup finds the entry in the caller's namespace rather than
  whichever namespace last wrote that slug.

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

  @doc """
  Optional scoped variant of `fetch_entry_by_slug/2`.

  Accepts a `:kb_id` option and returns only an entry in that namespace
  (`{:error, :not_found}` otherwise), even when another namespace in the same
  store holds an entry with the same slug. A `nil` (or absent) `:kb_id` means
  no scope. When not implemented, the tools fall back to
  `fetch_entry_by_slug/2` and reject a result from another namespace.
  """
  @callback fetch_entry_by_slug(state :: term(), slug :: String.t(), opts :: keyword()) ::
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
  Optional bulk callback: every link as `{from_entry_id, to_entry_id}`.

  The health check (`kb_health_check`) and the health workflow scope links
  to one knowledge base by keeping only pairs with both ends among its
  entries. A backend that can list the pairs in a single scan should
  implement this. Without it they call `outlinks/2` once per entry of the
  knowledge base, which is O(entries × links) on a backend whose
  `outlinks/2` scans the link table.
  """
  @callback link_endpoints(state :: term()) ::
              {:ok, [{from_entry_id :: String.t(), to_entry_id :: String.t()}]}

  @optional_callbacks [
    search_entries: 3,
    related_entries: 3,
    link_endpoints: 1,
    fetch_entry_by_slug: 3
  ]
end

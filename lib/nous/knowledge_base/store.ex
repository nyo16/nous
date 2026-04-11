defmodule Nous.KnowledgeBase.Store do
  @moduledoc """
  Storage behaviour for knowledge base backends.

  Defines callbacks for document, entry, and link CRUD operations
  plus search and graph traversal. Follows the same pattern as
  `Nous.Memory.Store` but with wiki-specific operations.

  All list/search callbacks accept a `:kb_id` option for scoping.
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

  @optional_callbacks [search_entries: 3, related_entries: 3]
end

defmodule Nous.Memory.Store do
  @moduledoc """
  Storage behaviour for memory backends.

  All search/list callbacks accept a :scope option (map of scoping fields to filter by).
  """

  alias Nous.Memory.Entry

  @callback init(opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback store(state :: term(), entry :: Entry.t()) :: {:ok, term()} | {:error, term()}
  @callback fetch(state :: term(), id :: String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  @callback delete(state :: term(), id :: String.t()) :: {:ok, term()} | {:error, term()}
  @doc """
  Applies `updates` to the entry identified by `id`.

  Returns `{:error, :not_found}` when no entry has that id.

  ## Unknown fields raise

  A key of `updates` that is not a `Nous.Memory.Entry` field is a **caller
  bug**, not a missing row, and backends that map fields onto SQL identifiers
  (`Nous.Memory.Store.SQLite`, `Nous.Memory.Store.DuckDB`) MUST raise
  `ArgumentError` for one rather than return an error tuple. The allowlist
  those backends check is an injection control, and it is validated *before*
  the row lookup, so an update carrying both an unknown field and an unknown
  id raises — it does not return `{:error, :not_found}`. Validating ahead of
  the lookup is also what keeps the control reachable without a live driver.

  Backends that do not build SQL (`Nous.Memory.Store.ETS` and friends) apply
  `struct/2` semantics and are not required to raise.
  """
  @callback update(state :: term(), id :: String.t(), updates :: map()) ::
              {:ok, term()} | {:error, term()}
  @callback search_text(state :: term(), query :: String.t(), opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}
  @callback search_vector(state :: term(), embedding :: [float()], opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}
  @callback list(state :: term(), opts :: keyword()) :: {:ok, [Entry.t()]}

  @optional_callbacks [search_vector: 3]
end

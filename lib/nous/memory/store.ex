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
  @callback update(state :: term(), id :: String.t(), updates :: map()) ::
              {:ok, term()} | {:error, term()}
  @callback search_text(state :: term(), query :: String.t(), opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}
  @callback search_vector(state :: term(), embedding :: [float()], opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}
  @callback list(state :: term(), opts :: keyword()) :: {:ok, [Entry.t()]}

  @optional_callbacks [search_vector: 3]
end

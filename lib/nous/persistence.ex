defmodule Nous.Persistence do
  @moduledoc ~S"""
  Behaviour for pluggable persistence backends.

  Implement this behaviour to store and retrieve serialized agent contexts.
  See `Nous.Persistence.ETS` for a reference implementation.

  ## Example

      defmodule MyApp.RedisPersistence do
        @behaviour Nous.Persistence

        @impl true
        def save(session_id, data) do
          Redix.command(:redix, ["SET", "nous:#{session_id}", Jason.encode!(data)])
          :ok
        end

        @impl true
        def load(session_id) do
          case Redix.command(:redix, ["GET", "nous:#{session_id}"]) do
            {:ok, nil} -> {:error, :not_found}
            {:ok, json} -> {:ok, Jason.decode!(json, keys: :atoms)}
          end
        end

        @impl true
        def delete(session_id) do
          Redix.command(:redix, ["DEL", "nous:#{session_id}"])
          :ok
        end

        @impl true
        def list do
          {:ok, keys} = Redix.command(:redix, ["KEYS", "nous:*"])
          {:ok, Enum.map(keys, &String.replace_prefix(&1, "nous:", ""))}
        end
      end

  """

  @doc "Save serialized context data for a session."
  @callback save(session_id :: String.t(), data :: map()) :: :ok | {:error, term()}

  @doc "Load serialized context data for a session."
  @callback load(session_id :: String.t()) ::
              {:ok, map()} | {:error, :not_found} | {:error, term()}

  @doc "Delete persisted data for a session."
  @callback delete(session_id :: String.t()) :: :ok | {:error, term()}

  @doc "List all persisted session IDs."
  @callback list() :: {:ok, [String.t()]} | {:error, term()}
end

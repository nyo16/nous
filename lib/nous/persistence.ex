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
          Redix.command(:redix, ["SET", "nous:#{session_id}", JSON.encode!(data)])
          :ok
        end

        @impl true
        def load(session_id) do
          case Redix.command(:redix, ["GET", "nous:#{session_id}"]) do
            {:ok, nil} -> {:error, :not_found}
            # Guarded key decode. `String.to_existing_atom/1` would raise on a
            # key written by an older release, crashing every load from then on.
            {:ok, json} -> {:ok, json |> JSON.decode!() |> Nous.Persistence.decode_keys()}
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

  @doc """
  Convert a persisted map's string keys to the atom keys `c:load/1` returns.

  Backends that serialize to a string-keyed format — JSON, MessagePack, Redis
  hashes — need this on the way back in. `c:save/1` receives an atom-keyed map
  and `c:load/1` must hand one back, so the round trip has to re-key.

  Only top-level keys are converted; values are returned untouched.

  ## Why not `String.to_existing_atom/1`

  Two failure modes, both of which this avoids:

    * A key whose atom is not loaded raises `ArgumentError`. One stale key
      written by an older release would crash every subsequent load of that
      session. Such keys are left as binaries instead, which downstream casts
      ignore.

    * Persisted blobs are attacker-reachable, so `String.to_atom/1` is never
      an option either: atoms are not garbage collected, and minting them from
      stored data is a node-wide denial of service.

  ## Examples

      iex> Nous.Persistence.decode_keys(%{"session_id" => "abc"})
      %{session_id: "abc"}

      iex> Nous.Persistence.decode_keys(%{"no_such_persisted_key_xyz" => 1})
      %{"no_such_persisted_key_xyz" => 1}

  """
  @spec decode_keys(map()) :: map()
  def decode_keys(data) when is_map(data), do: Nous.Util.atomize_keys(data)
end

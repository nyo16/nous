defmodule Nous.Memory.Scope do
  @moduledoc """
  Shared scope-building logic for memory operations.

  Both `Nous.Plugins.Memory` and `Nous.Memory.Tools` need to resolve a scope
  from config. This module extracts that common pattern.
  """

  @doc """
  Build a scope map from config based on the `:default_search_scope` setting.

  Returns `:global` or a map of scoping fields extracted from `config`.
  """
  @spec build(map()) :: :global | map()
  def build(config) do
    case config[:default_search_scope] do
      :global -> :global
      :session -> from_fields(config, [:agent_id, :session_id, :user_id])
      :user -> from_fields(config, [:user_id])
      _agent_or_default -> from_fields(config, [:agent_id, :user_id])
    end
  end

  @doc """
  Build a scope map from specific fields in config.

  Returns `:global` if no fields have values.
  """
  @spec from_fields(map(), [atom()]) :: :global | map()
  def from_fields(config, fields) do
    fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(config, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> :global
      scope -> scope
    end
  end

  @doc """
  Fetch the entry `id` from the store, but only if it lies inside `scope`
  (as returned by `build/1`).

  An entry outside the scope is reported as `{:error, :not_found}`, the same
  as a missing one, so a caller acting on a model-supplied id can neither
  touch nor confirm the existence of another scope's memory. Any other store
  error is passed through.
  """
  @spec fetch_in_scope(module(), term(), String.t(), :global | map()) ::
          {:ok, Nous.Memory.Entry.t()} | {:error, term()}
  def fetch_in_scope(store_mod, store_state, id, scope) do
    case store_mod.fetch(store_state, id) do
      {:ok, entry} -> if contains?(scope, entry), do: {:ok, entry}, else: {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Whether `entry` lies inside `scope`: every scope field equals the entry's
  field, the same exact-match filter the stores apply to `scope:` in
  `search_text/3` and `list/2`. `:global` contains every entry.
  """
  @spec contains?(:global | map(), Nous.Memory.Entry.t()) :: boolean()
  def contains?(:global, _entry), do: true

  def contains?(scope, entry) when is_map(scope) do
    Enum.all?(scope, fn {field, value} -> Map.get(entry, field) == value end)
  end
end

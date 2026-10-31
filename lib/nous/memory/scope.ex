defmodule Nous.Memory.Scope do
  @moduledoc """
  Shared scope-building logic for memory operations.

  Both `Nous.Plugins.Memory` and `Nous.Memory.Tools` need to resolve a scope
  from config. This module extracts that common pattern.

  ## Namespace is a partition

  `:default_search_scope` picks which of `:agent_id`, `:session_id` and
  `:user_id` narrow a search. `:namespace` is not one of those levels: when it
  is configured it is added to the scope in every mode, explicit `:global`
  included, so recall, auto-inject, `forget` and the auto-update reflection
  never see or touch another namespace's memories. `:global` only drops the
  agent/session/user narrowing inside the namespace.

  ## Unscoped config is global

  When neither `:namespace` nor any field the mode uses has a value (for
  instance a config with no scope fields at all, or only `:session_id` under
  the default `:agent` mode), `build/1` returns `:global`: every entry in the
  store is in scope, for recall and for `forget`/reflection update and forget
  alike. That is the intended single-tenant default. A store shared by several
  users, agents or tenants must set the mode's scope field or `:namespace` on
  every config that uses it.
  """

  @doc """
  Build a scope map from config based on the `:default_search_scope` setting.

  Returns `:global` or a map of scoping fields extracted from `config`.
  `:namespace`, when set, is part of the map in every mode (see the
  moduledoc), so `:global` is returned only when neither the mode's fields nor
  `:namespace` have a value.
  """
  @spec build(map()) :: :global | map()
  def build(config) do
    fields =
      case config[:default_search_scope] do
        :global -> []
        :session -> [:agent_id, :session_id, :user_id]
        :user -> [:user_id]
        _agent_or_default -> [:agent_id, :user_id]
      end

    from_fields(config, fields ++ [:namespace])
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

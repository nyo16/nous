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
end

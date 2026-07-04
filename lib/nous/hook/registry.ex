defmodule Nous.Hook.Registry do
  @moduledoc """
  Storage and lookup for hooks, indexed by event type.

  The registry maintains hooks sorted by priority within each event type.
  It provides efficient lookup with optional tool name matching for
  `:pre_tool_use` and `:post_tool_use` events.

  ## Example

      registry = Nous.Hook.Registry.new()
      |> Nous.Hook.Registry.register(%Nous.Hook{
        event: :pre_tool_use,
        matcher: "delete_file",
        type: :function,
        handler: fn _, _ -> :deny end
      })

      hooks = Nous.Hook.Registry.hooks_for(registry, :pre_tool_use, %{tool_name: "delete_file"})
  """

  alias __MODULE__
  alias Nous.Hook

  @type t :: %Registry{
          hooks: %{Hook.event() => [Hook.t()]}
        }

  defstruct hooks: %{}

  @doc """
  Create an empty registry.
  """
  @spec new() :: t()
  def new, do: %Registry{}

  @doc """
  Create a registry from a list of hooks.
  """
  @spec from_hooks([Hook.t()]) :: t()
  def from_hooks(hooks) when is_list(hooks) do
    Enum.reduce(hooks, new(), &register(&2, &1))
  end

  @doc """
  Register a hook in the registry.

  Hooks are stored sorted by priority (lower = earlier execution).
  """
  @spec register(t(), Hook.t()) :: t()
  def register(%Registry{} = registry, %Hook{} = hook) do
    hooks_for_event = Map.get(registry.hooks, hook.event, [])

    updated =
      [hook | hooks_for_event]
      |> Enum.sort_by(& &1.priority)

    %{registry | hooks: Map.put(registry.hooks, hook.event, updated)}
  end

  @doc """
  Register multiple hooks at once.
  """
  @spec register_all(t(), [Hook.t()]) :: t()
  def register_all(%Registry{} = registry, hooks) when is_list(hooks) do
    Enum.reduce(hooks, registry, &register(&2, &1))
  end

  @doc """
  Get all hooks for a given event type.
  """
  @spec hooks_for(t(), Hook.event()) :: [Hook.t()]
  def hooks_for(%Registry{} = registry, event) do
    Map.get(registry.hooks, event, [])
  end

  @doc """
  Get hooks for a given event type that match the payload.

  For `:pre_tool_use` and `:post_tool_use`, filters by tool name matching.
  For other events, returns all hooks for that event.
  """
  @spec hooks_for(t(), Hook.event(), map()) :: [Hook.t()]
  def hooks_for(%Registry{} = registry, event, payload) do
    registry
    |> hooks_for(event)
    |> Enum.filter(&Hook.matches?(&1, payload))
  end

  @doc """
  Check if the registry has any hooks for a given event.
  """
  @spec has_hooks?(t(), Hook.event()) :: boolean()
  def has_hooks?(%Registry{} = registry, event) do
    case Map.get(registry.hooks, event) do
      nil -> false
      [] -> false
      _ -> true
    end
  end

  @doc """
  Return the total number of registered hooks.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%Registry{} = registry) do
    registry.hooks
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
  end
end

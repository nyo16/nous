defmodule Nous.Workflow.Edge do
  @moduledoc """
  A directed edge connecting two nodes in a workflow graph.

  Edges define execution flow between nodes. They can be unconditional
  (sequential), conditional (evaluated against workflow state), or
  default (fallback when no conditional edge matches).

  ## Edge Types

  | Type | Behavior |
  |------|----------|
  | `:sequential` | Always followed (A -> B) |
  | `:conditional` | Followed when `condition.(state)` returns `true` |
  | `:default` | Followed when no sibling conditional edges match |

  ## Examples

      Nous.Workflow.Edge.new(%{
        from_id: "search",
        to_id: "synthesize",
        type: :sequential
      })

      Nous.Workflow.Edge.new(%{
        from_id: "evaluate",
        to_id: "publish",
        type: :conditional,
        condition: fn state -> state.data.quality >= 0.8 end
      })
  """

  @type edge_type :: :sequential | :conditional | :default

  @type t :: %__MODULE__{
          id: String.t(),
          from_id: String.t(),
          to_id: String.t(),
          type: edge_type(),
          condition: (Nous.Workflow.State.t() -> boolean()) | nil,
          label: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :from_id,
    :to_id,
    :condition,
    :label,
    type: :sequential,
    metadata: %{}
  ]

  @doc """
  Create a new workflow edge.

  Required: `:from_id` and `:to_id`.

  ## Examples

      iex> edge = Nous.Workflow.Edge.new(%{from_id: "a", to_id: "b"})
      iex> edge.type
      :sequential
      iex> is_binary(edge.id)
      true

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id) || generate_id(),
      from_id: attrs |> Map.fetch!(:from_id) |> to_string(),
      to_id: attrs |> Map.fetch!(:to_id) |> to_string(),
      type: Map.get(attrs, :type, :sequential),
      condition: Map.get(attrs, :condition),
      label: Map.get(attrs, :label),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

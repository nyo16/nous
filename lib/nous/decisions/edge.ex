defmodule Nous.Decisions.Edge do
  @moduledoc """
  A directed edge connecting two nodes in the decision graph.

  Edges encode the relationships between decision nodes: which options
  were chosen, what actions lead to which outcomes, and how decisions
  supersede or depend on one another.

  ## Architecture

  Edges are plain structs stored alongside nodes in a `Nous.Decisions.Store`
  backend. Each edge has a typed relationship (`edge_type`) and connects
  a source node (`from_id`) to a destination node (`to_id`).

  ## Quick Start

      edge = Nous.Decisions.Edge.new(%{
        from_id: goal_node.id,
        to_id: decision_node.id,
        edge_type: :leads_to
      })

  ## Fields

  | Field | Type | Description |
  |-------|------|-------------|
  | `id` | `String.t()` | Unique identifier (auto-generated) |
  | `from_id` | `String.t()` | Source node ID |
  | `to_id` | `String.t()` | Destination node ID |
  | `edge_type` | `edge_type()` | Relationship type |
  | `metadata` | `map()` | Arbitrary key-value data |
  | `created_at` | `DateTime.t()` | When the edge was created |
  """

  @type edge_type ::
          :leads_to | :chosen | :rejected | :requires | :blocks | :enables | :supersedes

  @type t :: %__MODULE__{
          id: String.t(),
          from_id: String.t(),
          to_id: String.t(),
          edge_type: edge_type(),
          metadata: map(),
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :from_id,
    :to_id,
    :edge_type,
    metadata: %{},
    created_at: nil
  ]

  @doc """
  Create a new edge with auto-generated ID and timestamp.

  Required: `:from_id`, `:to_id`, and `:edge_type`.

  ## Examples

      iex> edge = Nous.Decisions.Edge.new(%{from_id: "a", to_id: "b", edge_type: :leads_to})
      iex> edge.edge_type
      :leads_to
      iex> is_binary(edge.id)
      true

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = Map.get(attrs, :id) || generate_id()

    %__MODULE__{
      id: id,
      from_id: Map.fetch!(attrs, :from_id),
      to_id: Map.fetch!(attrs, :to_id),
      edge_type: Map.fetch!(attrs, :edge_type),
      metadata: Map.get(attrs, :metadata, %{}),
      created_at: Map.get(attrs, :created_at, now)
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

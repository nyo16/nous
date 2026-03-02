defmodule Nous.Decisions.Node do
  @moduledoc """
  A node in the decision graph.

  Nodes represent discrete elements of an agent's decision-making process:
  goals, decisions, options, actions, outcomes, observations, and revisits.

  ## Architecture

  Nodes are plain structs with auto-generated IDs and timestamps. They are
  stored in a `Nous.Decisions.Store` backend and connected by `Nous.Decisions.Edge`
  structs to form a directed graph.

  ## Quick Start

      node = Nous.Decisions.Node.new(%{
        type: :goal,
        label: "Implement authentication",
        confidence: 0.9
      })

  ## Fields

  | Field | Type | Description |
  |-------|------|-------------|
  | `id` | `String.t()` | Unique identifier (auto-generated) |
  | `type` | `node_type()` | Category of this node |
  | `label` | `String.t()` | Human-readable description |
  | `status` | `status()` | Current lifecycle status |
  | `confidence` | `float() \\| nil` | Agent's confidence level 0.0-1.0 |
  | `metadata` | `map()` | Arbitrary key-value data |
  | `rationale` | `String.t() \\| nil` | Explanation for this node's existence or state |
  | `created_at` | `DateTime.t()` | When the node was created |
  | `updated_at` | `DateTime.t()` | When the node was last modified |
  """

  @type node_type :: :goal | :decision | :option | :action | :outcome | :observation | :revisit
  @type status :: :active | :completed | :superseded | :rejected

  @type t :: %__MODULE__{
          id: String.t(),
          type: node_type(),
          label: String.t(),
          status: status(),
          confidence: float() | nil,
          metadata: map(),
          rationale: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :type,
    :label,
    :confidence,
    :rationale,
    status: :active,
    metadata: %{},
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Create a new node with auto-generated ID and timestamps.

  ## Options

  All fields except `:id`, `:created_at`, and `:updated_at` can be provided.
  Required: `:type` and `:label`.

  ## Examples

      iex> node = Nous.Decisions.Node.new(%{type: :goal, label: "Ship v1.0"})
      iex> node.type
      :goal
      iex> node.status
      :active
      iex> is_binary(node.id)
      true

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = Map.get(attrs, :id) || generate_id()

    %__MODULE__{
      id: id,
      type: Map.fetch!(attrs, :type),
      label: Map.fetch!(attrs, :label),
      status: Map.get(attrs, :status, :active),
      confidence: Map.get(attrs, :confidence),
      metadata: Map.get(attrs, :metadata, %{}),
      rationale: Map.get(attrs, :rationale),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

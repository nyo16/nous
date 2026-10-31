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

  alias __MODULE__

  @type node_type :: :goal | :decision | :option | :action | :outcome | :observation | :revisit
  @type status :: :active | :completed | :superseded | :rejected

  @type t :: %Node{
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

    %Node{
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

  @updatable_fields [
    :type,
    :label,
    :status,
    :confidence,
    :rationale,
    :metadata,
    :created_at,
    :updated_at
  ]

  @doc """
  Fields a store's `update_node/3` accepts (atom keys only; `:id` is immutable).
  """
  @spec updatable_fields() :: [atom()]
  def updatable_fields, do: @updatable_fields

  @doc """
  Validate an `update_node/3` updates map. Raises `ArgumentError` on any key
  that is not in `updatable_fields/0` (including string keys), so every store
  rejects unknown fields before touching storage.
  """
  @spec validate_updates!(map()) :: :ok
  def validate_updates!(updates) when is_map(updates) do
    Enum.each(updates, fn {key, _} ->
      unless key in @updatable_fields do
        raise ArgumentError,
              "unknown decision node field #{inspect(key)} — not in the allowlist " <>
                "(#{Enum.map_join(@updatable_fields, ", ", &inspect/1)})"
      end
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

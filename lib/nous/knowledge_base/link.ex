defmodule Nous.KnowledgeBase.Link do
  @moduledoc """
  A directed edge in the wiki graph between two entries.

  Links represent relationships like backlinks, cross-references,
  concept connections, and parent-child hierarchies.
  """

  @type link_type :: :backlink | :cross_reference | :concept | :see_also | :parent_child

  @type t :: %__MODULE__{
          id: String.t(),
          from_entry_id: String.t(),
          to_entry_id: String.t(),
          link_type: link_type(),
          label: String.t() | nil,
          weight: float(),
          kb_id: String.t() | nil,
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :from_entry_id,
    :to_entry_id,
    :label,
    :kb_id,
    link_type: :cross_reference,
    weight: 1.0,
    created_at: nil
  ]

  @doc """
  Creates a new Link from attributes.

  Requires `:from_entry_id` and `:to_entry_id`.
  """
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id) || generate_id(),
      from_entry_id: Map.fetch!(attrs, :from_entry_id),
      to_entry_id: Map.fetch!(attrs, :to_entry_id),
      link_type: Map.get(attrs, :link_type, :cross_reference),
      label: Map.get(attrs, :label),
      weight: Map.get(attrs, :weight, 1.0),
      kb_id: Map.get(attrs, :kb_id),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

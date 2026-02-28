defmodule Nous.Memory.Entry do
  @moduledoc """
  Memory entry struct with scoping fields for flexible isolation.
  """

  @type memory_type :: :semantic | :episodic | :procedural

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          type: memory_type(),
          importance: float(),
          evergreen: boolean(),
          embedding: [float()] | nil,
          metadata: map(),
          access_count: non_neg_integer(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          user_id: String.t() | nil,
          namespace: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_accessed_at: DateTime.t()
        }

  defstruct [
    :id,
    :content,
    :embedding,
    :agent_id,
    :session_id,
    :user_id,
    :namespace,
    type: :semantic,
    importance: 0.5,
    evergreen: false,
    metadata: %{},
    access_count: 0,
    created_at: nil,
    updated_at: nil,
    last_accessed_at: nil
  ]

  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = Map.get(attrs, :id) || generate_id()

    %__MODULE__{
      id: id,
      content: Map.fetch!(attrs, :content),
      type: Map.get(attrs, :type, :semantic),
      importance: Map.get(attrs, :importance, 0.5),
      evergreen: Map.get(attrs, :evergreen, false),
      embedding: Map.get(attrs, :embedding),
      metadata: Map.get(attrs, :metadata, %{}),
      access_count: 0,
      agent_id: Map.get(attrs, :agent_id),
      session_id: Map.get(attrs, :session_id),
      user_id: Map.get(attrs, :user_id),
      namespace: Map.get(attrs, :namespace),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now),
      last_accessed_at: Map.get(attrs, :last_accessed_at, now)
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

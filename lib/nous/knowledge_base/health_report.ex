defmodule Nous.KnowledgeBase.HealthReport do
  @moduledoc """
  Result of a health check audit on the knowledge base.

  Contains statistics, scores, and identified issues for maintenance.
  """

  @type issue_type :: :stale | :inconsistent | :orphan | :gap | :low_confidence | :duplicate
  @type severity :: :low | :medium | :high

  @type issue :: %{
          type: issue_type(),
          entry_id: String.t() | nil,
          description: String.t(),
          severity: severity(),
          suggested_action: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kb_id: String.t() | nil,
          total_entries: non_neg_integer(),
          total_links: non_neg_integer(),
          total_documents: non_neg_integer(),
          issues: [issue()],
          coverage_score: float(),
          freshness_score: float(),
          coherence_score: float(),
          created_at: DateTime.t()
        }

  defstruct [
    :id,
    :kb_id,
    total_entries: 0,
    total_links: 0,
    total_documents: 0,
    issues: [],
    coverage_score: 0.0,
    freshness_score: 0.0,
    coherence_score: 0.0,
    created_at: nil
  ]

  @doc """
  Creates a new HealthReport from attributes.
  """
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id) || generate_id(),
      kb_id: Map.get(attrs, :kb_id),
      total_entries: Map.get(attrs, :total_entries, 0),
      total_links: Map.get(attrs, :total_links, 0),
      total_documents: Map.get(attrs, :total_documents, 0),
      issues: Map.get(attrs, :issues, []),
      coverage_score: Map.get(attrs, :coverage_score, 0.0),
      freshness_score: Map.get(attrs, :freshness_score, 0.0),
      coherence_score: Map.get(attrs, :coherence_score, 0.0),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

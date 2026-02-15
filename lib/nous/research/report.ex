defmodule Nous.Research.Report do
  @moduledoc """
  Represents a completed research report with citations.
  """

  alias Nous.Research.Finding

  @type source :: %{
          url: String.t(),
          title: String.t() | nil
        }

  @type t :: %__MODULE__{
          title: String.t(),
          query: String.t(),
          content: String.t(),
          findings: [Finding.t()],
          sources: [source()],
          gaps: [String.t()],
          iterations: non_neg_integer(),
          total_tokens: non_neg_integer(),
          duration_ms: non_neg_integer(),
          completed_at: DateTime.t()
        }

  defstruct [
    :title,
    :query,
    :content,
    :completed_at,
    findings: [],
    sources: [],
    gaps: [],
    iterations: 0,
    total_tokens: 0,
    duration_ms: 0
  ]
end

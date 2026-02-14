defmodule Nous.Research.Finding do
  @moduledoc """
  Represents a research finding from a search/analysis step.
  """

  @type t :: %__MODULE__{
          claim: String.t(),
          source_url: String.t() | nil,
          source_title: String.t() | nil,
          confidence: float(),
          timestamp: DateTime.t(),
          search_query: String.t() | nil
        }

  defstruct [
    :claim,
    :source_url,
    :source_title,
    :search_query,
    confidence: 0.5,
    timestamp: nil
  ]

  def new(attrs) do
    %__MODULE__{
      claim: Map.fetch!(attrs, :claim),
      source_url: Map.get(attrs, :source_url),
      source_title: Map.get(attrs, :source_title),
      confidence: Map.get(attrs, :confidence, 0.5),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
      search_query: Map.get(attrs, :search_query)
    }
  end
end

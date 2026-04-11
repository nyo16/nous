defmodule Nous.KnowledgeBase.Document do
  @moduledoc """
  A raw ingested document before compilation into wiki entries.

  Documents represent source material (markdown, text, URLs, etc.) that
  gets processed by the LLM into structured `Entry` wiki articles.
  """

  @type doc_type :: :markdown | :text | :url | :pdf | :html
  @type status :: :pending | :processing | :compiled | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          content: String.t(),
          doc_type: doc_type(),
          source_url: String.t() | nil,
          source_path: String.t() | nil,
          status: status(),
          metadata: map(),
          checksum: String.t(),
          compiled_entry_ids: [String.t()],
          kb_id: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :title,
    :content,
    :source_url,
    :source_path,
    :kb_id,
    doc_type: :markdown,
    status: :pending,
    metadata: %{},
    checksum: nil,
    compiled_entry_ids: [],
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Creates a new Document from attributes.

  Requires `:content` and `:title`. Auto-generates id, checksum, and timestamps.
  """
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = Map.get(attrs, :id) || generate_id()
    content = Map.fetch!(attrs, :content)
    title = Map.fetch!(attrs, :title)

    %__MODULE__{
      id: id,
      title: title,
      content: content,
      doc_type: Map.get(attrs, :doc_type, :markdown),
      source_url: Map.get(attrs, :source_url),
      source_path: Map.get(attrs, :source_path),
      status: Map.get(attrs, :status, :pending),
      metadata: Map.get(attrs, :metadata, %{}),
      checksum: Map.get(attrs, :checksum) || compute_checksum(content),
      compiled_entry_ids: Map.get(attrs, :compiled_entry_ids, []),
      kb_id: Map.get(attrs, :kb_id),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end

  @doc """
  Computes SHA-256 checksum of content for change detection.
  """
  def compute_checksum(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

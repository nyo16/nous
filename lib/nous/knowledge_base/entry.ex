defmodule Nous.KnowledgeBase.Entry do
  @moduledoc """
  A compiled wiki entry — the core unit of the knowledge base.

  Entries are produced by LLM compilation of raw `Document`s. They contain
  structured markdown with `[[wiki-links]]`, summaries, extracted concepts,
  and metadata for search and graph traversal.
  """

  @type entry_type :: :article | :concept | :summary | :index | :glossary

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          slug: String.t(),
          content: String.t(),
          summary: String.t() | nil,
          entry_type: entry_type(),
          concepts: [String.t()],
          tags: [String.t()],
          confidence: float(),
          source_doc_ids: [String.t()],
          embedding: [float()] | nil,
          metadata: map(),
          kb_id: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_verified_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :title,
    :slug,
    :content,
    :summary,
    :embedding,
    :kb_id,
    :last_verified_at,
    entry_type: :article,
    concepts: [],
    tags: [],
    confidence: 0.5,
    source_doc_ids: [],
    metadata: %{},
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Creates a new Entry from attributes.

  Requires `:title` and `:content`. Auto-generates id, slug, and timestamps.
  """
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    id = Map.get(attrs, :id) || generate_id()
    title = Map.fetch!(attrs, :title)

    %__MODULE__{
      id: id,
      title: title,
      slug: Map.get(attrs, :slug) || slugify(title),
      content: Map.fetch!(attrs, :content),
      summary: Map.get(attrs, :summary),
      entry_type: Map.get(attrs, :entry_type, :article),
      concepts: Map.get(attrs, :concepts, []),
      tags: Map.get(attrs, :tags, []),
      confidence: Map.get(attrs, :confidence, 0.5),
      source_doc_ids: Map.get(attrs, :source_doc_ids, []),
      embedding: Map.get(attrs, :embedding),
      metadata: Map.get(attrs, :metadata, %{}),
      kb_id: Map.get(attrs, :kb_id),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now),
      last_verified_at: Map.get(attrs, :last_verified_at)
    }
  end

  @doc """
  Generates a URL-safe slug from a title.

  ## Examples

      iex> Nous.KnowledgeBase.Entry.slugify("Elixir GenServer Patterns")
      "elixir-genserver-patterns"
  """
  def slugify(title) when is_binary(title) do
    # L-3: normalise unicode to NFD and strip combining marks so accented
    # characters are preserved as their base ASCII form ("Café" -> "cafe")
    # rather than entirely stripped (the previous \w-only filter dropped
    # them). Multilingual titles still collide on slug; the Store layer
    # is responsible for slug uniqueness (see Store moduledoc).
    title
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

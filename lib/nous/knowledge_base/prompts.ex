defmodule Nous.KnowledgeBase.Prompts do
  @moduledoc """
  LLM prompt templates for knowledge base compilation, linking, auditing,
  and output generation.
  """

  @doc """
  Builds a prompt for extracting concepts from raw documents.
  """
  def extraction_prompt(documents) do
    doc_texts =
      documents
      |> Enum.with_index(1)
      |> Enum.map(fn {doc, i} ->
        """
        ### Document #{i}: #{doc.title}
        #{String.slice(doc.content, 0, 3000)}
        """
      end)
      |> Enum.join("\n")

    """
    Analyze the following documents and extract key concepts, topics, and potential wiki entry titles.

    For each potential wiki entry, provide:
    - title: A clear, descriptive title
    - concepts: Key concepts covered
    - summary: A 1-2 sentence description

    Output as a JSON array of objects with keys: title, concepts, summary.

    #{doc_texts}

    Output the JSON array only, no markdown fences.
    """
  end

  @doc """
  Builds a prompt for compiling raw documents into wiki entries.
  """
  def compilation_prompt(documents, concepts) do
    doc_texts =
      documents
      |> Enum.with_index(1)
      |> Enum.map(fn {doc, i} ->
        "### Document #{i}: #{doc.title}\n#{doc.content}"
      end)
      |> Enum.join("\n\n")

    concept_text =
      concepts
      |> Enum.map(fn c ->
        "- #{c["title"]}: #{c["summary"]}"
      end)
      |> Enum.join("\n")

    """
    You are a knowledge base curator. Compile the following source documents into \
    structured wiki entries.

    ## Source Documents
    #{doc_texts}

    ## Planned Entries
    #{concept_text}

    ## Instructions

    For each planned entry, create a wiki article with:
    1. A clear title
    2. Well-structured markdown content
    3. Use [[slug-format]] to link to other entries in the wiki
    4. A 1-3 sentence summary
    5. A list of key concepts
    6. Appropriate tags

    Output as a JSON array of objects with keys:
    - title (string)
    - slug (string, lowercase-hyphenated)
    - content (string, markdown with [[wiki-links]])
    - summary (string)
    - concepts (array of strings)
    - tags (array of strings)
    - entry_type (string: "article", "concept", "summary", "glossary")
    - confidence (float 0.0-1.0, how confident you are in the accuracy)

    Output the JSON array only, no markdown fences.
    """
  end

  @doc """
  Builds a prompt for generating links between wiki entries.
  """
  def linking_prompt(entries) do
    entry_texts =
      entries
      |> Enum.map(fn entry ->
        "- [[#{entry.slug}]] #{entry.title}: #{entry.summary || String.slice(entry.content, 0, 200)}"
      end)
      |> Enum.join("\n")

    """
    You are a knowledge base curator. Analyze these wiki entries and identify \
    meaningful relationships between them.

    ## Entries
    #{entry_texts}

    ## Instructions

    For each relationship you find, create a link with:
    - from_slug: the slug of the source entry
    - to_slug: the slug of the target entry
    - link_type: one of "cross_reference", "concept", "see_also", "parent_child"
    - label: a brief description of the relationship

    Only create links where there is a genuine conceptual connection.
    Do not create redundant bidirectional links — one direction is sufficient.

    Output as a JSON array of objects with keys: from_slug, to_slug, link_type, label.
    Output the JSON array only, no markdown fences.
    """
  end

  @doc """
  Builds a prompt for auditing the knowledge base.
  """
  def audit_prompt(stats, entry_summaries) do
    entries_text =
      entry_summaries
      |> Enum.map(fn e ->
        "- [[#{e.slug}]] #{e.title} (type: #{e.entry_type}, confidence: #{e.confidence}, links: #{e.link_count})"
      end)
      |> Enum.join("\n")

    """
    You are a knowledge base auditor. Review the following wiki and identify issues.

    ## Statistics
    - Total entries: #{stats.total_entries}
    - Total links: #{stats.total_links}
    - Total documents: #{stats.total_documents}

    ## Entries
    #{entries_text}

    ## Check For
    1. **Stale entries** — entries that may be outdated
    2. **Inconsistencies** — entries that contradict each other
    3. **Orphans** — entries with no links or source documents
    4. **Gaps** — topics that should have entries but don't
    5. **Low confidence** — entries with low confidence scores
    6. **Duplicates** — entries covering the same topic

    For each issue found, provide:
    - type: one of "stale", "inconsistent", "orphan", "gap", "low_confidence", "duplicate"
    - entry_id: the entry slug (or null for gaps)
    - description: what the issue is
    - severity: "low", "medium", or "high"
    - suggested_action: what to do about it

    Output as a JSON array of issue objects.
    Output the JSON array only, no markdown fences.
    """
  end

  @doc """
  Builds a prompt for generating an output (report/summary/slides) from entries.
  """
  def output_prompt(topic, entries, output_type) do
    entry_texts =
      entries
      |> Enum.map(fn entry ->
        "## #{entry.title}\n#{entry.content}"
      end)
      |> Enum.join("\n\n---\n\n")

    format_instructions =
      case output_type do
        :slides ->
          """
          Format as a Marp slide deck:
          - Start with YAML frontmatter: ---\\nmarp: true\\ntheme: default\\n---
          - Use --- to separate slides
          - Each slide should have a heading and 3-5 bullet points
          - Keep slides concise and visual
          """

        :report ->
          """
          Format as a comprehensive markdown report with:
          - Executive summary
          - Key findings with inline citations [[slug]]
          - Analysis and discussion
          - Conclusion
          """

        _ ->
          """
          Format as a concise summary with:
          - Key points as bullet list
          - Important concepts highlighted
          - References to source entries using [[slug]]
          """
      end

    """
    Generate a #{output_type} about "#{topic}" using the following knowledge base entries.

    ## Source Entries
    #{entry_texts}

    ## Format Instructions
    #{format_instructions}

    Generate the output now.
    """
  end
end

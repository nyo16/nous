defmodule DeepResearch.Tools.MemoryTools do
  @moduledoc """
  Tools for managing research findings, sources, and knowledge base.

  Uses `__update_context__` pattern for state persistence across agent iterations.
  """

  @doc """
  Record a new research finding with source citation.

  ## Parameters
  - content: The finding/fact discovered (required)
  - source_url: URL where this was found (required)
  - source_title: Title of the source (optional)
  - confidence: low/medium/high (default: medium)
  - sub_question: Which sub-question this answers (optional)

  ## Returns
  Map with success status and updated context.
  """
  def add_finding(ctx, args) do
    content = Map.get(args, "content", "")
    source_url = Map.get(args, "source_url", "")
    source_title = Map.get(args, "source_title", "")
    confidence = parse_confidence(Map.get(args, "confidence", "medium"))
    sub_question = Map.get(args, "sub_question")

    if content == "" do
      %{success: false, error: "content is required"}
    else
      findings = ctx.deps[:findings] || []
      sources = ctx.deps[:sources] || %{}

      finding_id = length(findings) + 1

      new_finding = %{
        id: finding_id,
        content: content,
        source_url: source_url,
        source_title: source_title,
        confidence: confidence,
        verified: false,
        sub_question: sub_question,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Track unique sources
      updated_sources =
        if source_url != "" and not Map.has_key?(sources, source_url) do
          Map.put(sources, source_url, %{
            url: source_url,
            title: source_title,
            type: :web,
            accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            relevance: 3
          })
        else
          sources
        end

      updated_findings = [new_finding | findings]

      %{
        success: true,
        finding: new_finding,
        message: "Finding ##{finding_id} recorded",
        total_findings: length(updated_findings),
        total_sources: map_size(updated_sources),
        __update_context__: %{findings: updated_findings, sources: updated_sources}
      }
    end
  end

  @doc """
  Update an existing finding (e.g., verify or update confidence).

  ## Parameters
  - id: Finding ID (required)
  - verified: Mark as verified (optional)
  - confidence: Update confidence level (optional)
  """
  def update_finding(ctx, args) do
    id = Map.get(args, "id")
    findings = ctx.deps[:findings] || []

    case Enum.find_index(findings, &(&1.id == id)) do
      nil ->
        %{success: false, error: "Finding ##{id} not found"}

      index ->
        updated =
          Enum.at(findings, index)
          |> maybe_update(:verified, Map.get(args, "verified"))
          |> maybe_update(:confidence, parse_confidence(Map.get(args, "confidence")))
          |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        updated_findings = List.replace_at(findings, index, updated)

        %{
          success: true,
          finding: updated,
          message: "Finding ##{id} updated",
          __update_context__: %{findings: updated_findings}
        }
    end
  end

  @doc """
  List all findings with optional filtering.

  ## Parameters
  - sub_question: Filter by sub-question (optional)
  - verified_only: Only show verified findings (optional, boolean)
  - confidence: Filter by confidence level (optional)
  """
  def list_findings(ctx, args) do
    findings = ctx.deps[:findings] || []
    sources = ctx.deps[:sources] || %{}

    filtered =
      findings
      |> filter_by_sub_question(Map.get(args, "sub_question"))
      |> filter_by_verified(Map.get(args, "verified_only"))
      |> filter_by_confidence(Map.get(args, "confidence"))

    %{
      success: true,
      findings: Enum.reverse(filtered),
      total: length(filtered),
      sources_count: map_size(sources),
      by_confidence: %{
        high: Enum.count(findings, &(&1.confidence == :high)),
        medium: Enum.count(findings, &(&1.confidence == :medium)),
        low: Enum.count(findings, &(&1.confidence == :low))
      },
      verified_count: Enum.count(findings, & &1.verified)
    }
  end

  @doc """
  Add a source to track separately from findings.

  ## Parameters
  - url: Source URL (required)
  - title: Source title (optional)
  - type: Source type: web/news/academic/wikipedia (optional)
  - relevance: Relevance score 1-5 (optional)
  """
  def add_source(ctx, args) do
    url = Map.get(args, "url", "")
    title = Map.get(args, "title", "")
    source_type = parse_source_type(Map.get(args, "type", "web"))
    relevance = Map.get(args, "relevance", 3) |> min(5) |> max(1)

    sources = ctx.deps[:sources] || %{}

    if url == "" do
      %{success: false, error: "url is required"}
    else
      if Map.has_key?(sources, url) do
        %{success: false, error: "Source already tracked", url: url}
      else
        new_source = %{
          url: url,
          title: title,
          type: source_type,
          relevance: relevance,
          accessed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        updated_sources = Map.put(sources, url, new_source)

        %{
          success: true,
          source: new_source,
          total_sources: map_size(updated_sources),
          __update_context__: %{sources: updated_sources}
        }
      end
    end
  end

  @doc """
  List all tracked sources.
  """
  def list_sources(ctx, _args) do
    sources = ctx.deps[:sources] || %{}

    sources_list =
      sources
      |> Map.values()
      |> Enum.sort_by(& &1.relevance, :desc)

    by_type =
      Enum.group_by(sources_list, & &1.type)
      |> Enum.map(fn {type, list} -> {type, length(list)} end)
      |> Map.new()

    %{
      success: true,
      sources: sources_list,
      total: length(sources_list),
      by_type: by_type
    }
  end

  @doc """
  Add a knowledge gap identified during research.

  ## Parameters
  - description: What information is missing (required)
  - priority: low/medium/high (optional)
  """
  def add_gap(ctx, args) do
    description = Map.get(args, "description", "")
    priority = Map.get(args, "priority", "medium")

    if description == "" do
      %{success: false, error: "description is required"}
    else
      gaps = ctx.deps[:gaps] || []

      new_gap = %{
        id: length(gaps) + 1,
        description: description,
        priority: priority,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        resolved: false
      }

      updated_gaps = [new_gap | gaps]

      %{
        success: true,
        gap: new_gap,
        total_gaps: length(updated_gaps),
        __update_context__: %{gaps: updated_gaps}
      }
    end
  end

  @doc """
  List all knowledge gaps.
  """
  def list_gaps(ctx, _args) do
    gaps = ctx.deps[:gaps] || []
    unresolved = Enum.reject(gaps, & &1.resolved)

    %{
      success: true,
      gaps: Enum.reverse(unresolved),
      total: length(unresolved),
      resolved_count: length(gaps) - length(unresolved)
    }
  end

  @doc """
  Mark a gap as resolved.
  """
  def resolve_gap(ctx, args) do
    id = Map.get(args, "id")
    gaps = ctx.deps[:gaps] || []

    case Enum.find_index(gaps, &(&1.id == id)) do
      nil ->
        %{success: false, error: "Gap ##{id} not found"}

      index ->
        updated = Enum.at(gaps, index) |> Map.put(:resolved, true)
        updated_gaps = List.replace_at(gaps, index, updated)

        %{
          success: true,
          message: "Gap ##{id} resolved",
          __update_context__: %{gaps: updated_gaps}
        }
    end
  end

  @doc """
  Add verified knowledge to the knowledge base.

  ## Parameters
  - fact: The verified fact to store (required)
  - sources: List of source URLs supporting this fact (optional)
  """
  def add_to_knowledge_base(ctx, args) do
    fact = Map.get(args, "fact", "")
    source_urls = Map.get(args, "sources", [])

    if fact == "" do
      %{success: false, error: "fact is required"}
    else
      knowledge_base = ctx.deps[:knowledge_base] || []

      entry = %{
        id: length(knowledge_base) + 1,
        fact: fact,
        sources: source_urls,
        added_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      updated_kb = [entry | knowledge_base]

      %{
        success: true,
        entry: entry,
        total_facts: length(updated_kb),
        __update_context__: %{knowledge_base: updated_kb}
      }
    end
  end

  @doc """
  Get current research statistics.
  """
  def get_stats(ctx, _args) do
    findings = ctx.deps[:findings] || []
    sources = ctx.deps[:sources] || %{}
    gaps = ctx.deps[:gaps] || []
    knowledge_base = ctx.deps[:knowledge_base] || []

    %{
      success: true,
      stats: %{
        total_findings: length(findings),
        verified_findings: Enum.count(findings, & &1.verified),
        high_confidence: Enum.count(findings, &(&1.confidence == :high)),
        medium_confidence: Enum.count(findings, &(&1.confidence == :medium)),
        low_confidence: Enum.count(findings, &(&1.confidence == :low)),
        total_sources: map_size(sources),
        unresolved_gaps: Enum.count(gaps, &(not &1.resolved)),
        knowledge_base_size: length(knowledge_base)
      }
    }
  end

  # Helper functions

  defp parse_confidence(nil), do: nil
  defp parse_confidence("high"), do: :high
  defp parse_confidence("medium"), do: :medium
  defp parse_confidence("low"), do: :low
  defp parse_confidence(other) when is_atom(other), do: other
  defp parse_confidence(_), do: :medium

  defp parse_source_type("web"), do: :web
  defp parse_source_type("news"), do: :news
  defp parse_source_type("academic"), do: :academic
  defp parse_source_type("wikipedia"), do: :wikipedia
  defp parse_source_type(_), do: :web

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  defp filter_by_sub_question(findings, nil), do: findings

  defp filter_by_sub_question(findings, sq),
    do: Enum.filter(findings, &(&1.sub_question == sq))

  defp filter_by_verified(findings, nil), do: findings
  defp filter_by_verified(findings, true), do: Enum.filter(findings, & &1.verified)
  defp filter_by_verified(findings, "true"), do: Enum.filter(findings, & &1.verified)
  defp filter_by_verified(findings, _), do: findings

  defp filter_by_confidence(findings, nil), do: findings

  defp filter_by_confidence(findings, c) do
    c_atom = parse_confidence(c)
    Enum.filter(findings, &(&1.confidence == c_atom))
  end
end

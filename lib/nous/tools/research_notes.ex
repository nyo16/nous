defmodule Nous.Tools.ResearchNotes do
  @moduledoc """
  Structured note-taking tools for research agents.

  Provides tools to track findings, gaps, and contradictions across
  research iterations. Uses ContextUpdate to persist state in the
  agent's context deps.

  ## Usage

      tools = Nous.Tools.ResearchNotes.all_tools()
      agent = Agent.new("openai:gpt-4", tools: tools)
  """

  alias Nous.Tool
  alias Nous.Tool.ContextUpdate

  @doc """
  Returns all research note tools as a list.
  """
  def all_tools do
    [
      add_finding_tool(),
      list_findings_tool(),
      add_gap_tool(),
      list_gaps_tool(),
      add_contradiction_tool()
    ]
  end

  # Tool definitions

  defp add_finding_tool do
    %Tool{
      name: "add_finding",
      description:
        "Record a research finding with source and confidence score. Use this to track facts discovered during research.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "claim" => %{"type" => "string", "description" => "The factual claim or finding"},
          "source_url" => %{"type" => "string", "description" => "URL of the source"},
          "source_title" => %{
            "type" => "string",
            "description" => "Title of the source article/page"
          },
          "confidence" => %{
            "type" => "number",
            "description" => "Confidence score 0.0-1.0 (default: 0.7)"
          }
        },
        "required" => ["claim"]
      },
      function: &__MODULE__.add_finding/2,
      takes_ctx: true
    }
  end

  defp list_findings_tool do
    %Tool{
      name: "list_findings",
      description: "List all recorded research findings so far.",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []},
      function: &__MODULE__.list_findings/2,
      takes_ctx: true
    }
  end

  defp add_gap_tool do
    %Tool{
      name: "add_gap",
      description:
        "Record a knowledge gap - a question that still needs to be answered in the research.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "question" => %{
            "type" => "string",
            "description" => "The unanswered question or knowledge gap"
          }
        },
        "required" => ["question"]
      },
      function: &__MODULE__.add_gap/2,
      takes_ctx: true
    }
  end

  defp list_gaps_tool do
    %Tool{
      name: "list_gaps",
      description: "List all remaining knowledge gaps in the research.",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []},
      function: &__MODULE__.list_gaps/2,
      takes_ctx: true
    }
  end

  defp add_contradiction_tool do
    %Tool{
      name: "add_contradiction",
      description: "Record a contradiction found between two sources or claims.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "claim_a" => %{"type" => "string", "description" => "First conflicting claim"},
          "claim_b" => %{"type" => "string", "description" => "Second conflicting claim"},
          "sources" => %{
            "type" => "string",
            "description" => "Sources for each claim (comma-separated URLs)"
          }
        },
        "required" => ["claim_a", "claim_b"]
      },
      function: &__MODULE__.add_contradiction/2,
      takes_ctx: true
    }
  end

  # Tool implementations

  def add_finding(ctx, args) do
    finding = %{
      claim: Map.fetch!(args, "claim"),
      source_url: Map.get(args, "source_url"),
      source_title: Map.get(args, "source_title"),
      confidence: Map.get(args, "confidence", 0.7),
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    existing = ctx.deps[:research_findings] || []

    # Deduplicate by checking similar claims
    is_duplicate =
      Enum.any?(existing, fn f ->
        String.jaro_distance(f.claim, finding.claim) > 0.85
      end)

    if is_duplicate do
      {:ok, %{status: "duplicate", message: "A similar finding already exists"},
       ContextUpdate.new()}
    else
      {:ok, %{status: "recorded", finding: finding, total_findings: length(existing) + 1},
       ContextUpdate.new() |> ContextUpdate.append(:research_findings, finding)}
    end
  end

  def list_findings(ctx, _args) do
    findings = ctx.deps[:research_findings] || []

    %{
      findings: findings,
      count: length(findings),
      high_confidence: Enum.count(findings, &(&1.confidence >= 0.8)),
      low_confidence: Enum.count(findings, &(&1.confidence < 0.5))
    }
  end

  def add_gap(ctx, args) do
    question = Map.fetch!(args, "question")
    existing = ctx.deps[:research_gaps] || []

    {:ok, %{status: "recorded", question: question, total_gaps: length(existing) + 1},
     ContextUpdate.new() |> ContextUpdate.append(:research_gaps, question)}
  end

  def list_gaps(ctx, _args) do
    gaps = ctx.deps[:research_gaps] || []
    %{gaps: gaps, count: length(gaps)}
  end

  def add_contradiction(_ctx, args) do
    contradiction = %{
      claim_a: Map.fetch!(args, "claim_a"),
      claim_b: Map.fetch!(args, "claim_b"),
      sources: Map.get(args, "sources", ""),
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, %{status: "recorded", contradiction: contradiction},
     ContextUpdate.new() |> ContextUpdate.append(:research_contradictions, contradiction)}
  end
end

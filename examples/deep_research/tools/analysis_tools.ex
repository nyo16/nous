defmodule DeepResearch.Tools.AnalysisTools do
  @moduledoc """
  Tools for analyzing research findings and synthesizing insights.

  These tools help the Analyst agent process findings, identify patterns,
  and prepare data for the final report.
  """

  @doc """
  Analyze a set of findings and identify patterns.

  ## Parameters
  - findings: List of findings to analyze (optional, uses context if not provided)
  - focus: Specific aspect to focus on (optional)

  Returns analysis summary and identified patterns.
  """
  def analyze_findings(ctx, args) do
    findings = Map.get(args, "findings") || ctx.deps[:findings] || []
    focus = Map.get(args, "focus")

    if findings == [] do
      %{success: false, error: "No findings to analyze"}
    else
      verified = Enum.filter(findings, & &1.verified)
      by_confidence = Enum.group_by(findings, & &1.confidence)
      by_sub_question = Enum.group_by(findings, & &1.sub_question)

      %{
        success: true,
        summary: %{
          total_findings: length(findings),
          verified_count: length(verified),
          by_confidence: %{
            high: length(Map.get(by_confidence, :high, [])),
            medium: length(Map.get(by_confidence, :medium, [])),
            low: length(Map.get(by_confidence, :low, []))
          },
          sub_questions_covered: Map.keys(by_sub_question) |> Enum.reject(&is_nil/1),
          unique_sources: findings |> Enum.map(& &1.source_url) |> Enum.uniq() |> length()
        },
        analysis_guidance: """
        Analyze the findings with focus on: #{focus || "overall patterns"}

        Consider:
        1. What common themes emerge across findings?
        2. Are there any contradictions between sources?
        3. What claims have the strongest support (multiple sources)?
        4. What gaps remain in our understanding?
        5. What are the key takeaways for each sub-question?
        """,
        findings_by_topic:
          by_sub_question
          |> Enum.map(fn {sq, fs} -> {sq, length(fs)} end)
          |> Map.new()
      }
    end
  end

  @doc """
  Compare findings from multiple sources for consistency.

  ## Parameters
  - finding_ids: List of finding IDs to compare (optional)

  Returns comparison analysis.
  """
  def compare_sources(ctx, args) do
    finding_ids = Map.get(args, "finding_ids")
    all_findings = ctx.deps[:findings] || []

    findings =
      if finding_ids do
        Enum.filter(all_findings, &(&1.id in finding_ids))
      else
        all_findings
      end

    if length(findings) < 2 do
      %{success: false, error: "Need at least 2 findings to compare"}
    else
      sources =
        findings
        |> Enum.map(& &1.source_url)
        |> Enum.uniq()

      %{
        success: true,
        comparison: %{
          findings_compared: length(findings),
          unique_sources: length(sources),
          sources: sources
        },
        comparison_guidance: """
        Compare these #{length(findings)} findings from #{length(sources)} sources:

        Check for:
        1. Agreement: Do sources make similar claims?
        2. Contradiction: Are there conflicting statements?
        3. Complementary: Do sources add unique information?
        4. Reliability: Which sources are more authoritative?

        For each finding, note whether it is:
        - Confirmed by multiple sources
        - Unique to one source
        - Contradicted by other sources
        """,
        findings_preview:
          Enum.map(findings, fn f ->
            %{
              id: f.id,
              content_preview: String.slice(f.content, 0..100),
              source: f.source_title || f.source_url,
              confidence: f.confidence
            }
          end)
      }
    end
  end

  @doc """
  Generate a summary of findings for a specific sub-question.

  ## Parameters
  - sub_question: The sub-question to summarize (required)

  Returns findings related to that sub-question.
  """
  def summarize_for_question(ctx, args) do
    sub_question = Map.get(args, "sub_question", "")
    findings = ctx.deps[:findings] || []

    if sub_question == "" do
      %{success: false, error: "sub_question is required"}
    else
      relevant =
        Enum.filter(findings, fn f ->
          f.sub_question == sub_question or
            String.contains?(String.downcase(f.content), String.downcase(sub_question))
        end)

      %{
        success: true,
        sub_question: sub_question,
        finding_count: length(relevant),
        verified_count: Enum.count(relevant, & &1.verified),
        high_confidence_count: Enum.count(relevant, &(&1.confidence == :high)),
        findings:
          Enum.map(relevant, fn f ->
            %{
              id: f.id,
              content: f.content,
              source: f.source_title || f.source_url,
              confidence: f.confidence,
              verified: f.verified
            }
          end),
        summarization_guidance: """
        Summarize these findings to answer: #{sub_question}

        Structure your summary:
        1. Key answer/conclusion
        2. Supporting evidence (cite source)
        3. Caveats or limitations
        4. Confidence level based on source agreement
        """
      }
    end
  end

  @doc """
  Identify contradictions in findings.

  Looks for findings that might contradict each other.
  """
  def find_contradictions(ctx, _args) do
    findings = ctx.deps[:findings] || []

    if length(findings) < 2 do
      %{success: true, contradictions: [], message: "Not enough findings to check"}
    else
      %{
        success: true,
        analysis_guidance: """
        Review these #{length(findings)} findings for potential contradictions.

        Look for:
        1. Conflicting statistics or numbers
        2. Opposing conclusions or recommendations
        3. Different timelines for same events
        4. Contradictory cause-effect claims

        For each potential contradiction, note:
        - The conflicting claims
        - The sources involved
        - Which claim seems more reliable and why
        """,
        findings_to_review:
          findings
          |> Enum.sort_by(& &1.confidence, :desc)
          |> Enum.take(20)
          |> Enum.map(fn f ->
            %{
              id: f.id,
              content: String.slice(f.content, 0..200),
              source: f.source_title || f.source_url,
              confidence: f.confidence
            }
          end)
      }
    end
  end

  @doc """
  Calculate coverage score for sub-questions.

  Shows how well each sub-question has been researched.
  """
  def assess_coverage(ctx, _args) do
    findings = ctx.deps[:findings] || []
    sub_questions = ctx.deps[:sub_questions] || []

    coverage =
      Enum.map(sub_questions, fn sq ->
        related = Enum.filter(findings, &(&1.sub_question == sq))
        verified = Enum.count(related, & &1.verified)
        high_conf = Enum.count(related, &(&1.confidence == :high))

        score =
          cond do
            length(related) == 0 -> 0
            verified >= 3 and high_conf >= 2 -> 100
            verified >= 2 -> 80
            length(related) >= 3 -> 60
            length(related) >= 1 -> 40
            true -> 20
          end

        %{
          sub_question: sq,
          finding_count: length(related),
          verified_count: verified,
          high_confidence_count: high_conf,
          coverage_score: score,
          status:
            cond do
              score >= 80 -> :well_covered
              score >= 50 -> :partially_covered
              true -> :needs_research
            end
        }
      end)

    overall_score =
      if length(coverage) > 0 do
        Enum.map(coverage, & &1.coverage_score) |> Enum.sum() |> div(length(coverage))
      else
        0
      end

    %{
      success: true,
      coverage: coverage,
      overall_score: overall_score,
      needs_research:
        coverage
        |> Enum.filter(&(&1.status == :needs_research))
        |> Enum.map(& &1.sub_question),
      well_covered:
        coverage
        |> Enum.filter(&(&1.status == :well_covered))
        |> Enum.map(& &1.sub_question)
    }
  end

  @doc """
  Generate report outline based on findings.

  ## Parameters
  - title: Report title (optional)

  Returns suggested report structure.
  """
  def generate_outline(ctx, args) do
    title = Map.get(args, "title")
    question = ctx.deps[:question] || "Research Question"
    sub_questions = ctx.deps[:sub_questions] || []
    findings = ctx.deps[:findings] || []
    sources = ctx.deps[:sources] || %{}

    %{
      success: true,
      outline: %{
        title: title || "Research Report: #{question}",
        sections: [
          %{name: "Executive Summary", description: "Brief overview of key findings"},
          %{name: "Background & Context", description: "Introduction to the research question"}
          | Enum.with_index(sub_questions, 1)
            |> Enum.map(fn {sq, i} ->
              finding_count =
                Enum.count(findings, fn f ->
                  f.sub_question == sq
                end)

              %{
                name: "Section #{i}: #{summarize_question(sq)}",
                description: sq,
                finding_count: finding_count
              }
            end)
        ] ++
          [
            %{name: "Conclusions", description: "Synthesis of findings and recommendations"},
            %{name: "References", description: "#{map_size(sources)} sources cited"}
          ]
      },
      metadata: %{
        total_findings: length(findings),
        verified_findings: Enum.count(findings, & &1.verified),
        source_count: map_size(sources)
      }
    }
  end

  defp summarize_question(question) do
    question
    |> String.split()
    |> Enum.take(5)
    |> Enum.join(" ")
    |> Kernel.<>("...")
  end
end

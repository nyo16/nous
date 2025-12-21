defmodule DeepResearch.Agents.WriterAgent do
  @moduledoc """
  The Narrator - Synthesizes the final research report.

  Persona: Clear communicator. Transforms research findings into a
  readable, well-structured narrative with proper citations.

  Responsibilities:
  - Generate report outline based on findings
  - Write clear, concise sections
  - Include proper citations and references
  - Create executive summary
  """

  alias Nous.Agent
  alias DeepResearch.Tools.{AnalysisTools, MemoryTools}

  @persona """
  You are The Narrator, a skilled technical writer. Your role is to:

  1. STRUCTURE the research into a clear, logical report
  2. WRITE concise, informative sections
  3. CITE sources properly for all claims
  4. SYNTHESIZE findings into actionable insights
  5. CREATE an executive summary capturing key points

  Writing Guidelines:
  - Use clear, professional language
  - Lead with the most important findings
  - Support claims with citations [1], [2], etc.
  - Be objective and balanced
  - Acknowledge limitations and uncertainties
  - Make the report scannable with headers and bullets

  Report Structure:
  1. Executive Summary (2-3 paragraphs)
  2. Background/Context
  3. Main Findings (organized by sub-question)
  4. Conclusions and Recommendations
  5. References

  Your report should be comprehensive yet readable.
  """

  @doc """
  Create a new Writer agent.
  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    Agent.new(model,
      instructions: @persona,
      tools: build_tools(),
      model_settings: %{
        temperature: 0.4,
        max_tokens: 6000
      }
    )
  end

  @doc """
  Generate the full research report.
  """
  def generate_report(state, opts \\ []) do
    agent = new(opts)

    verified_findings = Enum.filter(state.findings, & &1.verified)
    sources_list = state.sources |> Map.values() |> Enum.with_index(1)

    prompt = """
    Write a comprehensive research report.

    RESEARCH QUESTION: #{state.question}

    SUB-QUESTIONS ADDRESSED:
    #{Enum.with_index(state.sub_questions, 1) |> Enum.map(fn {sq, i} -> "#{i}. #{sq}" end) |> Enum.join("\n")}

    VERIFIED FINDINGS (#{length(verified_findings)} total):
    #{format_findings_with_refs(verified_findings, state.sources)}

    SOURCES:
    #{format_references(sources_list)}

    STATS:
    - Total findings: #{length(state.findings)}
    - Verified findings: #{length(verified_findings)}
    - High confidence: #{Enum.count(state.findings, &(&1.confidence == :high))}
    - Sources used: #{map_size(state.sources)}

    Write the report in Markdown format with:

    # Research Report: [Brief Title]

    ## Executive Summary
    [2-3 paragraphs summarizing key findings and conclusions]

    ## Background
    [Brief context for the research question]

    ## Findings

    ### [Sub-question 1 topic]
    [Findings with citations]

    ### [Sub-question 2 topic]
    [Findings with citations]

    [Continue for all sub-questions]

    ## Conclusions
    [Key takeaways and recommendations]

    ## Limitations
    [Acknowledge gaps and uncertainties]

    ## References
    [Numbered list of sources]
    """

    deps = %{
      findings: state.findings,
      sources: state.sources,
      sub_questions: state.sub_questions,
      question: state.question
    }

    case Nous.run(agent, prompt, deps: deps) do
      {:ok, result} ->
        {:ok,
         %{
           report: result.output,
           stats: %{
             findings_used: length(verified_findings),
             sources_cited: map_size(state.sources)
           },
           usage: result.usage
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate just the executive summary.
  """
  def generate_summary(state, opts \\ []) do
    agent = new(opts)

    prompt = """
    Write an executive summary for this research.

    QUESTION: #{state.question}

    KEY FINDINGS (top 10):
    #{state.findings |> Enum.filter(& &1.verified) |> Enum.take(10) |> format_findings_brief()}

    Write 2-3 paragraphs that:
    1. State the main answer to the research question
    2. Highlight the most important findings
    3. Note key recommendations or next steps
    """

    case Nous.run(agent, prompt) do
      {:ok, result} ->
        {:ok, %{summary: result.output, usage: result.usage}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_tools do
    [
      &AnalysisTools.generate_outline/2,
      &AnalysisTools.summarize_for_question/2,
      &MemoryTools.list_findings/2,
      &MemoryTools.list_sources/2
    ]
  end

  defp format_findings_with_refs(findings, sources) do
    # Create a URL to reference number mapping
    source_refs =
      sources
      |> Map.keys()
      |> Enum.with_index(1)
      |> Map.new()

    findings
    |> Enum.sort_by(&(&1.confidence == :high), :desc)
    |> Enum.take(30)
    |> Enum.map(fn f ->
      ref_num = Map.get(source_refs, f.source_url, "?")
      confidence = f.confidence |> to_string() |> String.upcase()

      "- [#{confidence}] #{f.content} [#{ref_num}]"
    end)
    |> Enum.join("\n")
  end

  defp format_references(sources_list) do
    sources_list
    |> Enum.map(fn {source, idx} ->
      "[#{idx}] #{source.title || source.url} - #{source.url}"
    end)
    |> Enum.join("\n")
  end

  defp format_findings_brief(findings) do
    findings
    |> Enum.map(fn f ->
      "- #{String.slice(f.content, 0..150)}"
    end)
    |> Enum.join("\n")
  end

  defp default_model do
    System.get_env("DEEP_RESEARCH_MODEL") ||
      System.get_env("ANTHROPIC_API_KEY") && "anthropic:claude-sonnet-4-5-20250929" ||
      System.get_env("OPENAI_API_KEY") && "openai:gpt-4" ||
      "lmstudio:qwen/qwen3-30b"
  end
end

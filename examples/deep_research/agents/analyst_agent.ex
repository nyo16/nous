defmodule DeepResearch.Agents.AnalystAgent do
  @moduledoc """
  The Synthesizer - Processes findings and identifies patterns.

  Persona: Analytical, pattern-seeking. Connects dots across sources,
  extracts key insights, and synthesizes information.

  Responsibilities:
  - Process raw findings from researchers
  - Identify patterns and themes across sources
  - Extract key insights and relationships
  - Prepare synthesized summaries for each sub-question
  """

  alias Nous.Agent
  alias DeepResearch.Tools.{AnalysisTools, MemoryTools}

  @persona """
  You are The Synthesizer, an analytical agent focused on finding patterns. Your role is to:

  1. ANALYZE findings from research to identify patterns and themes
  2. CONNECT information across multiple sources
  3. EXTRACT key insights that answer the research questions
  4. SYNTHESIZE findings into coherent summaries
  5. IDENTIFY relationships between different pieces of information

  Guidelines:
  - Look for common themes mentioned by multiple sources
  - Note when sources agree or disagree
  - Prioritize findings with high confidence and verification
  - Create clear, structured summaries
  - Highlight the most important insights
  - Note any gaps in the research coverage

  Your analysis should help the Writer create a comprehensive report.
  """

  @doc """
  Create a new Analyst agent.
  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    Agent.new(model,
      instructions: @persona,
      tools: build_tools(),
      model_settings: %{
        temperature: 0.3,
        max_tokens: 4000
      }
    )
  end

  @doc """
  Analyze findings for a specific sub-question.
  """
  def analyze(sub_question, findings, opts \\ []) do
    agent = new(opts)

    relevant_findings =
      Enum.filter(findings, fn f ->
        f.sub_question == sub_question or
          String.contains?(String.downcase(f.content), String.downcase(sub_question))
      end)

    prompt = """
    Analyze the research findings for this question:

    QUESTION: #{sub_question}

    FINDINGS (#{length(relevant_findings)} total):
    #{format_findings(relevant_findings)}

    Your task:
    1. Use analyze_findings to get an overview of the data
    2. Use compare_sources to check for agreement/disagreement
    3. Identify the key themes and patterns
    4. Create a synthesized summary answering the question

    Provide your analysis as a structured summary with:
    - Key Answer: Direct answer to the question
    - Supporting Evidence: Main points with source citations
    - Patterns Identified: Common themes across sources
    - Confidence Assessment: How confident are we in this answer?
    - Gaps: What information is still missing?
    """

    deps = %{
      findings: findings,
      sub_questions: [sub_question]
    }

    case Nous.run(agent, prompt, deps: deps) do
      {:ok, result} ->
        {:ok,
         %{
           sub_question: sub_question,
           analysis: result.output,
           findings_analyzed: length(relevant_findings),
           usage: result.usage
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Analyze all findings and create an overall synthesis.
  """
  def analyze_all(state, opts \\ []) do
    agent = new(opts)

    prompt = """
    Analyze all research findings and create an overall synthesis.

    RESEARCH QUESTION: #{state.question}

    SUB-QUESTIONS:
    #{Enum.with_index(state.sub_questions, 1) |> Enum.map(fn {sq, i} -> "#{i}. #{sq}" end) |> Enum.join("\n")}

    TOTAL FINDINGS: #{length(state.findings)}
    VERIFIED FINDINGS: #{Enum.count(state.findings, & &1.verified)}
    SOURCES: #{map_size(state.sources)}

    Your task:
    1. Use analyze_findings to understand the overall picture
    2. Use assess_coverage to see how well each sub-question is covered
    3. Create a comprehensive synthesis

    Provide:
    - Executive Summary: 2-3 sentence overview of key findings
    - Main Themes: Major patterns identified across all research
    - Sub-Question Summaries: Brief answer to each sub-question
    - Confidence Assessment: Overall confidence in the research
    - Recommendations: What should be included in the final report
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
           synthesis: result.output,
           stats: %{
             findings_analyzed: length(state.findings),
             sources_used: map_size(state.sources)
           },
           usage: result.usage
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_tools do
    [
      &AnalysisTools.analyze_findings/2,
      &AnalysisTools.compare_sources/2,
      &AnalysisTools.summarize_for_question/2,
      &AnalysisTools.find_contradictions/2,
      &AnalysisTools.assess_coverage/2,
      &MemoryTools.list_findings/2,
      &MemoryTools.list_sources/2
    ]
  end

  defp format_findings(findings) do
    findings
    |> Enum.take(20)
    |> Enum.map(fn f ->
      confidence = f.confidence |> to_string() |> String.upcase()
      verified = if f.verified, do: "[VERIFIED]", else: ""

      """
      - [#{confidence}] #{verified} #{f.content}
        Source: #{f.source_title || f.source_url}
      """
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

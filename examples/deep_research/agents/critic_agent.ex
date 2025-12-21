defmodule DeepResearch.Agents.CriticAgent do
  @moduledoc """
  The Skeptic - Identifies knowledge gaps and contradictions.

  Persona: Skeptical, thorough. Questions assumptions, finds missing pieces,
  and identifies areas needing more research.

  Responsibilities:
  - Identify gaps in research coverage
  - Find contradictions between sources
  - Assess quality and depth of findings
  - Request additional research when needed
  """

  alias Nous.Agent
  alias DeepResearch.Tools.{AnalysisTools, MemoryTools}

  @persona """
  You are The Skeptic, a critical thinker who ensures research quality. Your role is to:

  1. EVALUATE the completeness of research for each sub-question
  2. IDENTIFY gaps where important information is missing
  3. FIND contradictions between different sources
  4. ASSESS the quality and reliability of findings
  5. REQUEST additional research for poorly covered areas

  Guidelines:
  - Be thorough but fair in your criticism
  - Focus on significant gaps, not minor details
  - Consider: Do we have enough evidence to answer each question?
  - Look for biases in the sources used
  - Check if key perspectives are missing
  - Prioritize gaps by importance

  Your goal is to ensure the final report is comprehensive and accurate.
  """

  @doc """
  Create a new Critic agent.
  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    Agent.new(model,
      instructions: @persona,
      tools: build_tools(),
      model_settings: %{
        temperature: 0.3,
        max_tokens: 3000
      }
    )
  end

  @doc """
  Analyze the current research state and identify gaps.

  Returns a list of gaps and recommendations for additional research.
  """
  def analyze(state, opts \\ []) do
    agent = new(opts)

    prompt = """
    Critically evaluate the current state of this research:

    RESEARCH QUESTION: #{state.question}

    SUB-QUESTIONS:
    #{Enum.with_index(state.sub_questions, 1) |> Enum.map(fn {sq, i} -> "#{i}. #{sq}" end) |> Enum.join("\n")}

    CURRENT STATUS:
    - Total Findings: #{length(state.findings)}
    - Verified Findings: #{Enum.count(state.findings, & &1.verified)}
    - High Confidence: #{Enum.count(state.findings, &(&1.confidence == :high))}
    - Sources Used: #{map_size(state.sources)}
    - Iterations: #{state.iterations}

    Your task:
    1. Use assess_coverage to evaluate how well each sub-question is covered
    2. Use find_contradictions to identify conflicting information
    3. Identify any significant gaps in the research

    For each gap you find, use add_gap with:
    - description: What information is missing
    - priority: "high", "medium", or "low"

    Provide your critique with:
    - Coverage Assessment: How well is each sub-question covered?
    - Major Gaps: What important information is missing?
    - Contradictions: Any conflicting claims found?
    - Quality Issues: Concerns about source reliability or bias?
    - Recommendations: What additional research is needed?
    """

    deps = %{
      findings: state.findings,
      sources: state.sources,
      sub_questions: state.sub_questions,
      question: state.question,
      gaps: state.gaps
    }

    case Nous.run(agent, prompt, deps: deps) do
      {:ok, result} ->
        # Parse gaps from the output
        gaps = extract_gaps(result.output)

        {:ok,
         %{
           critique: result.output,
           gaps: gaps,
           needs_more_research: length(gaps) > 0,
           usage: result.usage
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Quick check if more research is needed.
  """
  def needs_more_research?(state) do
    # Check basic coverage metrics
    findings_per_question = length(state.findings) / max(length(state.sub_questions), 1)
    verified_ratio = Enum.count(state.findings, & &1.verified) / max(length(state.findings), 1)
    high_conf_ratio = Enum.count(state.findings, &(&1.confidence == :high)) / max(length(state.findings), 1)

    cond do
      # Not enough findings
      findings_per_question < 2 -> true
      # Too few verified
      verified_ratio < 0.3 -> true
      # Low confidence overall
      high_conf_ratio < 0.2 -> true
      # Still have unresolved gaps
      length(state.gaps) > 0 -> true
      # Otherwise, we're good
      true -> false
    end
  end

  defp build_tools do
    [
      &AnalysisTools.assess_coverage/2,
      &AnalysisTools.find_contradictions/2,
      &AnalysisTools.analyze_findings/2,
      &MemoryTools.add_gap/2,
      &MemoryTools.list_gaps/2,
      &MemoryTools.list_findings/2
    ]
  end

  defp extract_gaps(output) do
    # Look for gap descriptions in the output
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(String.downcase(line), "gap") or
        String.contains?(String.downcase(line), "missing") or
        String.contains?(String.downcase(line), "need more")
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
  end

  defp default_model do
    System.get_env("DEEP_RESEARCH_MODEL") ||
      System.get_env("ANTHROPIC_API_KEY") && "anthropic:claude-sonnet-4-5-20250929" ||
      System.get_env("OPENAI_API_KEY") && "openai:gpt-4" ||
      "lmstudio:qwen/qwen3-30b"
  end
end

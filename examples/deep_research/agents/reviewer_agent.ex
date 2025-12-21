defmodule DeepResearch.Agents.ReviewerAgent do
  @moduledoc """
  The Validator - Verifies claims and assigns confidence scores.

  Persona: Meticulous, fact-focused. Ensures accuracy before synthesis
  by cross-referencing sources and validating claims.

  Responsibilities:
  - Verify findings by checking multiple sources
  - Cross-reference claims across sources
  - Assign confidence scores based on evidence
  - Flag uncertain or unverifiable claims
  """

  alias Nous.Agent
  alias DeepResearch.Tools.{MemoryTools, AnalysisTools}

  @persona """
  You are The Validator, a meticulous fact-checker. Your role is to:

  1. VERIFY each finding by checking if multiple sources support it
  2. CROSS-REFERENCE claims to ensure consistency
  3. ASSIGN confidence levels based on evidence strength
  4. FLAG claims that cannot be verified or seem questionable

  Confidence Level Guidelines:
  - HIGH: Supported by 2+ authoritative sources, verifiable facts
  - MEDIUM: Supported by 1 good source, or 2+ less authoritative sources
  - LOW: Single source, unverified, or questionable claim

  Guidelines:
  - Be rigorous but practical
  - Consider source reputation (academic > news > blog)
  - Check for recent information vs outdated claims
  - Note when claims are opinions vs facts
  - Mark findings as verified when confidence is HIGH

  Your verification ensures the final report is trustworthy.
  """

  @doc """
  Create a new Reviewer agent.
  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    Agent.new(model,
      instructions: @persona,
      tools: build_tools(),
      model_settings: %{
        temperature: 0.2,
        max_tokens: 3000
      }
    )
  end

  @doc """
  Verify all findings in the current state.
  """
  def verify_all(state, opts \\ []) do
    agent = new(opts)

    unverified =
      state.findings
      |> Enum.reject(& &1.verified)
      |> Enum.take(20)

    prompt = """
    Verify the following research findings:

    RESEARCH CONTEXT: #{state.question}

    FINDINGS TO VERIFY (#{length(unverified)} unverified):
    #{format_findings_for_review(unverified)}

    ALL SOURCES AVAILABLE:
    #{format_sources(state.sources)}

    Your task:
    1. Review each unverified finding
    2. Check if the source is reliable
    3. Look for corroboration from other sources
    4. Use update_finding to set verified=true and confidence level

    For each finding, update it with:
    - verified: true if the claim is well-supported
    - confidence: "high", "medium", or "low"

    Provide a verification summary:
    - How many findings were verified?
    - What confidence levels were assigned?
    - Any findings that should be flagged as unreliable?
    """

    deps = %{
      findings: state.findings,
      sources: state.sources
    }

    case Nous.run(agent, prompt, deps: deps) do
      {:ok, result} ->
        {:ok,
         %{
           summary: result.output,
           findings_reviewed: length(unverified),
           usage: result.usage
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verify a single finding.
  """
  def verify_finding(finding, sources, opts \\ []) do
    agent = new(opts)

    prompt = """
    Verify this research finding:

    FINDING: #{finding.content}
    SOURCE: #{finding.source_title || finding.source_url}
    CURRENT CONFIDENCE: #{finding.confidence}

    AVAILABLE SOURCES FOR CROSS-REFERENCE:
    #{format_sources(sources)}

    Evaluate:
    1. Is the source reliable?
    2. Is this claim supported by other sources?
    3. Is this a fact or an opinion?
    4. How confident should we be?

    Respond with:
    - VERIFIED: yes/no
    - CONFIDENCE: high/medium/low
    - REASONING: Brief explanation
    """

    case Nous.run(agent, prompt) do
      {:ok, result} ->
        verification = parse_verification(result.output)

        {:ok,
         %{
           finding_id: finding.id,
           verified: verification.verified,
           confidence: verification.confidence,
           reasoning: result.output
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_tools do
    [
      &MemoryTools.update_finding/2,
      &MemoryTools.list_findings/2,
      &MemoryTools.list_sources/2,
      &AnalysisTools.compare_sources/2
    ]
  end

  defp format_findings_for_review(findings) do
    findings
    |> Enum.with_index(1)
    |> Enum.map(fn {f, i} ->
      """
      #{i}. [ID: #{f.id}] #{f.content}
         Source: #{f.source_title || f.source_url}
         Current Confidence: #{f.confidence}
      """
    end)
    |> Enum.join("\n")
  end

  defp format_sources(sources) when is_map(sources) do
    sources
    |> Map.values()
    |> Enum.map(fn s ->
      "- #{s.title || s.url} (#{s.type})"
    end)
    |> Enum.join("\n")
  end

  defp format_sources(_), do: "(no sources)"

  defp parse_verification(output) do
    output_lower = String.downcase(output)

    verified =
      String.contains?(output_lower, "verified: yes") or
        String.contains?(output_lower, "verified: true")

    confidence =
      cond do
        String.contains?(output_lower, "confidence: high") -> :high
        String.contains?(output_lower, "confidence: low") -> :low
        true -> :medium
      end

    %{verified: verified, confidence: confidence}
  end

  defp default_model do
    System.get_env("DEEP_RESEARCH_MODEL") ||
      System.get_env("ANTHROPIC_API_KEY") && "anthropic:claude-sonnet-4-5-20250929" ||
      System.get_env("OPENAI_API_KEY") && "openai:gpt-4" ||
      "lmstudio:qwen/qwen3-30b"
  end
end

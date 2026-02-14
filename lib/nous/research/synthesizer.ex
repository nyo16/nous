defmodule Nous.Research.Synthesizer do
  @moduledoc """
  Consolidates findings from multiple searchers.

  Performs deduplication, contradiction detection, and gap analysis.
  """

  alias Nous.Research.Finding

  require Logger

  @type synthesis :: %{
          claims: [%{text: String.t(), sources: [String.t()], confidence: float()}],
          gaps: [String.t()],
          contradictions: [%{claim_a: String.t(), claim_b: String.t(), sources: String.t()}],
          total_findings: non_neg_integer()
        }

  @doc """
  Synthesize findings from multiple search results into a consolidated view.
  """
  @spec synthesize([Finding.t()], keyword()) :: {:ok, synthesis()} | {:error, term()}
  def synthesize(findings, opts \\ []) do
    model = Keyword.get(opts, :model, "openai:gpt-4o-mini")
    existing_gaps = Keyword.get(opts, :gaps, [])
    existing_contradictions = Keyword.get(opts, :contradictions, [])

    if Enum.empty?(findings) do
      {:ok,
       %{
         claims: [],
         gaps: existing_gaps,
         contradictions: existing_contradictions,
         total_findings: 0
       }}
    else
      synthesize_with_llm(findings, existing_gaps, existing_contradictions, model)
    end
  end

  defp synthesize_with_llm(findings, existing_gaps, existing_contradictions, model) do
    findings_text =
      findings
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} ->
        source = f.source_url || "unknown"
        "[#{i}] (confidence: #{f.confidence}) #{f.claim} [Source: #{source}]"
      end)
      |> Enum.join("\n")

    gaps_text =
      if Enum.empty?(existing_gaps),
        do: "None yet",
        else: Enum.join(existing_gaps, "\n- ")

    prompt = """
    Analyze these research findings and provide a synthesis.

    FINDINGS:
    #{findings_text}

    EXISTING KNOWLEDGE GAPS:
    #{gaps_text}

    Respond in this exact format:

    CLAIMS:
    - [claim text] (confidence: X.X) [sources: 1,3,5]
    - [claim text] (confidence: X.X) [sources: 2,4]

    REMAINING GAPS:
    - [unanswered question]
    - [unanswered question]

    CONTRADICTIONS:
    - [claim A] vs [claim B] [sources: 1 vs 3]

    Rules:
    - Deduplicate similar claims (merge and cite all sources)
    - Flag contradictions where sources disagree
    - Identify what's still unknown
    - Assign confidence based on source agreement (higher if multiple sources agree)
    """

    agent =
      Nous.Agent.new(model,
        instructions: "You are a research synthesis specialist. Be precise and cite sources.",
        model_settings: %{temperature: 0.2, max_tokens: 2000}
      )

    case Nous.Agent.run(agent, prompt) do
      {:ok, result} ->
        parsed = parse_synthesis(result.output, findings, existing_contradictions)
        {:ok, parsed}

      {:error, reason} ->
        # Fallback: return raw findings as claims
        Logger.warning("Synthesis LLM call failed: #{inspect(reason)}")

        claims =
          Enum.map(findings, fn f ->
            %{text: f.claim, sources: [f.source_url], confidence: f.confidence}
          end)

        {:ok,
         %{
           claims: claims,
           gaps: existing_gaps,
           contradictions: existing_contradictions,
           total_findings: length(findings)
         }}
    end
  end

  defp parse_synthesis(output, findings, existing_contradictions) do
    claims = parse_claims_section(output, findings)
    gaps = parse_gaps_section(output)
    contradictions = parse_contradictions_section(output) ++ existing_contradictions

    %{
      claims: claims,
      gaps: gaps,
      contradictions: contradictions,
      total_findings: length(findings)
    }
  end

  defp parse_claims_section(output, findings) do
    case Regex.run(~r/CLAIMS:\s*\n(.*?)(?=\nREMAINING GAPS:|\nCONTRADICTIONS:|$)/s, output) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "-"))
        |> Enum.map(&parse_claim_line(&1, findings))
        |> Enum.reject(&is_nil/1)

      _ ->
        # Fallback: convert findings directly
        Enum.map(findings, fn f ->
          %{text: f.claim, sources: [f.source_url], confidence: f.confidence}
        end)
    end
  end

  defp parse_claim_line(line, findings) do
    # Parse: "- [claim] (confidence: X.X) [sources: 1,3]"
    text =
      line
      |> String.trim_leading("- ")
      |> String.replace(~r/\(confidence:.*?\)/, "")
      |> String.replace(~r/\[sources:.*?\]/, "")
      |> String.trim()

    confidence =
      case Regex.run(~r/confidence:\s*([\d.]+)/, line) do
        [_, c] ->
          case Float.parse(c) do
            {f, _} -> f
            :error -> 0.5
          end

        _ ->
          0.5
      end

    source_indices =
      case Regex.run(~r/sources:\s*([\d,\s]+)/, line) do
        [_, indices] ->
          indices
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&Integer.parse/1)
          |> Enum.filter(&match?({_, _}, &1))
          |> Enum.map(fn {i, _} -> i - 1 end)

        _ ->
          []
      end

    sources =
      source_indices
      |> Enum.map(fn i -> Enum.at(findings, i) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.source_url)
      |> Enum.reject(&is_nil/1)

    if text != "" do
      %{text: text, sources: sources, confidence: confidence}
    end
  end

  defp parse_gaps_section(output) do
    case Regex.run(~r/REMAINING GAPS:\s*\n(.*?)(?=\nCONTRADICTIONS:|$)/s, output) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "-"))
        |> Enum.map(&String.trim_leading(&1, "- "))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp parse_contradictions_section(output) do
    case Regex.run(~r/CONTRADICTIONS:\s*\n(.*?)$/s, output) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "-"))
        |> Enum.map(fn line ->
          case String.split(line, " vs ", parts: 2) do
            [a, b] ->
              %{
                claim_a: String.trim_leading(a, "- "),
                claim_b: String.replace(b, ~r/\[sources:.*\]/, "") |> String.trim(),
                sources: ""
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end
end

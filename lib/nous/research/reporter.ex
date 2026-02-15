defmodule Nous.Research.Reporter do
  @moduledoc """
  Generates structured research reports with citations.
  """

  alias Nous.Research.{Finding, Report}

  @doc """
  Generate a markdown report from synthesis results and findings.
  """
  @spec generate(String.t(), map(), [Finding.t()], keyword()) ::
          {:ok, Report.t()} | {:error, term()}
  def generate(query, synthesis, findings, opts \\ []) do
    model = Keyword.get(opts, :model, "openai:gpt-4o-mini")
    start_time = Keyword.get(opts, :start_time, System.monotonic_time())
    total_tokens = Keyword.get(opts, :total_tokens, 0)
    iterations = Keyword.get(opts, :iterations, 0)

    case generate_report_content(query, synthesis, findings, model) do
      {:ok, content, title} ->
        sources = build_source_list(findings)
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        report = %Report{
          title: title,
          query: query,
          content: content,
          findings: findings,
          sources: sources,
          gaps: Map.get(synthesis, :gaps, []),
          iterations: iterations,
          total_tokens: total_tokens,
          duration_ms: duration_ms,
          completed_at: DateTime.utc_now()
        }

        {:ok, report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_report_content(query, synthesis, findings, model) do
    claims_text =
      (synthesis[:claims] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {claim, i} ->
        sources_refs =
          claim.sources
          |> Enum.map(fn url ->
            idx = Enum.find_index(findings, fn f -> f.source_url == url end)
            if idx, do: "[#{idx + 1}]", else: ""
          end)
          |> Enum.join("")

        "#{i}. #{claim.text} #{sources_refs} (confidence: #{claim.confidence})"
      end)
      |> Enum.join("\n")

    gaps_text =
      (synthesis[:gaps] || [])
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    contradictions_text =
      (synthesis[:contradictions] || [])
      |> Enum.map(&"- #{&1.claim_a} vs #{&1.claim_b}")
      |> Enum.join("\n")

    sources_text =
      findings
      |> Enum.uniq_by(& &1.source_url)
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} ->
        title = f.source_title || "Source"
        url = f.source_url || "unknown"
        "[#{i}] #{title} - #{url}"
      end)
      |> Enum.join("\n")

    prompt = """
    Write a comprehensive research report based on these findings.

    RESEARCH QUESTION: #{query}

    KEY CLAIMS:
    #{claims_text}

    KNOWLEDGE GAPS:
    #{gaps_text}

    CONTRADICTIONS:
    #{contradictions_text}

    SOURCES:
    #{sources_text}

    Write a well-structured markdown report with:
    1. A title (one line, no #)
    2. An executive summary (2-3 sentences)
    3. Key findings (with inline citations like [1], [2])
    4. Analysis and discussion
    5. Contradictions and caveats (if any)
    6. Further research needed (if any gaps remain)
    7. Sources (numbered list)

    Use inline citations [N] referring to the source numbers above.
    Be factual and balanced. Flag uncertainty where confidence is low.
    """

    agent =
      Nous.Agent.new(model,
        instructions: "Write clear, well-cited research reports in markdown.",
        model_settings: %{temperature: 0.3, max_tokens: 4000}
      )

    case Nous.Agent.run(agent, prompt) do
      {:ok, result} ->
        content = result.output

        title =
          content
          |> String.split("\n", parts: 2)
          |> List.first()
          |> String.trim_leading("#")
          |> String.trim()

        {:ok, content, title}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_source_list(findings) do
    findings
    |> Enum.filter(& &1.source_url)
    |> Enum.uniq_by(& &1.source_url)
    |> Enum.map(fn f ->
      %{url: f.source_url, title: f.source_title}
    end)
  end
end

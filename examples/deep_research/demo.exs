#!/usr/bin/env elixir

# Deep Research Multi-Agent Demo
#
# Demonstrates the full deep research workflow with:
# - 6 specialized AI agents working together
# - DAG-based orchestration with parallel execution
# - Iterative research with gap detection
# - Comprehensive report generation with citations
#
# Prerequisites:
# - Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or run LM Studio locally
# - Optionally set BRAVE_API_KEY for real web search (falls back to mock)
#
# Run with:
#   cd examples/deep_research
#   elixir demo.exs
#
# Or with a custom question:
#   elixir demo.exs "Your research question here"

# Ensure httpc is started
:inets.start()
:ssl.start()

# Load all modules
Code.require_file("research_state.ex", __DIR__)
Code.require_file("research_graph.ex", __DIR__)
Code.require_file("tools/memory_tools.ex", __DIR__)
Code.require_file("tools/search_tools.ex", __DIR__)
Code.require_file("tools/content_tools.ex", __DIR__)
Code.require_file("tools/analysis_tools.ex", __DIR__)
Code.require_file("agents/planner_agent.ex", __DIR__)
Code.require_file("agents/researcher_agent.ex", __DIR__)
Code.require_file("agents/analyst_agent.ex", __DIR__)
Code.require_file("agents/critic_agent.ex", __DIR__)
Code.require_file("agents/reviewer_agent.ex", __DIR__)
Code.require_file("agents/writer_agent.ex", __DIR__)
Code.require_file("orchestrator.ex", __DIR__)
Code.require_file("deep_research.ex", __DIR__)

defmodule DeepResearchDemo do
  @moduledoc """
  Interactive demo for the Deep Research multi-agent system.
  """

  def run(question \\ nil) do
    print_header()
    check_configuration()

    question = question || default_question()

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("RESEARCH QUESTION")
    IO.puts(String.duplicate("=", 70))
    IO.puts("\n#{question}\n")

    IO.puts("Starting deep research in 3 seconds...")
    IO.puts("(Press Ctrl+C to cancel)\n")
    Process.sleep(3000)

    start_time = System.monotonic_time(:millisecond)

    case DeepResearch.research_with_logging(question) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time
        print_results(result, duration)

      {:error, reason} ->
        IO.puts("\n[ERROR] Research failed: #{inspect(reason)}")
    end
  end

  defp print_header do
    IO.puts("""

    ╔══════════════════════════════════════════════════════════════════════╗
    ║                                                                      ║
    ║                    DEEP RESEARCH MULTI-AGENT SYSTEM                  ║
    ║                                                                      ║
    ║   6 Specialized Agents • DAG Orchestration • Parallel Execution      ║
    ║                                                                      ║
    ╚══════════════════════════════════════════════════════════════════════╝

    Agents:
      [PLANNER]    The Strategist - Decomposes questions
      [RESEARCHER] The Scout - Iterative search & extraction
      [ANALYST]    The Synthesizer - Pattern identification
      [CRITIC]     The Skeptic - Gap detection
      [REVIEWER]   The Validator - Verification & scoring
      [WRITER]     The Narrator - Report generation

    """)
  end

  defp check_configuration do
    brave_key = System.get_env("BRAVE_API_KEY")
    anthropic_key = System.get_env("ANTHROPIC_API_KEY")
    openai_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("DEEP_RESEARCH_MODEL")

    IO.puts("Configuration:")

    # Determine model
    active_model =
      cond do
        model -> model
        anthropic_key -> "anthropic:claude-sonnet-4-5-20250929"
        openai_key -> "openai:gpt-4"
        true -> "lmstudio:qwen/qwen3-30b"
      end

    IO.puts("  Model: #{active_model}")
    IO.puts("  Brave Search: #{if brave_key, do: "Enabled", else: "Mock mode (set BRAVE_API_KEY for real search)"}")

    unless anthropic_key || openai_key do
      IO.puts("\n  ⚠️  No cloud API key set. Make sure LM Studio is running locally.")
      IO.puts("     Or set ANTHROPIC_API_KEY or OPENAI_API_KEY for cloud models.")
    end

    IO.puts("")
  end

  defp default_question do
    """
    What are the most promising approaches to achieving artificial general intelligence (AGI),
    and what are the main technical and safety challenges that need to be solved?
    """
    |> String.replace("\n", " ")
    |> String.trim()
  end

  defp print_results(result, duration) do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("RESEARCH REPORT")
    IO.puts(String.duplicate("=", 70))
    IO.puts("")
    IO.puts(result.report)
    IO.puts("")

    IO.puts(String.duplicate("=", 70))
    IO.puts("SOURCES (#{map_size(result.sources)} total)")
    IO.puts(String.duplicate("=", 70))

    result.sources
    |> Map.values()
    |> Enum.with_index(1)
    |> Enum.each(fn {source, idx} ->
      IO.puts("  [#{idx}] #{source.title || "Untitled"}")
      IO.puts("      #{source.url}")
    end)

    IO.puts("")
    IO.puts(String.duplicate("=", 70))
    IO.puts("STATISTICS")
    IO.puts(String.duplicate("=", 70))

    stats = result.stats

    IO.puts("  Total Findings:    #{stats.total_findings}")
    IO.puts("  Verified Findings: #{stats.verified_findings}")
    IO.puts("  High Confidence:   #{stats.high_confidence}")
    IO.puts("  Sources Used:      #{stats.total_sources}")
    IO.puts("  Nodes Executed:    #{stats.nodes_completed}")
    IO.puts("  Iterations:        #{stats.iterations}")
    IO.puts("  Duration:          #{format_duration(duration)}")
    IO.puts("")

    # Show graph structure
    IO.puts(String.duplicate("=", 70))
    IO.puts("RESEARCH GRAPH (DAG)")
    IO.puts(String.duplicate("=", 70))
    IO.puts(DeepResearch.ResearchGraph.to_string(result.graph))

    IO.puts("""

    ╔══════════════════════════════════════════════════════════════════════╗
    ║                         DEMO COMPLETE                                 ║
    ╚══════════════════════════════════════════════════════════════════════╝

    Deep Research demonstrates:
      ✓ Multi-agent coordination with specialized personas
      ✓ DAG-based workflow orchestration (libgraph)
      ✓ Parallel execution of independent research tasks
      ✓ Iterative refinement with gap detection
      ✓ Source tracking and citation management
      ✓ Comprehensive report generation

    For more examples, see:
      - examples/deep_research/README.md
      - examples/README.md

    """)
  end

  defp format_duration(ms) do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
    end
  end
end

# Run the demo
question = Enum.at(System.argv(), 0)
DeepResearchDemo.run(question)

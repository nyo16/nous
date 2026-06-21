#!/usr/bin/env elixir

# Nous AI - Deep Research (Autonomous Research Loop)
#
# Demonstrates Nous.Research.run/2 — the autonomous deep-research subsystem.
# Given a single question, it drives a five-phase loop on its own:
#   1. Planning      - decompose the query into searchable sub-questions
#   2. Searching     - investigate each sub-question with the search tool
#   3. Synthesis     - consolidate findings, detect gaps/contradictions
#   4. Evaluation    - decide whether to iterate again or stop
#   5. Reporting     - produce a cited markdown Report
#
# IMPORTANT: This is the AUTONOMOUS loop. You hand it a question and a search
# tool, and the Coordinator decides what to search, when to dig deeper, and
# when to stop. This is DISTINCT from examples/workflow/research_pipeline.exs,
# which hand-builds a fixed plan -> research -> synthesize Workflow graph where
# YOU wire every node. Reach for Nous.Research when you want the system to plan
# the investigation; reach for Nous.Workflow when you want explicit control.
#
# Run: TAVILY_API_KEY="tvly-..." mix run examples/advanced/deep_research.exs

IO.puts("=== Nous AI - Deep Research ===\n")

# ============================================================================
# Setup: a real search tool is required
# ============================================================================
#
# Nous.Research.run/2 REQUIRES a :search_tool — without web access the loop has
# nothing to investigate. We use the built-in Tavily search tool, which is
# purpose-built for AI research (clean, pre-extracted content).
#
# Setup: export TAVILY_API_KEY="tvly-..."  (get a key at https://tavily.com)

api_key = System.get_env("TAVILY_API_KEY")

if is_nil(api_key) do
  IO.puts("TAVILY_API_KEY not set!")
  IO.puts("Get your key from: https://tavily.com")
  IO.puts("Then run: TAVILY_API_KEY=\"tvly-...\" mix run examples/advanced/deep_research.exs")
  System.halt(1)
end

# ============================================================================
# Run the autonomous research loop
# ============================================================================

query = "What are the best practices for deploying Elixir apps with releases in 2026?"

IO.puts("Query: #{query}\n")
IO.puts("Running autonomous research loop (this calls a live model + web search)...\n")

# Options (see Nous.Research module docs for the full list):
#   :search_tool   - REQUIRED. The function the loop uses to investigate.
#   :model         - model used for planning/synthesis/reporting.
#   :max_iterations - cap on plan->search->synthesize loops.
#   :strategy      - :parallel | :sequential | :tree (how sub-questions run).
#   :deps          - passed through to the search tool (here: the Tavily key).
{:ok, report} =
  Nous.Research.run(query,
    search_tool: &Nous.Tools.TavilySearch.search/2,
    model: "anthropic:claude-sonnet-4-5-20250929",
    max_iterations: 3,
    strategy: :parallel,
    deps: %{tavily_api_key: api_key}
  )

# ============================================================================
# Inspect the returned Report
# ============================================================================
#
# Nous.Research.run/2 returns {:ok, %Nous.Research.Report{}} with:
#   content   - the synthesized markdown report
#   findings  - [%Finding{claim, source_url, confidence, ...}]
#   sources   - [%{url, title}] citations gathered across iterations
#   gaps      - open questions the loop could not fully resolve
#   plus iterations / total_tokens / duration_ms metadata

IO.puts("=== Report: #{report.title} ===\n")
IO.puts(report.content)

# ----------------------------------------------------------------------------
# Findings (each grounded claim, with its confidence and source)
# ----------------------------------------------------------------------------

IO.puts("\n=== Findings (#{length(report.findings)}) ===")

report.findings
|> Enum.take(8)
|> Enum.each(fn finding ->
  confidence = Float.round(finding.confidence * 1.0, 2)
  IO.puts("  [#{confidence}] #{String.slice(finding.claim, 0, 100)}")

  if finding.source_url do
    IO.puts("        source: #{finding.source_url}")
  end
end)

# ----------------------------------------------------------------------------
# Citations (deduplicated sources backing the report)
# ----------------------------------------------------------------------------

IO.puts("\n=== Citations (#{length(report.sources)}) ===")

report.sources
|> Enum.with_index(1)
|> Enum.each(fn {source, idx} ->
  title = source[:title] || source.url
  IO.puts("  [#{idx}] #{title}")
  IO.puts("      #{source.url}")
end)

# ----------------------------------------------------------------------------
# Open gaps (what the loop flagged as unresolved)
# ----------------------------------------------------------------------------

if report.gaps != [] do
  IO.puts("\n=== Open Gaps (#{length(report.gaps)}) ===")
  Enum.each(report.gaps, fn gap -> IO.puts("  - #{gap}") end)
end

# ----------------------------------------------------------------------------
# Run metadata
# ----------------------------------------------------------------------------

IO.puts("\n=== Run Stats ===")
IO.puts("  Iterations:   #{report.iterations}")
IO.puts("  Total tokens: #{report.total_tokens}")
IO.puts("  Duration:     #{report.duration_ms}ms")

IO.puts("""

--- Deep Research vs. Workflow ---

  Nous.Research (this example): autonomous — the loop plans, searches,
    evaluates gaps, and re-plans on its own. You supply a question + tool.

  Nous.Workflow (examples/workflow/research_pipeline.exs): hand-built —
    you define every node and the execution graph yourself.

Next: See examples/workflow/research_pipeline.exs for the manual approach.
""")

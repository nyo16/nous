defmodule Nous.Research do
  @moduledoc """
  Deep Research Agent for nous.

  An autonomous AI system that conducts multi-step, multi-source investigation
  to produce comprehensive cited reports. Unlike simple RAG, deep research
  iteratively plans, searches, analyzes gaps, follows up, and synthesizes.

  ## Quick Start

      {:ok, report} = Nous.Research.run(
        "What are the best practices for Elixir deployment in 2026?",
        model: "anthropic:claude-sonnet-4-5-20250929",
        search_tool: &Nous.Tools.BraveSearch.web_search/2,
        max_iterations: 3
      )

      IO.puts(report.content)

  ## With Human Checkpoints

      Nous.Research.run("Compare React vs Svelte for enterprise apps",
        model: "openai:gpt-4o",
        search_tool: &Nous.Tools.BraveSearch.web_search/2,
        on_plan_ready: fn plan ->
          IO.inspect(plan.steps, label: "Research Plan")
          :approve
        end,
        on_iteration_complete: fn synthesis ->
          IO.puts("Gaps remaining: \#{length(synthesis.gaps)}")
          :continue
        end
      )

  ## Streaming Progress (for LiveView)

      Nous.Research.run("...",
        search_tool: &search/2,
        notify_pid: self()
      )
      # Receives:
      #   {:research_progress, %{phase: :planning, iteration: 0}}
      #   {:research_progress, %{phase: :searching, ...}}
      #   {:research_finding, %{query: "...", phase: :searching}}
      #   {:research_progress, %{phase: :synthesizing, ...}}
      #   {:research_progress, %{phase: :reporting, ...}}

  ## Architecture

  The research loop follows five phases:

  1. **Planning** - Decomposes query into searchable sub-questions
  2. **Searching** - Parallel search agents investigate each sub-question
  3. **Synthesis** - Consolidates findings, detects contradictions, identifies gaps
  4. **Evaluation** - Decides whether to iterate or stop
  5. **Reporting** - Generates structured markdown report with citations

  ## Options

  - `:model` - Model for coordination (default: "openai:gpt-4o-mini")
  - `:search_tool` - Search tool function (required)
  - `:max_iterations` - Maximum research loops (default: 5)
  - `:timeout` - Hard timeout in milliseconds (default: 10 minutes)
  - `:strategy` - `:parallel` | `:sequential` | `:tree` (default: `:parallel`)
  - `:on_plan_ready` - HITL callback for plan review
  - `:on_iteration_complete` - HITL callback between iterations
  - `:callbacks` - `%{on_progress: fn event -> ... end}`
  - `:notify_pid` - PID for progress messages
  - `:deps` - Dependencies for search tools (e.g., API keys)
  """

  alias Nous.Research.{Coordinator, Report}

  @doc """
  Run a deep research session.

  Returns `{:ok, %Report{}}` on success or `{:error, reason}` on failure.

  See module docs for full options list.
  """
  @spec run(String.t(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  defdelegate run(query, opts \\ []), to: Coordinator
end

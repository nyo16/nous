defmodule DeepResearch do
  @moduledoc """
  Deep Research - Multi-Agent Research System

  A production-grade deep research system featuring:
  - 6 specialized agents with distinct personas
  - DAG-based orchestration with dependency tracking
  - Iterative research loops with knowledge gap detection
  - Parallel execution where dependencies allow
  - Comprehensive source tracking with citations

  ## Quick Start

      # Basic usage
      {:ok, result} = DeepResearch.research("What are the leading approaches to AGI?")

      # With progress callback
      DeepResearch.research("Your question",
        callback: fn event -> IO.inspect(event) end
      )

  ## Architecture

  ```
                    ┌─────────────────┐
                    │   Orchestrator  │
                    │   (Supervisor)  │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │ Planner  │   │ Analyst  │   │ Critic   │
        │  Agent   │   │  Agent   │   │  Agent   │
        └────┬─────┘   └────┬─────┘   └────┬─────┘
             │              │              │
             ▼              ▼              ▼
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │Researcher│   │Researcher│   │ Reviewer │
        │  Agent   │   │  Agent   │   │  Agent   │
        └────┬─────┘   └────┬─────┘   └────┬─────┘
             │              │              │
             └──────────────┼──────────────┘
                            ▼
                    ┌──────────────┐
                    │    Writer    │
                    │    Agent     │
                    └──────────────┘
  ```

  ## Agent Personas

  1. **Planner** ("The Strategist") - Decomposes questions into sub-questions
  2. **Researcher** ("The Scout") - Iterative search and content extraction
  3. **Analyst** ("The Synthesizer") - Pattern identification and synthesis
  4. **Critic** ("The Skeptic") - Gap detection and quality assessment
  5. **Reviewer** ("The Validator") - Verification and confidence scoring
  6. **Writer** ("The Narrator") - Report generation with citations
  """

  alias DeepResearch.Orchestrator

  @doc """
  Run deep research on a question.

  ## Options

  - `:model` - LLM model to use (default: auto-detect from env)
  - `:max_iterations` - Maximum research loop iterations (default: 5)
  - `:callback` - Function called with progress updates

  ## Returns

  ```elixir
  {:ok, %{
    question: "Original question",
    sub_questions: ["Sub-question 1", ...],
    report: "# Research Report...",
    findings: [...],
    sources: %{...},
    stats: %{...},
    graph: %Graph{...}
  }}
  ```

  ## Example

      {:ok, result} = DeepResearch.research(
        "What are the implications of quantum computing for cryptography?",
        max_iterations: 3,
        callback: fn
          {:phase, phase} -> IO.puts("Phase: \#{phase}")
          {:researching, node, sq} -> IO.puts("Researching: \#{sq}")
          _ -> :ok
        end
      )

      IO.puts(result.report)
  """
  def research(question, opts \\ []) do
    Orchestrator.run(question, opts)
  end

  @doc """
  Run research with a simple progress logger.
  """
  def research_with_logging(question, opts \\ []) do
    callback = fn event ->
      case event do
        {:started, q} ->
          IO.puts("\n" <> String.duplicate("=", 70))
          IO.puts("DEEP RESEARCH")
          IO.puts(String.duplicate("=", 70))
          IO.puts("Question: #{q}\n")

        {:phase, phase} ->
          IO.puts("\n[PHASE] #{phase |> to_string() |> String.upcase()}")

        {:plan_complete, sub_questions} ->
          IO.puts("  Sub-questions identified: #{length(sub_questions)}")

          Enum.with_index(sub_questions, 1)
          |> Enum.each(fn {sq, i} ->
            IO.puts("    #{i}. #{sq}")
          end)

        {:graph_built, node_count} ->
          IO.puts("  Research graph: #{node_count} nodes")

        {:research_start, nodes} ->
          IO.puts("  Starting #{length(nodes)} research tasks in parallel...")

        {:researching, node, sq} ->
          IO.puts("    [#{node}] #{String.slice(sq, 0..50)}...")

        {:research_done, node, count} ->
          IO.puts("    [#{node}] Done - #{count} findings")

        {:analyzing, sq} ->
          IO.puts("  Analyzing: #{String.slice(sq, 0..40)}...")

        {:critiquing, iteration} ->
          IO.puts("  Critique iteration #{iteration}...")

        {:gaps_found, gaps} ->
          IO.puts("  Found #{length(gaps)} knowledge gaps")

        {:verifying, count} ->
          IO.puts("  Verifying #{count} findings...")

        {:verification_done, count} ->
          IO.puts("  Verified #{count} findings")

        {:complete, stats} ->
          IO.puts("\n" <> String.duplicate("=", 70))
          IO.puts("COMPLETE")
          IO.puts(String.duplicate("=", 70))
          IO.puts("  Findings: #{stats.total_findings}")
          IO.puts("  Verified: #{stats.verified_findings}")
          IO.puts("  Sources: #{stats.total_sources}")
          IO.puts("  Duration: #{stats.duration_ms}ms")
          IO.puts("")

        _ ->
          :ok
      end
    end

    research(question, Keyword.put(opts, :callback, callback))
  end

  @doc """
  Get just the research plan without executing.
  """
  def plan(question, opts \\ []) do
    DeepResearch.Agents.PlannerAgent.plan(question, opts)
  end

  @doc """
  Quick search on a topic without full research workflow.
  """
  def quick_search(query, opts \\ []) do
    DeepResearch.Agents.ResearcherAgent.research(query, opts)
  end
end

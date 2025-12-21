defmodule DeepResearch.Orchestrator do
  @moduledoc """
  DAG-based workflow orchestrator for deep research.

  Coordinates multiple specialized agents through a research workflow:
  1. Planner decomposes the question
  2. Researchers gather information in parallel
  3. Analyst synthesizes findings
  4. Critic identifies gaps (may trigger more research)
  5. Reviewer verifies claims
  6. Writer generates final report

  Uses libgraph for DAG management and Task.async_stream for parallelism.
  """

  require Logger

  alias DeepResearch.{ResearchGraph, ResearchState}

  alias DeepResearch.Agents.{
    PlannerAgent,
    ResearcherAgent,
    AnalystAgent,
    CriticAgent,
    ReviewerAgent,
    WriterAgent
  }

  @default_max_iterations 5

  @doc """
  Run the complete deep research workflow.

  Options:
  - model: LLM model to use (default: auto-detect from env)
  - max_iterations: Maximum research loop iterations (default: 5)
  - callback: Function called with progress updates

  Returns {:ok, result} with report and metadata.
  """
  def run(question, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)

    callback.({:started, question})

    # Phase 1: Planning
    callback.({:phase, :planning})

    with {:ok, plan} <- PlannerAgent.plan(question, opts) do
      callback.({:plan_complete, plan.sub_questions})

      # Build initial state with DAG
      state = build_initial_state(question, plan, max_iterations)
      callback.({:graph_built, ResearchGraph.node_count(state.graph)})

      # Phase 2: Research Loop
      callback.({:phase, :research})
      state = execute_research_loop(state, opts, callback)

      # Phase 3: Analysis
      callback.({:phase, :analysis})
      state = execute_analysis(state, opts, callback)

      # Phase 4: Critique (may trigger more research)
      callback.({:phase, :critique})
      state = execute_critique_loop(state, opts, callback)

      # Phase 5: Verification
      callback.({:phase, :verification})
      state = execute_verification(state, opts, callback)

      # Phase 6: Report Generation
      callback.({:phase, :writing})
      {:ok, report_result} = WriterAgent.generate_report(state, opts)

      callback.({:complete, ResearchState.stats(state)})

      {:ok,
       %{
         question: question,
         sub_questions: state.sub_questions,
         report: report_result.report,
         findings: state.findings,
         sources: state.sources,
         stats: ResearchState.stats(state),
         graph: state.graph
       }}
    end
  end

  @doc """
  Build the initial research state and DAG from the plan.
  """
  def build_initial_state(question, plan, max_iterations) do
    graph = ResearchGraph.build_from_sub_questions(plan.sub_questions)

    %ResearchState{
      question: question,
      sub_questions: plan.sub_questions,
      graph: graph,
      max_iterations: max_iterations,
      started_at: DateTime.utc_now()
    }
  end

  @doc """
  Execute the research phase with parallel execution where possible.
  """
  def execute_research_loop(state, opts, callback) do
    ready_nodes =
      ResearchGraph.ready_nodes(state.graph, state.completed)
      |> Enum.filter(fn node -> node_type(state.graph, node) == :research end)

    if ready_nodes == [] do
      # Mark plan node as complete and try again
      state = ResearchState.complete_node(state, "plan:root")
      ready_nodes = ResearchGraph.ready_nodes(state.graph, state.completed)
                    |> Enum.filter(fn node -> node_type(state.graph, node) == :research end)

      if ready_nodes == [] do
        state
      else
        execute_research_nodes(state, ready_nodes, opts, callback)
      end
    else
      execute_research_nodes(state, ready_nodes, opts, callback)
    end
  end

  defp execute_research_nodes(state, ready_nodes, opts, callback) do
    callback.({:research_start, ready_nodes})

    # Execute research nodes in parallel
    results =
      ready_nodes
      |> Task.async_stream(
        fn node ->
          sub_question = get_node_sub_question(state.graph, node)
          callback.({:researching, node, sub_question})

          case ResearcherAgent.research_with_state(sub_question, state, opts) do
            {:ok, result} ->
              callback.({:research_done, node, extract_new_findings_count(result)})
              {:ok, node, result}

            {:error, reason} ->
              callback.({:research_error, node, reason})
              {:error, node, reason}
          end
        end,
        timeout: 120_000,
        on_timeout: :kill_task,
        max_concurrency: 3
      )
      |> Enum.to_list()

    # Merge results into state
    Enum.reduce(results, state, fn
      {:ok, {:ok, node, result}}, acc ->
        acc
        |> merge_agent_result(result)
        |> ResearchState.complete_node(node)

      {:ok, {:error, node, _reason}}, acc ->
        ResearchState.complete_node(acc, node)

      {:exit, _reason}, acc ->
        acc
    end)
  end

  defp execute_analysis(state, opts, callback) do
    # Run analysis for each sub-question
    Enum.reduce(state.sub_questions, state, fn sq, acc ->
      callback.({:analyzing, sq})

      node = find_analyze_node(state.graph, sq)

      case AnalystAgent.analyze(sq, acc.findings, opts) do
        {:ok, result} ->
          callback.({:analysis_done, sq})

          acc
          |> ResearchState.store_agent_output(node, result)
          |> ResearchState.complete_node(node)

        {:error, _reason} ->
          ResearchState.complete_node(acc, node)
      end
    end)
  end

  defp execute_critique_loop(state, opts, callback) do
    if ResearchState.max_iterations_reached?(state) do
      Logger.info("Max iterations reached, skipping further critique")
      state
    else
      callback.({:critiquing, state.iterations})

      case CriticAgent.analyze(state, opts) do
        {:ok, result} ->
          if result.needs_more_research and state.iterations < state.max_iterations do
            callback.({:gaps_found, result.gaps})

            # Add new research nodes for gaps
            state =
              Enum.reduce(result.gaps, state, fn gap, acc ->
                ResearchState.add_gap(acc, gap)
              end)

            state = ResearchState.increment_iteration(state)

            # Research the first gap
            case List.first(result.gaps) do
              nil ->
                state

              gap ->
                callback.({:researching_gap, gap})

                case ResearcherAgent.research(gap, opts) do
                  {:ok, research_result} ->
                    merge_agent_result(state, research_result)

                  {:error, _} ->
                    state
                end
            end
          else
            callback.({:critique_complete, length(result.gaps)})
            ResearchState.complete_node(state, "critique:coverage")
          end

        {:error, _reason} ->
          ResearchState.complete_node(state, "critique:coverage")
      end
    end
  end

  defp execute_verification(state, opts, callback) do
    unverified_count = Enum.count(state.findings, &(not &1.verified))
    callback.({:verifying, unverified_count})

    case ReviewerAgent.verify_all(state, opts) do
      {:ok, result} ->
        callback.({:verification_done, result.findings_reviewed})
        ResearchState.complete_node(state, "review:verify")

      {:error, _reason} ->
        ResearchState.complete_node(state, "review:verify")
    end
  end

  # Helper functions

  defp node_type(graph, node) do
    case ResearchGraph.get_node(graph, node) do
      %{type: type} -> type
      _ -> :unknown
    end
  end

  defp get_node_sub_question(graph, node) do
    case ResearchGraph.get_node(graph, node) do
      %{sub_question: sq} when is_binary(sq) -> sq
      _ -> node
    end
  end

  defp find_analyze_node(graph, sub_question) do
    ResearchGraph.nodes_by_type(graph, :analyze)
    |> Enum.find(fn node ->
      case ResearchGraph.get_node(graph, node) do
        %{sub_question: ^sub_question} -> true
        _ -> false
      end
    end)
  end

  defp merge_agent_result(state, result) do
    # Extract findings from result if present
    case result do
      %{findings: findings} when is_list(findings) ->
        Enum.reduce(findings, state, fn finding, acc ->
          ResearchState.add_finding(acc, finding)
        end)

      _ ->
        state
    end
  end

  defp extract_new_findings_count(result) do
    case result do
      %{findings: findings} when is_list(findings) -> length(findings)
      _ -> 0
    end
  end
end

defmodule Nous.Research.Coordinator do
  @moduledoc """
  The main research loop coordinator.

  Orchestrates: plan -> search -> synthesize -> evaluate gaps -> re-plan if needed.
  Broadcasts progress via callbacks/PubSub. Supports HITL checkpoints.
  """

  alias Nous.Research.{Planner, Searcher, Synthesizer, Reporter, Finding}

  require Logger

  @type state :: %{
          query: String.t(),
          iteration: non_neg_integer(),
          max_iterations: non_neg_integer(),
          all_findings: [Finding.t()],
          synthesis: map() | nil,
          opts: keyword(),
          start_time: integer(),
          total_tokens: non_neg_integer()
        }

  @doc """
  Run the full research loop.

  ## Options

  - `:model` - Model for coordination/synthesis (default: "openai:gpt-4o-mini")
  - `:search_tool` - Search function or list of tools (required)
  - `:max_iterations` - Max research iterations (default: 5)
  - `:timeout` - Hard timeout in ms (default: 10 minutes)
  - `:strategy` - Planning strategy :parallel | :sequential | :tree (default: :parallel)
  - `:on_plan_ready` - Callback when plan is generated: fn plan -> :approve | {:edit, plan} | :reject end
  - `:on_iteration_complete` - Callback after each iteration: fn synthesis -> :continue | :stop end
  - `:callbacks` - Map of callback functions for progress events
  - `:notify_pid` - PID to receive progress messages
  - `:deps` - Dependencies to pass to search tools
  """
  @spec run(String.t(), keyword()) :: {:ok, Nous.Research.Report.t()} | {:error, term()}
  def run(query, opts \\ []) do
    state = %{
      query: query,
      iteration: 0,
      max_iterations: Keyword.get(opts, :max_iterations, 5),
      all_findings: [],
      synthesis: nil,
      opts: opts,
      start_time: System.monotonic_time(),
      total_tokens: 0
    }

    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))

    # Run with timeout
    task =
      Task.async(fn ->
        research_loop(state)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp research_loop(state) do
    notify(state, {:research_progress, %{phase: :planning, iteration: state.iteration}})

    # Phase 1: Plan
    case plan_phase(state) do
      {:ok, plan, state} ->
        # Check HITL checkpoint for plan
        case check_plan_approval(plan, state) do
          :approve ->
            execute_plan(plan, state)

          {:edit, modified_plan} ->
            execute_plan(modified_plan, state)

          :reject ->
            {:error, :plan_rejected}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plan_phase(state) do
    model = Keyword.get(state.opts, :model, "openai:gpt-4o-mini")
    strategy = Keyword.get(state.opts, :strategy, :parallel)

    # On subsequent iterations, plan based on remaining gaps
    query =
      if state.iteration > 0 && state.synthesis do
        gaps = state.synthesis[:gaps] || []

        if Enum.empty?(gaps) do
          state.query
        else
          "Follow up on these gaps: #{Enum.join(gaps, "; ")} (original question: #{state.query})"
        end
      else
        state.query
      end

    case Planner.plan(query, model: model, strategy: strategy) do
      {:ok, plan} ->
        Logger.info(
          "Research plan created: #{length(plan.steps)} steps (iteration #{state.iteration + 1})"
        )

        {:ok, plan, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_plan(plan, state) do
    notify(
      state,
      {:research_progress,
       %{phase: :searching, iteration: state.iteration, total_steps: length(plan.steps)}}
    )

    # Phase 2: Search - execute all steps
    case search_phase(plan, state) do
      {:ok, new_findings, state} ->
        all_findings = state.all_findings ++ new_findings
        state = %{state | all_findings: all_findings}

        notify(
          state,
          {:research_progress,
           %{phase: :synthesizing, iteration: state.iteration, findings: length(all_findings)}}
        )

        # Phase 3: Synthesize
        case synthesize_phase(state) do
          {:ok, synthesis, state} ->
            state = %{state | synthesis: synthesis, iteration: state.iteration + 1}

            notify(
              state,
              {:research_progress,
               %{
                 phase: :evaluating,
                 iteration: state.iteration,
                 gaps: length(synthesis[:gaps] || [])
               }}
            )

            # Phase 4: Evaluate - should we continue?
            case evaluate_termination(state) do
              :continue ->
                research_loop(state)

              :stop ->
                generate_report(state)
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_phase(plan, state) do
    model = Keyword.get(state.opts, :model, "openai:gpt-4o-mini")
    search_tool = Keyword.get(state.opts, :search_tool)
    deps = Keyword.get(state.opts, :deps, %{})

    # Execute search steps - parallel for :parallel strategy
    case plan.strategy do
      :parallel ->
        search_parallel(plan.steps, model, search_tool, deps, state)

      :sequential ->
        search_sequential(plan.steps, model, search_tool, deps, state)

      _ ->
        search_parallel(plan.steps, model, search_tool, deps, state)
    end
  end

  defp search_parallel(steps, model, search_tool, deps, state) do
    results =
      steps
      |> Task.async_stream(
        fn step ->
          notify(state, {:research_finding, %{query: step.query, phase: :searching}})

          Searcher.search(step.query,
            model: model,
            search_tool: search_tool,
            deps: deps
          )
        end,
        max_concurrency: 5,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, findings}} -> findings
        {:ok, {:error, _}} -> []
        {:exit, _} -> []
      end)

    {:ok, results, state}
  end

  defp search_sequential(steps, model, search_tool, deps, state) do
    {findings, _} =
      Enum.reduce(steps, {[], deps}, fn step, {acc_findings, acc_deps} ->
        notify(state, {:research_finding, %{query: step.query, phase: :searching}})

        case Searcher.search(step.query,
               model: model,
               search_tool: search_tool,
               deps: acc_deps
             ) do
          {:ok, new_findings} ->
            {acc_findings ++ new_findings, acc_deps}

          {:error, _} ->
            {acc_findings, acc_deps}
        end
      end)

    {:ok, findings, state}
  end

  defp synthesize_phase(state) do
    model = Keyword.get(state.opts, :model, "openai:gpt-4o-mini")
    existing_gaps = if state.synthesis, do: state.synthesis[:gaps] || [], else: []

    existing_contradictions =
      if state.synthesis, do: state.synthesis[:contradictions] || [], else: []

    case Synthesizer.synthesize(state.all_findings,
           model: model,
           gaps: existing_gaps,
           contradictions: existing_contradictions
         ) do
      {:ok, synthesis} ->
        {:ok, synthesis, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evaluate_termination(state) do
    cond do
      # Max iterations reached
      state.iteration >= state.max_iterations ->
        Logger.info("Research stopping: max iterations (#{state.max_iterations}) reached")
        :stop

      # No more gaps
      state.synthesis && Enum.empty?(state.synthesis[:gaps] || []) ->
        Logger.info("Research stopping: no remaining knowledge gaps")
        :stop

      # Check HITL callback
      true ->
        case check_iteration_approval(state) do
          :continue -> :continue
          :stop -> :stop
        end
    end
  end

  defp generate_report(state) do
    notify(state, {:research_progress, %{phase: :reporting, iteration: state.iteration}})

    model = Keyword.get(state.opts, :model, "openai:gpt-4o-mini")

    Reporter.generate(
      state.query,
      state.synthesis || %{claims: [], gaps: [], contradictions: []},
      state.all_findings,
      model: model,
      start_time: state.start_time,
      total_tokens: state.total_tokens,
      iterations: state.iteration
    )
  end

  defp check_plan_approval(plan, state) do
    case Keyword.get(state.opts, :on_plan_ready) do
      nil -> :approve
      callback -> callback.(plan)
    end
  end

  defp check_iteration_approval(state) do
    case Keyword.get(state.opts, :on_iteration_complete) do
      nil -> :continue
      callback -> callback.(state.synthesis)
    end
  end

  defp notify(state, event) do
    # Notify via PID
    case Keyword.get(state.opts, :notify_pid) do
      nil -> :ok
      pid -> send(pid, event)
    end

    # Notify via callback
    case Keyword.get(state.opts, :callbacks) do
      %{on_progress: callback} -> callback.(event)
      _ -> :ok
    end

    # Notify via PubSub
    case Keyword.get(state.opts, :session_id) do
      nil ->
        :ok

      session_id ->
        pubsub = Keyword.get(state.opts, :pubsub) || Nous.PubSub.configured_pubsub()
        topic = Nous.PubSub.research_topic(session_id)
        Nous.PubSub.broadcast(pubsub, topic, event)
    end
  end
end

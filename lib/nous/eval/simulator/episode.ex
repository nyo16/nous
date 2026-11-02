defmodule Nous.Eval.Simulator.Episode do
  @moduledoc false
  # One simulated episode: the sample function `Nous.Eval.run/2` runs for a
  # `nous.sim_case/1` case, inside the trace collector's sample task (so the
  # episode's trace id, timeout and kill semantics are the sample's).
  #
  # The agent under test continues one conversation across turns with
  # `Nous.run(agent, text, context: ctx)`, so every turn is a root run of the
  # same trace. The simulator runs once per user turn, stateless, under its
  # own trace id and role `:simulator`: its model events never enter the
  # agent's trace (the trace scorers would read them as the agent's), and the
  # run budget charges them because that trace id is tracked by the ledger.
  #
  # The episode's own events (`[:nous, :eval, :sim, *]`) are telemetry
  # emitted under the episode's scope, so the collector stores them in order
  # with the agent's events and the codec reads them back like any other.
  #
  # Returns `{:ok, %{output: episode}}` for every episode that ended, the
  # `Nous.Errors.ExecutionCancelled` error when the run budget stopped it
  # (the runner makes that sample `:budget_exhausted`).

  alias Nous.Errors.ExecutionCancelled
  alias Nous.Eval.{Budget, Simulator, Summary}
  alias Nous.Eval.Simulator.Scenario
  alias Nous.Telemetry.RunScope
  alias Nous.Usage

  @schema "nous.sim_episode/1"

  @turn_event [:nous, :eval, :sim, :turn]
  @error_event [:nous, :eval, :sim, :error]
  @stop_event [:nous, :eval, :sim, :episode, :stop]

  @doc false
  def schema, do: @schema

  @type args :: %{
          task: module(),
          case: Nous.Eval.Case.t(),
          sample: non_neg_integer(),
          seed: integer() | nil,
          agent: Nous.Agent.t(),
          deps: map(),
          state: term(),
          sim: Simulator.t(),
          budget: Budget.t(),
          check: (-> :ok)
        }

  @spec run(args()) :: {:ok, %{output: map()}} | {:error, ExecutionCancelled.t()}
  def run(%{case: %{input: %Scenario{} = scenario}} = args) do
    started = System.monotonic_time()
    sim_trace = RunScope.new_trace_id()
    :ok = Budget.track(args.budget, sim_trace)

    st = %{
      scenario: scenario,
      sent: 0,
      ctx: nil,
      transcript: [],
      iterations: 0,
      sim_usage: %Usage{},
      sim_trace: sim_trace,
      sim_agent: Simulator.agent(args.sim, scenario),
      error: nil,
      cancelled: nil
    }

    {termination, st, end_state} = with_environment(st, args)
    emit_stop(termination, st, end_state, started)

    case termination do
      :budget -> {:error, st.cancelled}
      _ -> {:ok, %{output: output(termination, st, end_state, args.sim)}}
    end
  end

  # ── environment ──────────────────────────────────────────────────────────

  defp with_environment(st, args) do
    context = %{
      case: args.case,
      sample: args.sample,
      seed: args.seed,
      deps: args.deps,
      state: args.state,
      fixture: st.scenario.fixture
    }

    case setup(args.task, context) do
      {:ok, env} ->
        try do
          {termination, st} = loop(st, args, env)
          {termination, st, end_state(args.task, env)}
        after
          teardown(args.task, env)
        end

      {:error, message} ->
        {:setup_error, %{st | error: message}, :none}
    end
  end

  defp setup(task, context) do
    case callback(task, :episode_setup, [context], {:ok, %{}}) do
      {:ok, {:ok, %{} = env}} when not is_struct(env) ->
        case Map.get(env, :deps, %{}) do
          %{} = deps when not is_struct(deps) -> {:ok, env}
          other -> {:error, "episode_setup/1: env.deps must be a map, got #{inspect(other)}"}
        end

      {:ok, {:error, reason}} ->
        {:error, "episode_setup/1 failed: #{inspect(reason, limit: 20)}"}

      {:ok, other} ->
        {:error,
         "episode_setup/1 must return {:ok, env_map} | {:error, reason}, got " <>
           inspect(other, limit: 10)}

      {:error, message} ->
        {:error, message}
    end
  end

  # `{:ok, map}` (JSON-native), `{:error, message}`, or `:none` when the task
  # reads no end state.
  defp end_state(task, env) do
    if function_exported?(task, :episode_state, 1) do
      case callback(task, :episode_state, [env], nil) do
        {:ok, {:ok, %{} = state}} ->
          {:ok, Summary.plain(state)}

        {:ok, {:error, reason}} ->
          {:error, "episode_state/1 failed: #{inspect(reason, limit: 20)}"}

        {:ok, other} ->
          {:error,
           "episode_state/1 must return {:ok, map} | {:error, reason}, got " <>
             inspect(other, limit: 10)}

        {:error, message} ->
          {:error, message}
      end
    else
      :none
    end
  end

  defp teardown(task, env) do
    _ = callback(task, :episode_teardown, [env], :ok)
    :ok
  end

  defp callback(task, fun, args, default) do
    if function_exported?(task, fun, length(args)),
      do: {:ok, apply(task, fun, args)},
      else: {:ok, default}
  rescue
    e -> {:error, "#{fun}/#{length(args)} raised: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "#{fun}/#{length(args)} #{kind}: #{inspect(reason, limit: 10)}"}
  end

  # ── the conversation ─────────────────────────────────────────────────────

  defp loop(st, args, env) do
    case user_turn(st, args) do
      {:message, text, st} ->
        if st.sent < st.scenario.max_turns do
          case agent_turn(st, text, args, env) do
            {:ok, st} -> loop(st, args, env)
            {:halt, reason, st} -> {reason, st}
          end
        else
          {:max_turns, st}
        end

      {:end, action, st} ->
        {action, st}

      {:halt, reason, st} ->
        {reason, st}
    end
  end

  # Turn 0 may be the case's scripted opener: no simulator call.
  defp user_turn(%{sent: 0, scenario: %Scenario{opener: opener}} = st, _args)
       when is_binary(opener) do
    emit_turn(st, :scripted, %{action: :message, message: opener, thought: nil}, %Usage{}, true)
    {:message, opener, st}
  end

  defp user_turn(st, args) do
    with {:ok, prompt} <- prompt(st),
         {:ok, %{output: output} = result} <- run_simulator(st, prompt, args.check) do
      usage = Map.get(result, :usage) || %Usage{}
      st = %{st | sim_usage: Usage.add(st.sim_usage, usage)}

      case Simulator.parse_action(output) do
        {:ok, %{action: :message, message: message} = action} ->
          emit_turn(st, :llm, action, usage, st.sent < st.scenario.max_turns)
          {:message, message, st}

        {:ok, %{action: action} = parsed} ->
          emit_turn(st, :llm, parsed, usage, false)
          {:end, action, st}

        {:error, reason} ->
          simulator_failed(st, :invalid_output, reason)
      end
    else
      {:error, %ExecutionCancelled{reason: :budget_exhausted} = error} ->
        {:halt, :budget, %{st | cancelled: error}}

      {:error, :boundary_collision} ->
        simulator_failed(st, :fence_collision, "an agent message contains the fence boundary")

      {:error, reason} ->
        simulator_failed(st, :run_failed, describe(reason))
    end
  end

  defp prompt(st), do: Simulator.turn_prompt(st.transcript, st.sent, st.scenario.max_turns)

  defp run_simulator(st, prompt, check) do
    RunScope.with_scope(%{trace_id: st.sim_trace, role: :simulator}, fn ->
      Nous.run(st.sim_agent, prompt, cancellation_check: check)
    end)
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp simulator_failed(st, kind, reason) do
    :telemetry.execute(
      @error_event,
      %{count: 1},
      RunScope.merge(%{turn: st.sent, kind: kind, reason: reason})
    )

    {:halt, :user_error, %{st | error: "the simulator failed (#{kind}): #{reason}"}}
  end

  defp agent_turn(st, text, args, env) do
    turn = st.sent
    st = %{st | sent: turn + 1, transcript: st.transcript ++ [{:user, turn, text}]}

    opts =
      if st.ctx,
        do: [context: st.ctx, cancellation_check: args.check],
        else: [
          deps: Map.merge(args.deps, Map.get(env, :deps, %{})),
          cancellation_check: args.check
        ]

    case Nous.run(args.agent, text, opts) do
      {:ok, result} ->
        {:ok,
         %{
           st
           | ctx: result.context,
             iterations: st.iterations + result.iterations,
             transcript: st.transcript ++ [{:agent, turn, reply(result)}]
         }}

      {:error, %ExecutionCancelled{reason: :budget_exhausted} = error} ->
        {:halt, :budget, %{st | cancelled: error}}

      {:error, reason} ->
        {:halt, :agent_error, %{st | error: "the agent failed: " <> describe(reason)}}
    end
  end

  # This turn's reply: the text output, else the last assistant message of
  # this run (`new_messages` covers only this run on a continued context).
  defp reply(%{output: output}) when is_binary(output), do: output

  defp reply(result) do
    result
    |> Map.get(:new_messages, [])
    |> Enum.filter(&(&1.role == :assistant))
    |> List.last()
    |> case do
      %Nous.Message{} = message -> Nous.Message.extract_text(message)
      nil -> inspect(result.output, limit: 50)
    end
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  # ── events and output ────────────────────────────────────────────────────

  defp emit_turn(st, source, action, usage, sent?) do
    :telemetry.execute(
      @turn_event,
      %{
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        total_tokens: usage.total_tokens
      },
      RunScope.merge(%{
        turn: st.sent,
        source: source,
        action: action.action,
        sent: sent?,
        message: action.message,
        thought: action.thought,
        sim_model: model_name(st.sim_agent),
        sim_trace_id: st.sim_trace,
        template_version: Simulator.template_version()
      })
    )
  end

  defp emit_stop(termination, st, end_state, started) do
    :telemetry.execute(
      @stop_event,
      %{
        duration: System.monotonic_time() - started,
        turns: st.sent,
        agent_iterations: st.iterations,
        simulator_tokens: st.sim_usage.total_tokens
      },
      RunScope.merge(%{
        case_kind: st.scenario.kind,
        termination: termination,
        end_state_status: end_state_status(end_state)
      })
    )
  end

  defp end_state_status({:ok, _}), do: :ok
  defp end_state_status({:error, _}), do: :error
  defp end_state_status(:none), do: :none

  defp model_name(%Nous.Agent{model: model}), do: "#{model.provider}:#{model.model}"

  defp output(termination, st, end_state, sim) do
    %{
      "schema" => @schema,
      "kind" => Atom.to_string(st.scenario.kind),
      "termination" => Atom.to_string(termination),
      "turns" => st.sent,
      "agent_iterations" => st.iterations,
      "transcript" =>
        Enum.map(st.transcript, fn {role, turn, text} ->
          %{"role" => Atom.to_string(role), "turn" => turn, "text" => text}
        end),
      "end_state" => end_state_value(end_state),
      "end_state_error" => end_state_error(end_state),
      "error" => st.error,
      "simulator" => %{
        "model" => sim.model,
        "trace_id" => st.sim_trace,
        "template_version" => Simulator.template_version(),
        "usage" => %{
          "requests" => st.sim_usage.requests,
          "input_tokens" => st.sim_usage.input_tokens,
          "output_tokens" => st.sim_usage.output_tokens,
          "total_tokens" => st.sim_usage.total_tokens
        },
        "cost" => cost(st.sim_usage, st.sim_agent.model)
      }
    }
  end

  defp end_state_value({:ok, state}), do: state
  defp end_state_value(_end_state), do: nil

  defp end_state_error({:error, message}), do: message
  defp end_state_error(_end_state), do: nil

  defp cost(usage, model) do
    case Usage.cost(usage, model) do
      {:ok, %{total: total}} -> total / 1
      {:error, _} -> nil
    end
  end
end

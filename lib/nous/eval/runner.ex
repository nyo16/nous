defmodule Nous.Eval.Runner do
  @moduledoc false
  # Orchestration behind `Nous.Eval.run/2` and `Nous.Eval.rescore/3`; the
  # behaviour is documented there.
  #
  # Order matters for failing closed and for not spending money on a run that
  # cannot finish: options, task, dataset filter and store are checked before
  # `setup/1`; scorer `init/1`s, the fingerprint and the budget pre-flight run
  # before the first model call. `teardown/1` runs whenever `setup/1`
  # succeeded.
  #
  # Samples run in a bounded `Task.Supervisor.async_stream_nolink/4` over
  # (case, index). Each worker admits itself against the budget, builds the
  # agent, runs it under the trace collector (which enforces the per-sample
  # timeout and keeps the partial trace of a killed sample), then scores it.
  # Stopping is cooperative: once the trace handler is found detached (or
  # the budget is exhausted) workers that have not started return at once,
  # so the stream drains without new model calls.

  alias Nous.Eval.{
    Budget,
    CanonicalJSON,
    Case,
    Dataset,
    Fingerprint,
    Run,
    Sample,
    ScoreInput,
    ScorerError,
    Scoring,
    Summary,
    Trace
  }

  alias Nous.Eval.Scorer.Spec
  alias Nous.Eval.Scorers.Judge

  alias Nous.Eval.Task, as: EvalTask
  alias Nous.Eval.Trace.{Collector, Event}
  alias Nous.Telemetry.RunScope

  require Logger

  @run_stop [:nous, :agent, :run, :stop]
  @iteration_start [:nous, :agent, :iteration, :start]

  @run_keys [
    :k,
    :parallelism,
    :timeout,
    :seed,
    :splits,
    :tags,
    :cases,
    :profile,
    :budget,
    :store,
    :scorer_timeout,
    :max_trace_events,
    :max_trace_bytes,
    :metadata
  ]

  @rescore_keys [:parallelism, :store, :scorer_timeout, :budget, :metadata]

  # ── run ────────────────────────────────────────────────────────────────────

  @spec run(module(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run(module, opts) when is_list(opts) do
    with {:ok, config} <- validate(opts, @run_keys),
         {:ok, task} <- EvalTask.load(module),
         {:ok, dataset} <- select(task.dataset, config),
         {:ok, store} <- open_store(config.store) do
      started_at = DateTime.utc_now()

      with_setup(task, opts, fn state ->
        with {:ok, run} <- execute(task, dataset, state, config, started_at, store) do
          persist(store, run)
        end
      end)
    end
  end

  defp select(dataset, config) do
    filters =
      [splits: config.splits, tags: config.tags]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, dataset} <- select_cases(Dataset.filter(dataset, filters), config.cases) do
      case dataset do
        %Dataset{cases: []} -> {:error, :no_cases}
        selected -> {:ok, selected}
      end
    end
  end

  # `cases:` keeps the named ids after the split and tag filters; an id the
  # filtered dataset does not hold is an error, never a silent omission.
  defp select_cases(dataset, nil), do: {:ok, dataset}

  defp select_cases(dataset, ids) do
    known = MapSet.new(dataset.cases, & &1.id)

    case ids |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.uniq() do
      [] ->
        wanted = MapSet.new(ids)
        cases = Enum.filter(dataset.cases, &MapSet.member?(wanted, &1.id))
        # An empty filter only recomputes the hash, over the kept cases.
        {:ok, Dataset.filter(%{dataset | cases: cases}, [])}

      missing ->
        {:error, {:unknown_cases, Enum.sort(missing)}}
    end
  end

  defp with_setup(task, opts, fun) do
    case EvalTask.setup(task, opts) do
      {:ok, state} ->
        try do
          fun.(state)
        after
          case EvalTask.teardown(task, state) do
            :ok -> :ok
            {:error, message} -> Logger.warning("[Nous.Eval] " <> message)
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp execute(task, dataset, state, config, started_at, store) do
    with {:ok, deps} <- EvalTask.deps(task, state),
         {:ok, scorers} <- init_scorers(task, dataset, store),
         {:ok, agent} <- fingerprint_agent(task, dataset, deps, state, config),
         {:ok, fingerprint} <-
           Fingerprint.build(task.module, agent, dataset, task.scorers,
             k: config.k,
             seed: config.seed,
             deps: deps
           ),
         :ok <- Collector.attach(),
         :ok <- Budget.preflight(config.budget, priced_models(agent, scorers)) do
      budget = Budget.start(config.budget)

      try do
        ctx = %{
          task: task,
          deps: deps,
          state: state,
          config: config,
          budget: budget,
          scorers: scorers,
          abort: :atomics.new(1, [])
        }

        {samples, abort_reason} = run_samples(ctx, dataset)

        run = %Run{
          id: new_run_id(started_at),
          task: inspect(task.module),
          status: status(samples, abort_reason),
          started_at: started_at,
          finished_at: DateTime.utc_now(),
          fingerprint: fingerprint,
          dataset_hash: dataset.hash,
          k: config.k,
          seed: config.seed,
          budget: Budget.report(budget),
          samples: samples,
          metadata: abort_metadata(config.metadata, abort_reason)
        }

        {:ok, %{run | summary: Summary.build(run)}}
      after
        Budget.stop(budget)
      end
    end
  end

  # Every distinct case-scorer list is initialized once, after the task's
  # scorers, so a bad option anywhere fails the run before any model call.
  defp init_scorers(task, dataset, store) do
    with {:ok, base} <- scoring_init(task.scorers, store) do
      dataset.cases
      |> Enum.map(& &1.scorers)
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, %{}}, fn specs, {:ok, acc} ->
        case scoring_init(specs, store) do
          {:ok, prepared} -> {:cont, {:ok, Map.put(acc, specs, base ++ prepared)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp scoring_init(specs, store) do
    with {:ok, specs} <- with_calibrations(specs, store) do
      case Scoring.init(specs) do
        {:ok, prepared} -> {:ok, prepared}
        {:error, {module, reason}} -> {:error, {:scorer_init_failed, module, reason}}
      end
    end
  end

  # A judge learns two things only the runner knows: whether it is a gate
  # (its declaration's `required`) and the calibration stored for its exact
  # configuration. The calibration is looked up by the judge's own
  # fingerprint id, so `init/1` runs once to compute it. With no store, or a
  # store without calibrations, the judge is told nothing was looked up and
  # `require_calibration` refuses at scoring time. These options are added
  # here and never to the specs the run fingerprint is built from.
  defp with_calibrations(specs, store) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case calibrated_spec(spec, store) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp calibrated_spec(%Spec{module: Judge} = spec, store) do
    gated = %{spec | opts: Keyword.put(spec.opts, :gate, spec.required)}

    with {:ok, config} <- judge_config(spec),
         {:ok, found} <- stored_calibration(store, Judge.fingerprint_id(config)) do
      case found do
        :not_looked_up -> {:ok, gated}
        calibration -> {:ok, %{gated | opts: Keyword.put(gated.opts, :calibration, calibration)}}
      end
    end
  end

  defp calibrated_spec(spec, _store), do: {:ok, spec}

  defp judge_config(spec) do
    case Judge.init(spec.opts) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:scorer_init_failed, Judge, reason}}
    end
  end

  defp stored_calibration({module, state}, fingerprint_id) do
    if function_exported?(module, :get_calibration, 2) do
      case module.get_calibration(state, fingerprint_id) do
        {:ok, calibration} -> {:ok, calibration}
        {:error, :not_found} -> {:ok, nil}
        {:error, reason} -> {:error, {:store, reason}}
      end
    else
      {:ok, :not_looked_up}
    end
  end

  defp stored_calibration(nil, _fingerprint_id), do: {:ok, :not_looked_up}

  # The agent the fingerprint describes: the first case's first sample. A
  # seed the task copied from the context into `model_settings` is the
  # sample's, not the configuration's (the fingerprint records the base seed).
  defp fingerprint_agent(task, dataset, deps, state, config) do
    [first | _] = dataset.cases
    seed = sample_seed(config.seed, first.id, 0)

    with {:ok, agent} <- build_agent(task, first, 0, seed, deps, state),
         {:ok, agent} <- with_profile(agent, config.profile) do
      if seed != nil and agent.model_settings[:seed] == seed,
        do: {:ok, %{agent | model_settings: Map.delete(agent.model_settings, :seed)}},
        else: {:ok, agent}
    end
  end

  defp build_agent(task, %Case{} = c, index, seed, deps, state) do
    EvalTask.agent(task, %{case: c, sample: index, seed: seed, deps: deps, state: state})
  end

  # `profile:` replaces the text of every agent the task builds. A profile
  # that does not apply to the first case's agent fails the run before any
  # model call; one that fails on a later case's agent fails that sample.
  defp with_profile(agent, nil), do: {:ok, agent}

  defp with_profile(agent, profile) do
    case Nous.Profile.apply(profile, agent) do
      {:ok, agent} -> {:ok, agent}
      {:error, error} -> {:error, {:profile, error}}
    end
  end

  # The models a cost budget must be able to price: the agent's model, its
  # fallbacks, and the judge model every model-graded scorer describes.
  defp priced_models(agent, scorers),
    do: Enum.uniq([agent.model | agent.fallback] ++ judge_models(scorers))

  defp judge_models(scorers) do
    for prepared <- scorers |> Map.values() |> List.flatten() |> Enum.uniq(),
        prepared.kind == :model_graded,
        model = described_model(prepared),
        uniq: true,
        do: model
  end

  defp described_model(%Scoring.Prepared{spec: %{module: module}, config: config}) do
    if function_exported?(module, :describe, 1) do
      case module.describe(config) do
        %{model: model} when is_binary(model) -> model
        %{"model" => model} when is_binary(model) -> model
        _ -> nil
      end
    end
  end

  # ── samples ────────────────────────────────────────────────────────────────

  defp run_samples(ctx, dataset) do
    items = for c <- dataset.cases, index <- 0..(ctx.config.k - 1), do: {c, index}

    results =
      Nous.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(items, &run_item(ctx, &1),
        max_concurrency: ctx.config.parallelism,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.zip(items)
      |> Enum.map(fn
        {{:ok, result}, _item} -> result
        {{:exit, reason}, {c, index}} -> {:sample, crashed(ctx, c, index, reason)}
      end)

    samples =
      for {:sample, sample} <- results do
        sample
      end

    abort_reason =
      Enum.find_value(results, fn
        {:aborted, reason} -> reason
        _ -> nil
      end) || handler_lost()

    {Enum.sort_by(samples, &{&1.case_id, &1.index}), abort_reason}
  end

  # A handler detached after the last sample started leaves no sample to
  # notice it, yet the traces collected after the detach are empty.
  defp handler_lost do
    if Collector.attached?(), do: nil, else: :trace_handler_detached
  end

  defp run_item(ctx, {c, index}) do
    seed = sample_seed(ctx.config.seed, c.id, index)

    cond do
      :atomics.get(ctx.abort, 1) == 1 -> :skipped
      Budget.admit(ctx.budget) == :exhausted -> {:sample, unrun(ctx, c, index, seed)}
      true -> run_one(ctx, c, index, seed)
    end
  end

  defp run_one(ctx, c, index, seed) do
    with {:ok, agent} <- build_agent(ctx.task, c, index, seed, ctx.deps, ctx.state),
         {:ok, agent} <- with_profile(agent, ctx.config.profile) do
      agent = inject_seed(agent, seed)
      trace_id = RunScope.new_trace_id()
      :ok = Budget.track(ctx.budget, trace_id)
      check = Budget.cancellation_check(ctx.budget)

      case Collector.run_sample(
             fn -> invoke(agent, c.input, ctx.deps, check) end,
             sample_opts(ctx.config, trace_id)
           ) do
        {:ok, collected} ->
          {:sample, finish(ctx, c, index, seed, agent, collected)}

        {:error, reason} ->
          :atomics.put(ctx.abort, 1, 1)
          {:aborted, reason}
      end
    else
      {:error, reason} ->
        {:sample,
         %Sample{
           case_id: c.id,
           index: index,
           seed: seed,
           outcome: :error,
           error: sample_error(reason),
           verdict: :error
         }}
    end
  end

  defp sample_error({:profile, error}),
    do: "the profile does not apply: " <> Exception.message(error)

  defp sample_error(message) when is_binary(message), do: message

  defp inject_seed(agent, nil), do: agent

  defp inject_seed(agent, seed),
    do: %{agent | model_settings: Map.put(agent.model_settings, :seed, seed)}

  defp invoke(agent, input, deps, check) when is_binary(input),
    do: Nous.run(agent, input, deps: deps, cancellation_check: check)

  defp invoke(agent, messages, deps, check) when is_list(messages),
    do: Nous.run(agent, messages: messages, deps: deps, cancellation_check: check)

  defp sample_opts(config, trace_id) do
    [
      trace_id: trace_id,
      timeout: config.timeout,
      max_events: config.max_trace_events,
      max_bytes: config.max_trace_bytes
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp finish(ctx, c, index, seed, agent, %{outcome: outcome, trace: trace, duration_ms: ms}) do
    sample = %Sample{
      case_id: c.id,
      index: index,
      seed: seed,
      trace_id: trace.trace_id,
      outcome: outcome_of(outcome),
      output: output_of(outcome),
      error: error_of(outcome, ctx.config.timeout),
      trace: trace,
      usage: Trace.usage(trace),
      cost: cost(trace, agent),
      duration_ms: ms,
      iterations: iterations(trace)
    }

    if sample.outcome == :budget_exhausted do
      sample
    else
      input = %ScoreInput{
        case: c,
        sample: index,
        seed: seed,
        output: sample.output,
        run_outcome: outcome,
        trace: trace,
        usage: sample.usage,
        duration_ms: ms
      }

      apply_scores(sample, score(ctx, c, input))
    end
  end

  defp outcome_of({:ok, _}), do: :ok

  defp outcome_of({:error, %Nous.Errors.ExecutionCancelled{reason: :budget_exhausted}}),
    do: :budget_exhausted

  defp outcome_of({:error, _}), do: :error
  defp outcome_of(:killed), do: :killed

  defp output_of({:ok, %{output: output}}), do: output
  defp output_of(_outcome), do: nil

  defp error_of({:ok, _}, _timeout), do: nil

  defp error_of({:error, %Nous.Errors.ExecutionCancelled{reason: :budget_exhausted}}, _timeout),
    do: "cancelled: the run budget is exhausted"

  defp error_of({:error, {:exit, reason}}, _timeout),
    do: "the agent run crashed: " <> Exception.format_exit(reason)

  defp error_of({:error, %{__exception__: true} = exception}, _timeout),
    do: Exception.message(exception)

  defp error_of({:error, reason}, _timeout), do: inspect(reason, limit: 50)
  defp error_of(:killed, timeout), do: "killed after the #{timeout} ms sample timeout"

  defp apply_scores(%Sample{} = sample, result) do
    %{
      sample
      | verdict: result.verdict,
        case_score: result.case_score,
        scores: result.scores,
        scorer_errors: result.scorer_errors,
        skipped: result.skipped
    }
  end

  # Model-graded scorers are not called once spending has stopped; each
  # becomes a `:budget_exhausted` error, so the sample is `:error`, never a
  # pass on the deterministic scorers alone.
  defp score(ctx, %Case{scorers: specs}, input) do
    prepared = Map.fetch!(ctx.scorers, specs)

    {runnable, starved} =
      if Budget.spend_exhausted?(ctx.budget),
        do: Enum.split_with(prepared, &(&1.kind != :model_graded)),
        else: {prepared, []}

    result = Scoring.score(runnable, input, scoring_opts(ctx.config))

    for %{metadata: %{usage: %Nous.Usage{} = usage} = metadata} <- result.scores do
      Budget.charge(ctx.budget, usage, model_of(metadata[:model]))
    end

    starve(result, starved, Budget.exhausted(ctx.budget))
  end

  defp model_of(%Nous.Model{} = model), do: model
  defp model_of(model) when is_binary(model), do: model
  defp model_of(_), do: nil

  defp scoring_opts(%{scorer_timeout: nil}), do: []
  defp scoring_opts(%{scorer_timeout: timeout}), do: [timeout: timeout]

  defp starve(result, [], _reason), do: result

  defp starve(result, starved, reason) do
    errors =
      Enum.map(starved, fn prepared ->
        %ScorerError{
          scorer: prepared.id,
          kind: :budget_exhausted,
          reason: "not run: the run budget is exhausted (#{reason})"
        }
      end)

    %{result | scorer_errors: result.scorer_errors ++ errors, verdict: :error, case_score: nil}
  end

  defp unrun(ctx, c, index, seed) do
    %Sample{
      case_id: c.id,
      index: index,
      seed: seed,
      outcome: :budget_exhausted,
      error: "not run: the run budget is exhausted (#{Budget.exhausted(ctx.budget)})"
    }
  end

  defp crashed(ctx, c, index, reason) do
    %Sample{
      case_id: c.id,
      index: index,
      seed: sample_seed(ctx.config.seed, c.id, index),
      outcome: :error,
      error: "the eval worker crashed: " <> Exception.format_exit(reason),
      verdict: :error
    }
  end

  # Each answered request priced against the model that answered it; `nil`
  # as soon as one has no price.
  defp cost(trace, agent) do
    calls = trace |> Trace.model_calls() |> Enum.filter(&(&1.outcome == :ok))

    if calls == [] do
      case Nous.Usage.cost(%Nous.Usage{}, agent.model) do
        {:ok, _} -> 0.0
        {:error, _} -> nil
      end
    else
      Enum.reduce_while(calls, 0.0, fn call, acc ->
        provider = call.active_model_provider || call.model_provider
        name = call.active_model_name || call.model_name

        with true <- is_atom(provider) and provider != nil and is_binary(name),
             {:ok, %{total: total}} <-
               Nous.Usage.cost(call.usage, %Nous.Model{provider: provider, model: name}) do
          {:cont, acc + total}
        else
          _ -> {:halt, nil}
        end
      end)
    end
  end

  # From the root run's stop event; a run that never stopped (failed,
  # killed, cancelled) counts the iterations it started.
  defp iterations(trace) do
    case Trace.root_run_id(trace) do
      nil ->
        0

      root ->
        Enum.find_value(trace.events, fn
          %Event{
            name: @run_stop,
            metadata: %{agent_run_id: ^root},
            measurements: %{iterations: n}
          }
          when is_integer(n) ->
            n

          _ ->
            nil
        end) ||
          Enum.count(trace.events, fn
            %Event{name: @iteration_start, metadata: %{agent_run_id: ^root}} -> true
            _ -> false
          end)
    end
  end

  defp status(_samples, reason) when reason != nil, do: :aborted

  defp status(samples, nil) do
    exhausted? =
      Enum.any?(samples, fn sample ->
        sample.outcome == :budget_exhausted or
          Enum.any?(sample.scorer_errors, &(&1.kind == :budget_exhausted))
      end)

    if exhausted?, do: :budget_exhausted, else: :completed
  end

  defp abort_metadata(metadata, nil), do: metadata
  defp abort_metadata(metadata, reason), do: Map.put(metadata, :abort_reason, inspect(reason))

  @doc false
  # The seed of one sample: a deterministic function of the base seed, the
  # case id and the sample index, as a non-negative 31-bit integer (the
  # widest every provider's seed parameter accepts).
  @spec sample_seed(integer() | nil, String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def sample_seed(nil, _case_id, _index), do: nil

  def sample_seed(seed, case_id, index) do
    <<n::unsigned-32, _::binary>> =
      :crypto.hash(:sha256, CanonicalJSON.encode(["nous.eval.seed/1", seed, case_id, index]))

    Bitwise.band(n, 0x7FFFFFFF)
  end

  defp new_run_id(%DateTime{} = at) do
    Calendar.strftime(at, "%Y%m%dt%H%M%Sz") <>
      "-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # ── rescore ────────────────────────────────────────────────────────────────

  @spec rescore(Run.t(), module(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def rescore(%Run{} = source, module, opts) when is_list(opts) do
    with {:ok, config} <- validate(opts, @rescore_keys),
         :ok <- no_sample_limit(config.budget),
         {:ok, task} <- EvalTask.load(module),
         {:ok, dataset} <- rescore_dataset(task.dataset, source),
         {:ok, store} <- open_store(config.store),
         {:ok, scorers} <- init_scorers(task, dataset, store),
         {:ok, fingerprint} <- rescore_fingerprint(source, task, dataset),
         :ok <- Budget.preflight(config.budget, judge_models(scorers)) do
      started_at = DateTime.utc_now()
      budget = Budget.start(config.budget)

      try do
        ctx = %{config: config, budget: budget, scorers: scorers}
        cases = Map.new(dataset.cases, &{&1.id, &1})

        samples =
          Nous.TaskSupervisor
          |> Task.Supervisor.async_stream_nolink(
            source.samples,
            &rescore_sample(ctx, Map.fetch!(cases, &1.case_id), &1),
            max_concurrency: config.parallelism,
            ordered: true,
            timeout: :infinity
          )
          |> Enum.zip(source.samples)
          |> Enum.map(fn
            {{:ok, sample}, _source} ->
              sample

            {{:exit, reason}, sample} ->
              %{
                sample
                | verdict: :error,
                  case_score: nil,
                  error: "the eval worker crashed: " <> Exception.format_exit(reason)
              }
          end)

        run = %Run{
          id: new_run_id(started_at),
          task: inspect(module),
          status: rescore_status(source.status, samples),
          started_at: started_at,
          finished_at: DateTime.utc_now(),
          fingerprint: fingerprint,
          dataset_hash: dataset.hash,
          k: source.k,
          seed: source.seed,
          budget: Budget.report(budget),
          samples: samples,
          metadata:
            source.metadata
            |> Map.merge(config.metadata)
            |> Map.put(:rescored_from, source.id)
        }

        persist(store, %{run | summary: Summary.build(run)})
      after
        Budget.stop(budget)
      end
    end
  end

  # A rescore runs no agent, so only token and cost limits mean anything.
  defp no_sample_limit(%{max_samples: nil}), do: :ok

  defp no_sample_limit(%{max_samples: n}),
    do: {:error, {:invalid_option, :budget, [max_samples: n]}}

  defp rescore_dataset(dataset, %Run{samples: samples}) do
    ids = samples |> Enum.map(& &1.case_id) |> Enum.uniq()
    known = MapSet.new(dataset.cases, & &1.id)

    case Enum.reject(ids, &MapSet.member?(known, &1)) do
      [] ->
        wanted = MapSet.new(ids)
        cases = Enum.filter(dataset.cases, &MapSet.member?(wanted, &1.id))
        # An empty filter only recomputes the hash, over the run's cases.
        {:ok, Dataset.filter(%{dataset | cases: cases}, [])}

      missing ->
        {:error, {:missing_cases, Enum.sort(missing)}}
    end
  end

  # The stored configuration with the task's current scorers and data: the
  # agent did not run again, so everything else describes the traces as they
  # were recorded. The scorer terms do not depend on the agent, so any agent
  # serves to build them.
  defp rescore_fingerprint(%Run{fingerprint: stored}, task, dataset) do
    with {:ok, current} <-
           Fingerprint.build(
             task.module,
             Nous.Agent.new("openai:gpt-4o-mini"),
             dataset,
             task.scorers
           ) do
      fingerprint =
        stored
        |> Map.delete("id")
        |> Map.merge(%{"scorers" => current["scorers"], "dataset" => dataset.hash})

      {:ok, Map.put(fingerprint, "id", CanonicalJSON.hash(fingerprint))}
    end
  end

  # Samples that never reached the scorers (not run, or the agent could not
  # be built, so there is no trace) are carried over as they were.
  defp rescore_sample(_ctx, _case, %Sample{outcome: :budget_exhausted} = sample), do: sample
  defp rescore_sample(_ctx, _case, %Sample{trace: nil} = sample), do: sample

  defp rescore_sample(ctx, c, %Sample{} = sample) do
    input = %ScoreInput{
      case: c,
      sample: sample.index,
      seed: sample.seed,
      output: sample.output,
      run_outcome: stored_outcome(sample),
      trace: sample.trace,
      usage: sample.usage,
      duration_ms: sample.duration_ms
    }

    apply_scores(sample, score(ctx, c, input))
  end

  defp stored_outcome(%Sample{outcome: :ok} = s),
    do: {:ok, %{output: s.output, usage: s.usage, iterations: s.iterations}}

  defp stored_outcome(%Sample{outcome: :killed}), do: :killed
  defp stored_outcome(%Sample{outcome: :error, error: error}), do: {:error, error}

  defp rescore_status(:aborted, _samples), do: :aborted
  defp rescore_status(_status, samples), do: status(samples, nil)

  # ── options & store ────────────────────────────────────────────────────────

  defp validate(opts, keys) do
    case Keyword.split(opts, keys) do
      {known, []} -> check_options(known)
      {_known, unknown} -> {:error, {:unknown_options, Keyword.keys(unknown)}}
    end
  end

  defp check_options(opts) do
    defaults = %{
      k: 3,
      parallelism: System.schedulers_online(),
      timeout: 120_000,
      seed: nil,
      splits: nil,
      tags: nil,
      cases: nil,
      profile: nil,
      budget: nil,
      store: nil,
      scorer_timeout: nil,
      max_trace_events: nil,
      max_trace_bytes: nil,
      metadata: %{}
    }

    opts
    |> Enum.reduce_while({:ok, defaults}, fn {key, value}, {:ok, acc} ->
      if valid_option?(key, value),
        do: {:cont, {:ok, Map.put(acc, key, value)}},
        else: {:halt, {:error, {:invalid_option, key, value}}}
    end)
    |> case do
      {:ok, config} ->
        with {:ok, limits} <- Budget.limits(config.budget), do: {:ok, %{config | budget: limits}}

      error ->
        error
    end
  end

  defp valid_option?(key, value)
       when key in [:k, :parallelism, :timeout] and is_integer(value) and value > 0,
       do: true

  defp valid_option?(key, nil)
       when key in [:seed, :splits, :tags, :cases, :profile, :budget, :store],
       do: true

  defp valid_option?(:seed, seed), do: is_integer(seed)

  defp valid_option?(:splits, splits),
    do: is_list(splits) and splits != [] and Enum.all?(splits, &(&1 in Case.splits()))

  defp valid_option?(:tags, tags),
    do: is_list(tags) and tags != [] and Enum.all?(tags, &is_binary/1)

  defp valid_option?(:cases, ids), do: is_list(ids) and ids != [] and Enum.all?(ids, &is_binary/1)
  defp valid_option?(:profile, profile), do: is_struct(profile, Nous.Profile)

  defp valid_option?(:budget, budget), do: is_list(budget)

  defp valid_option?(:store, {module, opts}), do: is_atom(module) and is_list(opts)

  defp valid_option?(:scorer_timeout, nil), do: true
  defp valid_option?(:scorer_timeout, ms) when is_integer(ms) and ms > 0, do: true

  defp valid_option?(:scorer_timeout, %{} = map) do
    Enum.all?(map, fn {kind, ms} ->
      kind in [:deterministic, :model_graded] and is_integer(ms) and ms > 0
    end)
  end

  defp valid_option?(key, value) when key in [:max_trace_events, :max_trace_bytes],
    do: is_nil(value) or (is_integer(value) and value > 0)

  defp valid_option?(:metadata, metadata), do: is_map(metadata) and not is_struct(metadata)
  defp valid_option?(_key, _value), do: false

  defp open_store(nil), do: {:ok, nil}

  defp open_store({module, opts}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) do
      case module.init(opts) do
        {:ok, state} -> {:ok, {module, state}}
        {:error, reason} -> {:error, {:store, reason}}
      end
    else
      {:error, {:store, {:not_a_store, module}}}
    end
  end

  defp persist(nil, run), do: {:ok, run}

  defp persist({module, state}, run) do
    case module.put_run(state, run) do
      {:ok, _state} -> {:ok, run}
      {:error, reason} -> {:error, {:store_put_failed, reason, run}}
    end
  end
end

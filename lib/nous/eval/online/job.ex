defmodule Nous.Eval.Online.Job do
  @moduledoc false
  # One captured trace through the pipeline, in a task under the instance's
  # bounded `Task.Supervisor`: finalize the trace, split and redact it, build
  # the sample from the redacted trace, score it per rule (only on redacted
  # data, budget reserved before every model-graded scorer), redact the
  # score explanations, and hand the sample to the coordinator.
  #
  # Raw content lives only in this process between `finalize/1` and the
  # redactor's answer. Nothing here logs, and every failure is caught and
  # reduced to a counter: a crash report would print the raw trace.

  alias Nous.Eval.{Case, Sample, Score, ScoreInput, ScorerError, Scoring, Trace}
  alias Nous.Eval.Online.{Config, Counters, Redaction, Sampler}
  alias Nous.Eval.Scoring.Prepared
  alias Nous.Eval.Trace.{Collector, Event, ModelCall}
  alias Nous.Message
  alias Nous.Telemetry.RunScope

  @run_start [:nous, :agent, :run, :start]
  @run_stop [:nous, :agent, :run, :stop]
  @run_exception [:nous, :agent, :run, :exception]
  @score_stop [:nous, :eval, :online, :score, :stop]

  @type ctx :: %{
          config: Config.t(),
          shared: map(),
          coordinator: pid(),
          scorer_sup: atom()
        }

  @doc false
  @spec run(ctx(), String.t(), :closed | :abandoned) :: :ok
  def run(ctx, tid, kind) do
    case :ets.take(ctx.shared.table, tid) do
      [{^tid, rid, started_ms, _state, _changed}] ->
        Counters.add(ctx.shared.counters, :in_flight, -1)
        process(ctx, tid, rid, started_ms, kind)

      [] ->
        :ok
    end
  catch
    _kind, _reason ->
      Counters.add(ctx.shared.counters, :lost)
      :ok
  end

  defp process(ctx, tid, rid, started_ms, kind) do
    %{config: config, shared: shared} = ctx
    raw = Collector.finalize(tid)
    session = session_id(raw, rid)
    {content, keys} = Redaction.split(raw)

    {trace, redaction} =
      case Redaction.redact(config.redact, content, config.redact_timeout, ctx.scorer_sup) do
        {:ok, redacted, status} ->
          case Redaction.rebuild(raw, redacted, keys) do
            {:ok, trace} -> {trace, status}
            {:error, failure} -> {Redaction.skeleton_trace(raw, content), {:failed, failure}}
          end

        {:error, failure} ->
          {Redaction.skeleton_trace(raw, content), {:failed, failure}}
      end

    report_redaction(redaction, config, shared)

    sample = build_sample(trace, rid, started_ms, kind)
    # The capture decision's key and salt, so a rule samples a subset of it.
    sampling_key =
      if config.sample_by == :session and is_binary(session) and session != "",
        do: {session, config.sampling_salt},
        else: {tid, nil}

    {sample, rules} = score(ctx, sample, sampling_key)

    {scores, errors, explanations} =
      Redaction.redact_scores(
        sample.scores,
        sample.scorer_errors,
        tid,
        config.redact,
        config.redact_timeout,
        ctx.scorer_sup
      )

    info = %{
      "captured_at" => captured_at(started_ms),
      "redaction" => status_name(redaction),
      "redaction_failure" => failure_name(redaction),
      "explanations" => status_name(explanations),
      "rules" => rules,
      "abandoned" => kind == :abandoned,
      "group" => group(session || tid)
    }

    send(ctx.coordinator, {:sample, %{sample | scores: scores, scorer_errors: errors}, info})
    :ok
  end

  defp report_redaction({:failed, failure}, config, shared) do
    Counters.add(shared.counters, :redaction_failed)

    :telemetry.execute([:nous, :eval, :online, :redaction_failed], %{count: 1}, %{
      instance: config.instance,
      kind: failure
    })
  end

  defp report_redaction(_status, _config, _shared), do: :ok

  defp status_name(:redacted), do: "redacted"
  defp status_name(:dropped), do: "dropped"
  defp status_name({:failed, _}), do: "failed"

  defp failure_name({:failed, kind}), do: Atom.to_string(kind)
  defp failure_name(_status), do: nil

  # Grouping key for promoted cases (a session's turns stay together),
  # without storing the session id itself.
  defp group(key),
    do: :crypto.hash(:sha256, "nous.online.group:" <> key) |> Base.encode16(case: :lower)

  defp session_id(%Trace{events: events}, rid) do
    Enum.find_value(events, fn
      %Event{name: @run_start, metadata: %{agent_run_id: ^rid, session_id: s}}
      when is_binary(s) ->
        s

      _ ->
        nil
    end)
  end

  defp captured_at(started_ms) do
    DateTime.utc_now()
    |> DateTime.add(started_ms - System.monotonic_time(:millisecond), :millisecond)
    |> DateTime.to_iso8601()
  end

  # ── sample ─────────────────────────────────────────────────────────────────

  defp build_sample(%Trace{} = trace, rid, started_ms, kind) do
    {outcome, error, duration} = outcome(trace, rid, started_ms, kind)
    calls = trace |> Trace.model_calls() |> Enum.filter(&(&1.agent_run_id == rid))

    %Sample{
      case_id: trace.trace_id,
      index: 0,
      trace_id: trace.trace_id,
      outcome: outcome,
      output: if(outcome == :ok, do: output(calls)),
      error: error,
      trace: trace,
      usage: Trace.usage(trace),
      cost: cost(trace),
      duration_ms: duration,
      iterations: iterations(trace, rid)
    }
  end

  defp outcome(trace, rid, started_ms, kind) do
    terminal =
      Enum.find(trace.events, fn %Event{name: name, metadata: meta} ->
        name in [@run_stop, @run_exception] and Map.get(meta, :agent_run_id) == rid
      end)

    case terminal do
      %Event{name: @run_stop} = e ->
        {:ok, nil, duration_ms(e)}

      %Event{name: @run_exception, metadata: meta} = e ->
        {:error, "run failed: " <> (Map.get(meta, :error_kind) || "error"), duration_ms(e)}

      nil ->
        reason = if kind == :abandoned, do: "abandoned", else: "no run stop in the trace"
        {:killed, reason, max(System.monotonic_time(:millisecond) - started_ms, 0)}
    end
  end

  defp duration_ms(%Event{measurements: %{duration: d}}) when is_integer(d) and d >= 0,
    do: System.convert_time_unit(d, :native, :millisecond)

  defp duration_ms(_event), do: 0

  defp output(calls) do
    case calls |> Enum.filter(&(&1.outcome == :ok)) |> List.last() do
      %ModelCall{response: %Message{} = response} -> Message.extract_text(response)
      _ -> nil
    end
  end

  defp input(trace, rid) do
    trace
    |> Trace.model_calls()
    |> Enum.find(&(&1.agent_run_id == rid))
    |> case do
      %ModelCall{messages: messages} when is_list(messages) ->
        messages
        |> Enum.filter(&match?(%Message{role: :user}, &1))
        |> List.last()
        |> case do
          %Message{} = m -> Message.extract_text(m)
          nil -> ""
        end

      _ ->
        ""
    end
  end

  defp cost(trace) do
    trace
    |> Trace.model_calls()
    |> Enum.filter(&(&1.outcome == :ok))
    |> Enum.reduce_while(0.0, fn call, acc ->
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

  defp iterations(trace, rid) do
    Enum.find_value(trace.events, 0, fn
      %Event{name: @run_stop, metadata: %{agent_run_id: ^rid}, measurements: %{iterations: n}}
      when is_integer(n) ->
        n

      _ ->
        nil
    end)
  end

  # ── scoring ────────────────────────────────────────────────────────────────

  defp score(%{config: %{rules: []}}, sample, _key), do: {sample, []}

  defp score(ctx, sample, key) do
    rid = Trace.root_run_id(sample.trace)

    input = %ScoreInput{
      case: %Case{id: sample.case_id, input: input(sample.trace, rid)},
      sample: 0,
      output: sample.output,
      run_outcome: run_outcome(sample),
      trace: sample.trace,
      usage: sample.usage,
      duration_ms: sample.duration_ms
    }

    applied = Enum.filter(ctx.config.rules, &applies?(&1, key, sample))

    results =
      RunScope.with_scope(%{role: :judge}, fn ->
        Enum.flat_map(applied, &score_rule(ctx, &1, input))
      end)

    {compose(sample, results), Enum.map(applied, & &1.name)}
  end

  defp run_outcome(%Sample{outcome: :ok, output: output}), do: {:ok, %{output: output}}
  defp run_outcome(%Sample{outcome: :killed}), do: :killed
  defp run_outcome(%Sample{error: error}), do: {:error, error}

  defp applies?(rule, {key, salt}, sample) do
    Sampler.below?(key, rule.threshold, salt) and when?(rule.when, sample)
  end

  defp when?(nil, _sample), do: true

  defp when?(fun, sample) do
    fun.(sample) == true
  catch
    _kind, _reason -> false
  end

  # Each scorer is scored on its own (`Scoring.score/3` with one scorer),
  # so its duration, cost and status are its own; the scorers of a rule
  # run in parallel.
  defp score_rule(ctx, rule, input) do
    {runnable, starved} =
      Enum.split_with(rule.scorers, fn p -> reserve(ctx, rule, p) != :exhausted end)

    starved_results = Enum.map(starved, &{rule, &1, :skipped_budget, nil, 0, 0.0})

    scope = RunScope.current()

    ran =
      ctx.scorer_sup
      |> Task.Supervisor.async_stream_nolink(
        runnable,
        fn p -> RunScope.with_scope(scope, fn -> timed(ctx, p, input) end) end,
        max_concurrency: max(length(runnable), 1),
        timeout: ctx.config.score_timeout + 5_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(runnable)
      |> Enum.map(fn
        {{:ok, {result, duration}}, p} ->
          cost = settle(ctx, rule, p, result)
          {rule, p, status(result), result, duration, cost}

        {{:exit, _reason}, p} ->
          cost = settle(ctx, rule, p, nil)
          {rule, p, :timeout, timeout_result(p), ctx.config.score_timeout, cost}
      end)

    results = ran ++ starved_results
    Enum.each(results, &report_score(ctx, &1))
    results
  end

  defp timed(ctx, p, input) do
    started = System.monotonic_time()

    result =
      Scoring.score([p], input, supervisor: ctx.scorer_sup, timeout: ctx.config.score_timeout)

    {result, System.monotonic_time() - started}
  end

  defp timeout_result(%Prepared{id: id}) do
    %{
      scores: [],
      scorer_errors: [%ScorerError{scorer: id, kind: :timeout}],
      skipped: [],
      verdict: :error,
      case_score: nil
    }
  end

  defp status(%{scorer_errors: [%ScorerError{kind: :timeout} | _]}), do: :timeout
  defp status(%{scorer_errors: [_ | _]}), do: :error
  defp status(%{skipped: [_ | _]}), do: :skip
  defp status(_result), do: :ok

  defp report_score(ctx, {rule, p, status, _result, duration, cost}) do
    counter =
      case status do
        :ok -> :scored
        :skip -> :scored
        :skipped_budget -> :skipped_budget
        _failed -> :score_failed
      end

    Counters.add(ctx.shared.counters, counter)

    :telemetry.execute(@score_stop, %{duration: duration, cost: cost}, %{
      instance: ctx.config.instance,
      rule: rule.name,
      scorer: p.id,
      status: status
    })
  end

  # ── budget ─────────────────────────────────────────────────────────────────

  defp reserve(%{config: %{budget: nil}}, _rule, _p), do: :ok
  defp reserve(_ctx, _rule, %Prepared{kind: :deterministic}), do: :ok

  defp reserve(ctx, rule, %Prepared{id: id}) do
    case Map.fetch(ctx.config.budget.reserves, {rule.name, id}) do
      {:ok, %{usd: usd}} ->
        GenServer.call(ctx.coordinator, {:reserve, rule.name, id, usd}, 15_000)

      :error ->
        :ok
    end
  catch
    :exit, _ -> :exhausted
  end

  # The actual cost of a model-graded scorer, settled against its
  # reservation. A call whose spend is unknown (an error, a timeout, no
  # usage reported) is charged the whole reservation: it may have been
  # billed.
  defp settle(%{config: %{budget: nil}}, _rule, _p, _result), do: 0.0
  defp settle(_ctx, _rule, %Prepared{kind: :deterministic}, _result), do: 0.0

  defp settle(ctx, rule, %Prepared{id: id}, result) do
    case Map.fetch(ctx.config.budget.reserves, {rule.name, id}) do
      {:ok, %{usd: usd, model: model}} ->
        actual = actual_cost(result, model) || usd
        GenServer.cast(ctx.coordinator, {:settle, usd, actual})
        actual

      :error ->
        0.0
    end
  end

  defp actual_cost(%{scores: scores, scorer_errors: []}, model) do
    usages = for %Score{metadata: %{usage: %Nous.Usage{} = u}} <- scores, do: u

    case usages do
      [] ->
        nil

      usages ->
        usage = Enum.reduce(usages, %Nous.Usage{}, &Nous.Usage.add(&2, &1))

        case Nous.Usage.cost(usage, model) do
          {:ok, %{total: total}} -> total
          {:error, _} -> nil
        end
    end
  end

  defp actual_cost(_result, _model), do: nil

  # ── composition ────────────────────────────────────────────────────────────

  # Every result is named `<rule>/<name>`. The sample verdict is the worst
  # per-scorer verdict (`:error` > `:fail` > `:pass`); `case_score` is the
  # mean of the per-scorer case scores.
  defp compose(%Sample{} = sample, results) do
    named = Enum.map(results, &named/1)
    verdicts = for {_s, _e, _k, verdict, _cs} <- named, verdict != nil, do: verdict
    case_scores = for {_s, _e, _k, _v, cs} <- named, is_float(cs), do: cs

    %Sample{
      sample
      | scores: Enum.flat_map(named, &elem(&1, 0)),
        scorer_errors: Enum.flat_map(named, &elem(&1, 1)),
        skipped: Enum.flat_map(named, &elem(&1, 2)),
        verdict: worst(verdicts),
        case_score:
          if(case_scores == [], do: nil, else: Enum.sum(case_scores) / length(case_scores))
    }
  end

  defp named({rule, p, :skipped_budget, _result, _duration, _cost}),
    do: {[], [], [{rule.name <> "/" <> p.id, "budget_exhausted"}], nil, nil}

  defp named({rule, _p, _status, result, _duration, _cost}) do
    prefix = rule.name <> "/"

    {Enum.map(result.scores, fn %Score{} = s -> %{s | name: prefix <> s.name} end),
     Enum.map(result.scorer_errors, fn %ScorerError{} = e -> %{e | scorer: prefix <> e.scorer} end),
     Enum.map(result.skipped, fn {id, reason} -> {prefix <> id, reason} end), result.verdict,
     result.case_score}
  end

  defp worst([]), do: nil

  defp worst(verdicts) do
    cond do
      :error in verdicts -> :error
      :fail in verdicts -> :fail
      true -> :pass
    end
  end
end

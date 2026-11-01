defmodule Nous.Eval.Scorers.Judge do
  @moduledoc """
  Grades a sample with an LLM judge: a tool-less agent that reads the
  evidence and answers with a verdict from a declared, closed label set.

      {Nous.Eval.Scorers.Judge,
       judge: "openai:gpt-4o-2024-08-06",
       rubric: "The answer states the refund amount and the order number.",
       scale: {:likert, 1, 5, labels: %{1 => "wrong", 5 => "complete and correct"}},
       threshold: 0.75}

  ## Options

    * `:judge` - **required**: the judge model, `"provider:model"` or
      `{"provider:model", model_opts}` (`model_opts` as for
      `Nous.Model.parse/2`, e.g. `base_url:`). There is no fallback to the
      agent's model or a global default. Pin a dated model id: an alias such
      as `-latest` moves under you and logs a warning
    * `:rubric` - the criteria, author-written text (default: "The answer
      correctly and completely addresses the request.")
    * `:scale` - the verdict scale (default `:binary`):
      * `:binary` - `"pass"` 1.0, `"fail"` 0.0
      * `:ternary` or `{:ternary, partial: 0.5}` - `"pass"`, `"partial"`,
        `"fail"`
      * `{:likert, min, max}` or `{:likert, min, max, labels: %{1 => "..."}}`
        - the judge answers a point as a string (`"4"`), normalized to
        `(point - min) / (max - min)`; `labels` describe points in the prompt
      * `{:choices, %{"A" => 1.0, "B" => 0.4, "C" => 0.0}}` - your labels and
        their values in `0.0..1.0`; describe them in the rubric

      Dataset files use `"binary"`, `"ternary"`, `{"ternary": {"partial":
      0.5}}`, `{"likert": {"min": 1, "max": 5, "labels": {"1": "..."}}}` and
      `{"choices": {"A": 1.0, ...}}`.
    * `:threshold` - `passed?` when the normalized value is at least this.
      Required for every scale but `:binary` (whose default is `1.0`)
    * `:include` - what the judge sees (default `[:input, :output]`): any of
      `:input`, `:output`, `:tool_calls` (the root run's tool calls with
      their arguments and results), `:transcript` (the root run's messages),
      `:reference` (the `:reference` option, else the case's
      `expected["output"]`), `:expected` (the case's whole `expected` map)
    * `:samples` - judge calls per sample (default `1`), combined by
      `:reduce`: `:majority` (default; the most frequent label, a tie going
      to the lowest-valued tied label) or `:mean` (the mean value; the
      reported label is the one whose value is closest to it)
    * `:temperature` (default `0`) and `:seed` (default none) - sent as model
      settings; whether the seed reaches the provider depends on the
      provider (see `Nous.Eval.Fingerprint.seed_forwarded?/1`)
    * `:max_span_bytes` - longest piece of evidence sent, in bytes (default
      `20_000`); longer ones are cut with a `…[truncated N bytes]` marker and
      the cut is recorded in the score's metadata
    * `:require_calibration` - `[min_kappa: 0.6, max_false_pass: 0.1]` (or
      `true` for those defaults): refuse to grade unless the
      `:calibration` given is for this exact configuration and meets both
      thresholds. See "Calibration" below
    * `:calibration` - the `Nous.Eval.JudgeCalibration.Result` stored for
      this judge, or `nil` when none was found; set by the runner, not in
      dataset files
    * `:gate` - whether the scorer is a gate (a required scorer); set by the
      runner from the scorer's declaration (default `true`)
    * `:reference` - the reference answer for `include: [:reference]`
    * `:name` - the score name (default `"judge"`)

  ## The judge call

  The judge is `Nous.new(judge, instructions: ..., output_type: %{verdict:
  :string, critique: :string}, structured_output: [max_retries: 1],
  model_settings: %{temperature: 0, seed: seed})`, run with no tools. The
  system prompt holds the template, the rubric and the label set; the
  evidence goes in the user message, every piece (`USER_INPUT`,
  `AGENT_OUTPUT`, `TOOL_CALL_n`, `TRANSCRIPT`, `REFERENCE`, `EXPECTED`) in
  its own fence with a random boundary minted for that request (see
  `Nous.Plugins.InputGuard.Strategies.LLMJudge`). Fence-like markers (`<<<`,
  `>>>`) inside the evidence are broken up before fencing.

  Each judge run executes under its own trace id with role `:judge`, so its
  telemetry never lands in the graded sample's trace. The score's metadata
  carries `judge_trace_id`, the summed judge `usage` (`Nous.Usage`) and the
  judge `model`, for cost accounting.

  ## Results

  The value is the normalized float of the verdict; `passed?` compares it
  with `:threshold`. Metadata holds the raw `label`, every sample's
  `labels`, the `scale`, the `label_values` map, the `prompt_hash` and the
  judge `fingerprint_id`; details hold the judge's `critique` (untrusted
  model text).

  An agent run that failed scores a fail with reason `"run_failed"` without
  calling the judge. A judge that cannot answer is a
  `Nous.Eval.ScorerError`, never a fail: `:judge_unparseable` (no usable
  verdict after the structured-output retry), `:judge_out_of_range` (a
  verdict outside the label set), `:judge_call_failed` (the model call
  failed). With `samples > 1` any failed call makes the score an error.

  ## Calibration

  `describe/1` is the judge's identity: model, provider, temperature, seed,
  prompt hash (template + rubric + labels), scale, threshold, include,
  samples, reduce, span limit and Nous version; `fingerprint_id/1` hashes
  it. `mix nous.eval.judge.calibrate` (`Nous.Eval.JudgeCalibration`) measures
  a judge configuration against human labels and stores the result under
  that id. With `:require_calibration`, a missing (`calibration: nil`), stale
  (another fingerprint) or below-threshold calibration makes `init/1` fail
  with an error, and `score/2` returns an `:invalid_config` error whenever
  the requirement is not met (also when no `:calibration` was passed at
  all). Without it, a gate judge that is not calibrated logs a warning once
  per run.
  """

  @behaviour Nous.Eval.Scorer

  require Logger

  alias Nous.Eval.{CanonicalJSON, JudgeCalibration, Score, ScoreInput, ScorerError, Trace}
  alias Nous.Eval.Scorers.Judge.{Prompt, Scale}
  alias Nous.Eval.Scorers.Options
  alias Nous.Eval.Trace.{Event, ToolCall}
  alias Nous.Fence
  alias Nous.Telemetry.RunScope

  @id "judge"

  @option_keys [
    :judge,
    :rubric,
    :scale,
    :threshold,
    :include,
    :samples,
    :reduce,
    :temperature,
    :seed,
    :max_span_bytes,
    :require_calibration,
    :reference,
    :name
  ]

  # Set by the runner, never from a file.
  @runner_keys [:calibration, :gate]

  @default_rubric "The answer correctly and completely addresses the request."
  @default_include [:input, :output]
  @includes [:input, :transcript, :tool_calls, :output, :reference, :expected]
  @default_requirements %{min_kappa: 0.6, max_false_pass: 0.1}
  @output_type %{verdict: :string, critique: :string}

  # Warnings logged at most once per initialized config (once per run).
  @warn_uncalibrated 1
  @warn_self_grading 2

  @type config :: map()

  @impl true
  def id, do: @id

  @impl true
  def kind, do: :model_graded

  @impl true
  def option_keys, do: @option_keys

  @impl true
  def init(opts) do
    with {:ok, map} <- Options.validate(@id, opts, @option_keys ++ @runner_keys),
         {:ok, model} <- judge_opt(Map.get(map, :judge)),
         {:ok, scale} <- scale_opt(Map.get(map, :scale, :binary)),
         {:ok, threshold} <- threshold_opt(Map.fetch(map, :threshold), scale),
         {:ok, config} <-
           Options.parse(
             map,
             [
               {:rubric, @default_rubric, &Options.string(@id, :rubric, &1)},
               {:include, @default_include, &include_opt/1},
               {:samples, 1, &positive_integer(:samples, &1)},
               {:reduce, :majority, &Options.enum(@id, :reduce, &1, [:majority, :mean])},
               {:temperature, 0, &Options.non_neg_number(@id, :temperature, &1)},
               {:seed, nil, &seed_opt/1},
               {:max_span_bytes, 20_000, &span_limit_opt/1},
               {:require_calibration, nil, &requirements_opt/1},
               {:reference, nil, &reference_opt/1},
               {:name, @id, &Options.string(@id, :name, &1)},
               {:gate, true, &Options.boolean(@id, :gate, &1)}
             ],
             Map.merge(model, %{scale: scale, threshold: threshold})
           ),
         {:ok, calibration} <- calibration_opt(Map.fetch(map, :calibration)) do
      config
      |> Map.put(:calibration, calibration)
      |> finish_config()
      |> check_calibration_at_init()
    end
  end

  defp judge_opt(nil), do: Options.invalid(@id, "judge is required (a model string)")
  defp judge_opt(model) when is_binary(model), do: judge_opt({model, []})

  defp judge_opt({model, model_opts}) when is_binary(model) and is_list(model_opts) do
    if Keyword.keyword?(model_opts) do
      parsed = Nous.Model.parse(model, model_opts)

      {:ok,
       %{
         model: "#{parsed.provider}:#{parsed.model}",
         model_string: model,
         model_opts: model_opts,
         provider: parsed.provider,
         model_name: parsed.model
       }}
    else
      Options.invalid(@id, "judge options must be a keyword list")
    end
  rescue
    e in ArgumentError -> Options.invalid(@id, "invalid judge model: " <> Exception.message(e))
  end

  defp judge_opt(other),
    do:
      Options.invalid(
        @id,
        "judge must be a model string or {model, opts}, got #{inspect(other)}"
      )

  defp scale_opt(value) do
    case Scale.parse(value) do
      {:ok, scale} -> {:ok, scale}
      {:error, message} -> Options.invalid(@id, message)
    end
  end

  defp threshold_opt(:error, %Scale{kind: :binary}), do: {:ok, 1.0}

  defp threshold_opt(:error, %Scale{kind: kind}),
    do: Options.invalid(@id, "threshold is required for a #{kind} scale")

  defp threshold_opt({:ok, value}, _scale), do: Options.unit_float(@id, :threshold, value)

  @include_names Map.new(@includes, &{Atom.to_string(&1), &1})

  defp include_opt([_ | _] = list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      cond do
        item in @includes ->
          {:cont, {:ok, [item | acc]}}

        is_binary(item) and is_map_key(@include_names, item) ->
          {:cont, {:ok, [@include_names[item] | acc]}}

        true ->
          {:halt,
           Options.invalid(
             @id,
             "include: unknown item #{inspect(item)}; allowed: #{inspect(@includes)}"
           )}
      end
    end)
    |> case do
      # Canonical order, so the same set always renders (and hashes) the same.
      {:ok, items} -> {:ok, Enum.filter(@includes, &(&1 in items))}
      error -> error
    end
  end

  defp include_opt(other),
    do: Options.invalid(@id, "include must be a non-empty list, got #{inspect(other)}")

  defp positive_integer(_key, value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(key, value),
    do: Options.invalid(@id, "#{key} must be a positive integer, got #{inspect(value)}")

  defp seed_opt(seed) when is_nil(seed) or is_integer(seed), do: {:ok, seed}
  defp seed_opt(other), do: Options.invalid(@id, "seed must be an integer, got #{inspect(other)}")

  defp span_limit_opt(n) when is_integer(n) and n >= 256, do: {:ok, n}

  defp span_limit_opt(n),
    do: Options.invalid(@id, "max_span_bytes must be an integer >= 256, got #{inspect(n)}")

  defp reference_opt(value) when is_nil(value) or is_binary(value), do: {:ok, value}

  defp reference_opt(other),
    do: Options.invalid(@id, "reference must be a string, got #{inspect(other)}")

  @requirement_keys %{
    "min_kappa" => :min_kappa,
    "max_false_pass" => :max_false_pass,
    :min_kappa => :min_kappa,
    :max_false_pass => :max_false_pass
  }

  defp requirements_opt(value) when value in [nil, false], do: {:ok, nil}
  defp requirements_opt(true), do: {:ok, @default_requirements}

  defp requirements_opt(value) when is_list(value) or is_map(value) do
    if is_list(value) and not Keyword.keyword?(value) do
      requirements_error(value)
    else
      Enum.reduce_while(value, {:ok, @default_requirements}, fn {key, v}, {:ok, acc} ->
        case {Map.get(@requirement_keys, key), v} do
          {:min_kappa, v} when is_number(v) and v >= -1 and v <= 1 ->
            {:cont, {:ok, Map.put(acc, :min_kappa, v / 1)}}

          {:max_false_pass, v} when is_number(v) and v >= 0 and v <= 1 ->
            {:cont, {:ok, Map.put(acc, :max_false_pass, v / 1)}}

          _ ->
            {:halt, requirements_error(value)}
        end
      end)
    end
  end

  defp requirements_opt(other), do: requirements_error(other)

  defp requirements_error(value) do
    Options.invalid(
      @id,
      "require_calibration must be true or [min_kappa: -1..1, max_false_pass: 0..1], " <>
        "got #{inspect(value)}"
    )
  end

  # `:error` (absent) means nobody looked a calibration up yet: `init/1`
  # cannot judge it, `score/2` refuses when one is required. `nil` means it
  # was looked up and not found.
  defp calibration_opt(:error), do: {:ok, :not_provided}
  defp calibration_opt({:ok, nil}), do: {:ok, nil}
  defp calibration_opt({:ok, %JudgeCalibration.Result{} = result}), do: {:ok, result}

  defp calibration_opt({:ok, other}),
    do:
      Options.invalid(
        @id,
        "calibration must be a Nous.Eval.JudgeCalibration.Result or nil, got #{inspect(other)}"
      )

  defp finish_config(config) do
    system = Prompt.system(config.rubric, config.scale)

    agent =
      Nous.new(
        config.model_string,
        config.model_opts ++
          [
            name: "nous_eval_judge",
            instructions: system,
            output_type: @output_type,
            structured_output: [max_retries: 1],
            model_settings: model_settings(config)
          ]
      )

    config =
      Map.merge(config, %{
        system_prompt: system,
        prompt_hash: CanonicalJSON.hash(%{"system" => system, "user" => Prompt.user_template()}),
        agent: agent,
        warned: :atomics.new(2, [])
      })

    if String.contains?(config.model_name, "latest") do
      Logger.warning(
        "[Nous.Eval] judge model #{config.model} is an alias that can change under you; " <>
          "pin a dated model id so verdicts and calibrations stay comparable"
      )
    end

    Map.put(config, :fingerprint_id, CanonicalJSON.hash(describe(config)))
  end

  defp model_settings(%{temperature: temperature, seed: nil}), do: %{temperature: temperature}
  defp model_settings(%{temperature: t, seed: seed}), do: %{temperature: t, seed: seed}

  defp check_calibration_at_init(%{require_calibration: nil} = config), do: {:ok, config}
  defp check_calibration_at_init(%{calibration: :not_provided} = config), do: {:ok, config}

  defp check_calibration_at_init(config) do
    case calibration_status(config) do
      :calibrated -> {:ok, config}
      status -> Options.invalid(@id, refusal(config, status))
    end
  end

  @doc """
  The judge's identity, hashed into the run fingerprint and keying stored
  calibrations: model, provider, temperature, seed, `prompt_hash`
  (template, rubric and label set), scale, threshold, include, samples,
  reduce, span limit and Nous version. Model options (keys, URLs) are not
  part of it.
  """
  @impl true
  def describe(config) do
    %{
      model: config.model,
      provider: Atom.to_string(config.provider),
      temperature: config.temperature,
      seed: config.seed,
      prompt_hash: config.prompt_hash,
      scale: Scale.describe(config.scale),
      threshold: config.threshold,
      include: Enum.map(config.include, &Atom.to_string/1),
      samples: config.samples,
      reduce: Atom.to_string(config.reduce),
      max_span_bytes: config.max_span_bytes,
      nous_version: nous_version()
    }
  end

  @doc """
  The id calibrations of this configuration are stored under:
  `Nous.Eval.CanonicalJSON.hash/1` of `describe/1`.
  """
  @spec fingerprint_id(config()) :: String.t()
  def fingerprint_id(%{fingerprint_id: id}), do: id

  @doc """
  The judge's calibration status: `:calibrated` when the configured
  `:calibration` is for this configuration and meets `:require_calibration`
  (without the option, any matching calibration), else `:not_provided`,
  `:missing`, `:stale` or `{:below_threshold, reason}`.
  """
  @spec calibration_status(config()) ::
          :calibrated | :not_provided | :missing | :stale | {:below_threshold, String.t()}
  def calibration_status(%{calibration: :not_provided}), do: :not_provided

  def calibration_status(config) do
    case JudgeCalibration.check(
           config.calibration,
           config.fingerprint_id,
           config.require_calibration || %{}
         ) do
      :ok -> :calibrated
      {:error, status} -> status
    end
  end

  defp refusal(config, status) do
    "judge #{config.model} requires a calibration (require_calibration) and " <>
      case status do
        :not_provided -> "none was provided"
        :missing -> "none is stored for fingerprint #{config.fingerprint_id}"
        :stale -> "the one provided is for another configuration (stale)"
        {:below_threshold, reason} -> "it is below the threshold: #{reason}"
      end <>
      "; run mix nous.eval.judge.calibrate"
  end

  # ── scoring ──────────────────────────────────────────────────────────────

  @impl true
  def score(%ScoreInput{} = input, config) do
    with :ok <- calibration_gate(config),
         false <- Options.run_failed?(input),
         :ok <- check_trace(input, config),
         {:ok, spans, truncated} <- spans(input, config) do
      warn_self_grading(input, config)
      judge(spans, truncated, config)
    else
      true -> {:ok, %{Options.run_failed_score(config.name) | metadata: base_metadata(config)}}
      {:error, %ScorerError{}} = error -> error
    end
  end

  defp calibration_gate(%{require_calibration: nil} = config) do
    status = calibration_status(config)

    if config.gate and status != :calibrated and once?(config, @warn_uncalibrated) do
      Logger.warning(
        "[Nous.Eval] judge #{config.model} gates samples without a calibration " <>
          "(#{status_text(status)}): its verdicts were not checked against human labels. " <>
          "Run mix nous.eval.judge.calibrate, and set require_calibration to enforce it"
      )
    end

    :ok
  end

  defp calibration_gate(config) do
    case calibration_status(config) do
      :calibrated -> :ok
      status -> error(config, :invalid_config, refusal(config, status))
    end
  end

  defp status_text(:not_provided), do: "none provided"
  defp status_text(:missing), do: "none stored"
  defp status_text(:stale), do: "stale"
  defp status_text({:below_threshold, reason}), do: "below threshold: " <> reason

  defp once?(%{warned: ref}, index), do: :atomics.compare_exchange(ref, index, 0, 1) == :ok

  # Tool calls and the transcript come from the trace. A truncated trace may
  # be missing the very calls the judge should see.
  defp check_trace(%ScoreInput{trace: %Trace{truncated?: true}}, config) do
    if Enum.any?(config.include, &(&1 in [:tool_calls, :transcript])),
      do:
        error(
          config,
          :missing_trace,
          "the trace is truncated; the judge would see partial evidence"
        ),
      else: :ok
  end

  defp check_trace(_input, _config), do: :ok

  # The model under test grading itself biases the verdict; warn once.
  defp warn_self_grading(%ScoreInput{trace: %Trace{events: events}}, config)
       when is_list(events) do
    self_graded? =
      Enum.any?(events, fn
        %Event{name: [:nous, :agent, :run, :start], metadata: %{parent_agent_run_id: nil} = meta} ->
          meta[:model_provider] == config.provider and meta[:model_name] == config.model_name

        _ ->
          false
      end)

    if self_graded? and once?(config, @warn_self_grading) do
      Logger.warning(
        "[Nous.Eval] judge #{config.model} is the model under test: a model grading its own " <>
          "answers is biased; use a different judge model"
      )
    end
  end

  defp warn_self_grading(_input, _config), do: :ok

  # ── evidence ─────────────────────────────────────────────────────────────

  defp spans(input, config) do
    Enum.reduce_while(config.include, {:ok, [], %{}}, fn item, {:ok, spans, truncated} ->
      case raw_spans(item, input, config) do
        {:ok, raw} ->
          {spans, truncated} =
            Enum.reduce(raw, {spans, truncated}, fn {name, text}, {spans, truncated} ->
              {text, dropped} = text |> Fence.neutralize() |> truncate(config.max_span_bytes)
              truncated = if dropped > 0, do: Map.put(truncated, name, dropped), else: truncated
              {[{name, text} | spans], truncated}
            end)

          {:cont, {:ok, spans, truncated}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, spans, truncated} -> {:ok, Enum.reverse(spans), truncated}
      error -> error
    end
  end

  defp raw_spans(:input, %ScoreInput{case: c}, _config),
    do: {:ok, [{"USER_INPUT", input_text(c.input)}]}

  defp raw_spans(:output, input, _config), do: {:ok, [{"AGENT_OUTPUT", to_text(input.output)}]}

  defp raw_spans(:transcript, %ScoreInput{trace: trace}, _config) do
    text = trace |> Trace.transcript() |> Enum.map_join("\n\n", &message_text/1)
    {:ok, [{"TRANSCRIPT", text}]}
  end

  defp raw_spans(:tool_calls, %ScoreInput{trace: trace}, _config) do
    spans =
      trace
      |> Trace.tool_calls(include: :all)
      |> Enum.with_index(1)
      |> Enum.map(fn {call, index} -> {"TOOL_CALL_#{index}", tool_call_text(call)} end)

    {:ok, spans}
  end

  defp raw_spans(:reference, input, config) do
    case Options.expected(%{expected: config.reference}, input) do
      {:ok, reference} ->
        {:ok, [{"REFERENCE", to_text(reference)}]}

      :error ->
        error(
          config,
          :invalid_config,
          "include: :reference but the case has no expected output and no reference option"
        )
    end
  end

  defp raw_spans(:expected, %ScoreInput{case: c}, config) do
    case c.expected do
      expected when expected == %{} or is_nil(expected) ->
        error(config, :invalid_config, "include: :expected but the case has no expected map")

      expected ->
        {:ok, [{"EXPECTED", to_text(expected)}]}
    end
  end

  defp input_text(text) when is_binary(text), do: text

  defp input_text(messages) when is_list(messages),
    do: Enum.map_join(messages, "\n\n", &message_text/1)

  defp input_text(other), do: to_text(other)

  defp message_text(%Nous.Message{} = message) do
    calls =
      for %{} = call <- message.tool_calls || [] do
        name = Map.get(call, "name") || Map.get(call, :name)
        args = Map.get(call, "arguments") || Map.get(call, :arguments)
        "\n(tool call #{name}: #{to_text(args)})"
      end

    "#{message.role}: #{Nous.Message.extract_text(message)}#{Enum.join(calls)}"
  end

  defp message_text(other), do: to_text(other)

  defp tool_call_text(%ToolCall{} = call) do
    result =
      case call do
        %ToolCall{error: error} when not is_nil(error) -> "error: " <> to_text(error)
        %ToolCall{result: result} -> "result: " <> to_text(result)
      end

    Enum.join(
      [
        "name: #{call.name}",
        "outcome: #{call.outcome}",
        "arguments: " <> to_text(call.arguments),
        result
      ],
      "\n"
    )
  end

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text

  defp to_text(term) do
    JSON.encode!(term)
  rescue
    _ -> inspect(term, limit: :infinity, printable_limit: :infinity)
  end

  # Cuts `text` to at most `limit` bytes on a character boundary and marks
  # the cut. Returns the dropped byte count.
  defp truncate(text, limit) when byte_size(text) <= limit, do: {text, 0}

  defp truncate(text, limit) do
    kept = valid_prefix(binary_part(text, 0, limit))
    dropped = byte_size(text) - byte_size(kept)
    {kept <> "…[truncated #{dropped} bytes]", dropped}
  end

  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # ── the judge call ───────────────────────────────────────────────────────

  defp judge(spans, truncated, config) do
    texts = Enum.map(spans, &elem(&1, 1))
    trace_id = RunScope.new_trace_id()

    # A scope of its own: the judge's runs get a fresh trace id and the
    # `:judge` role instead of inheriting the graded sample's scope.
    outcome =
      RunScope.with_scope(%{trace_id: trace_id, role: :judge}, fn ->
        Enum.reduce_while(1..config.samples, {:ok, [], %Nous.Usage{}}, fn _, {:ok, acc, usage} ->
          case call_judge(texts, spans, config) do
            {:ok, verdict, run_usage} ->
              {:cont, {:ok, [verdict | acc], Nous.Usage.add(usage, run_usage)}}

            {:error, kind, reason} ->
              {:halt, {:error, kind, reason}}
          end
        end)
      end)

    case outcome do
      {:ok, verdicts, usage} ->
        {:ok, build_score(Enum.reverse(verdicts), usage, trace_id, truncated, config)}

      {:error, kind, reason} ->
        {:error,
         %ScorerError{
           scorer: config.name,
           kind: kind,
           reason: reason,
           details: %{judge_trace_id: trace_id, model: config.model}
         }}
    end
  end

  defp call_judge(texts, spans, config) do
    case Fence.boundary_for(texts) do
      {:ok, boundary} ->
        run_judge(Prompt.user(spans, boundary), config)

      {:error, :boundary_collision} ->
        {:error, :judge_call_failed, "the evidence contains the fence boundary"}
    end
  end

  defp run_judge(prompt, config) do
    case Nous.run(config.agent, prompt) do
      {:ok, %{output: output, usage: usage}} ->
        verdict(output, usage, config)

      {:error, %Nous.Errors.ValidationError{} = e} ->
        {:error, :judge_unparseable, "no valid verdict object: " <> Exception.message(e)}

      {:error, reason} ->
        {:error, :judge_call_failed, call_error(reason)}
    end
  rescue
    e -> {:error, :judge_call_failed, Exception.message(e)}
  catch
    kind, reason -> {:error, :judge_call_failed, Exception.format_banner(kind, reason)}
  end

  defp call_error(%{__exception__: true} = e), do: Exception.message(e)
  defp call_error(reason), do: inspect(reason, limit: 10)

  defp verdict(%{verdict: verdict} = output, usage, config) when is_binary(verdict) do
    label = String.trim(verdict)
    critique = if is_binary(output[:critique]), do: output.critique

    if Map.has_key?(config.scale.values, label),
      do: {:ok, %{label: label, critique: critique}, usage},
      else:
        {:error, :judge_out_of_range,
         "verdict #{inspect(verdict, printable_limit: 80)} is not one of #{inspect(config.scale.labels)}"}
  end

  defp verdict(output, _usage, _config),
    do:
      {:error, :judge_unparseable,
       "no verdict string in #{inspect(output, limit: 5, printable_limit: 80)}"}

  # ── the score ────────────────────────────────────────────────────────────

  defp build_score(verdicts, usage, trace_id, truncated, config) do
    values = config.scale.values
    labels = Enum.map(verdicts, & &1.label)
    {label, value} = reduce(labels, values, config.reduce)
    passed? = value >= config.threshold
    critique = Enum.find_value(verdicts, & &1.critique)

    details =
      if config.samples > 1,
        do: %{critique: critique, critiques: Enum.map(verdicts, & &1.critique)},
        else: %{critique: critique}

    %Score{
      name: config.name,
      value: value,
      passed?: passed?,
      reason:
        if(passed?, do: nil, else: "judge verdict #{inspect(label)} is below the threshold"),
      details: details,
      metadata:
        Map.merge(base_metadata(config), %{
          label: label,
          labels: labels,
          judge_trace_id: trace_id,
          usage: usage,
          truncated: truncated
        })
    }
  end

  defp base_metadata(config) do
    %{
      model: config.model,
      scale: Scale.describe(config.scale),
      label_values: config.scale.values,
      threshold: config.threshold,
      prompt_hash: config.prompt_hash,
      fingerprint_id: config.fingerprint_id,
      calibration: calibration_label(calibration_status(config))
    }
  end

  defp calibration_label(:calibrated), do: "calibrated"
  defp calibration_label(:not_provided), do: "not_provided"
  defp calibration_label(:missing), do: "missing"
  defp calibration_label(:stale), do: "stale"
  defp calibration_label({:below_threshold, _}), do: "below_threshold"

  # Majority: the most frequent label; a tie goes to the lowest-valued label
  # among the tied, so disagreement never rounds up to a pass.
  defp reduce(labels, values, :majority) do
    {label, _count} =
      labels
      |> Enum.frequencies()
      |> Enum.min_by(fn {label, count} -> {-count, Map.fetch!(values, label), label} end)

    {label, Map.fetch!(values, label)}
  end

  # Mean of the values; the label reported is the one closest to the mean
  # (ties to the lower value).
  defp reduce(labels, values, :mean) do
    mean = Enum.sum(Enum.map(labels, &Map.fetch!(values, &1))) / length(labels)

    {label, _value} =
      Enum.min_by(values, fn {label, value} -> {abs(value - mean), value, label} end)

    {label, mean}
  end

  defp error(config, kind, reason) do
    {:error,
     %ScorerError{
       scorer: config.name,
       kind: kind,
       reason: reason,
       details: %{model: config.model}
     }}
  end

  defp nous_version do
    case Application.spec(:nous, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end
end

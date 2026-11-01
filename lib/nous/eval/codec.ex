defmodule Nous.Eval.Codec do
  @moduledoc """
  The storage format of `Nous.Eval.Run`: a JSON-safe map, and its JSON text.

  Every `Nous.Eval.Store` persists runs as `encode_run_json/1` text and reads
  them back with `decode_run_json/1`, so a run written by one backend reads
  back identically from another. A store you implement outside Nous should
  do the same rather than invent its own serialization.

  ## Versioning

  Every record carries `"schema_version"` (`Nous.Eval.Run.schema_version/0`
  when written). Decoding reads every version up to the current one and
  refuses a newer one with `{:error, {:unsupported_schema_version, v}}`: a
  record written by a later Nous may mean something this release cannot
  represent, and silently dropping what it does not understand would turn a
  baseline into a different run. The decoded struct keeps the version the
  record was written with.

  ## Record shape

  The run, its samples, scores, scorer errors, trace and events are JSON
  objects with string keys named after the struct fields (`truncated?` is
  `"truncated"`, `passed?` is `"passed"`). Enumerated fields (`status`,
  `outcome`, `verdict`, `kind`) are plain strings decoded through literal
  tables; an unknown value is an error, not a guess. `Score.value` is
  `"pass"`, `"fail"`, a number, or `{"label": text}`. A `skipped` entry is a
  `[scorer, reason]` pair. Timestamps are ISO 8601 strings. Cases are
  referenced by `case_id`; the case itself is not stored.

  Event names are lists of strings (`["nous", "agent", "tool_call", "stop"]`)
  and decode only through a closed table of the events Nous emits. An event
  whose name is not in the table is dropped and counted in the trace's
  `dropped`, never turned into a new atom.

  Judge calibrations (`Nous.Eval.JudgeCalibration.Result`) are a separate
  record, `encode_calibration_json/1`, marked `"schema":
  "nous.judge_calibration/1"` and versioned by that marker.

  ## Open values

  Open fields (`fingerprint`, `budget`, `summary`, `metadata`, `output`,
  `details`, event `measurements`/`metadata`) hold arbitrary terms, which
  are encoded as JSON values tagged where JSON has no native form. A tag is
  a single-key object whose key starts with `$`:

    * `{"$atom": "executed"}` - an atom other than `nil`/`true`/`false`
    * `{"$amap": {...}}` - a map whose keys are all atoms
    * `{"$map": [[key, value], ...]}` - any other map that is not a plain
      object (mixed or non-string keys, or a single key starting with `$`)
    * `{"$tuple": [...]}`
    * `{"$dt": iso}`, `{"$ndt": iso}`, `{"$date": iso}`, `{"$time": iso}`
    * `{"$bin": base64}` - a binary that is not valid UTF-8
    * `{"$msg": {...}}` - a `Nous.Message` (e.g. the `messages` of
      `[:nous, :agent, :model, :start]` and the `response` of its `:stop`)
    * `{"$part": {...}}` - a `Nous.Message.ContentPart`
    * `{"$usage": {...}}` - a `Nous.Usage`
    * `{"$struct": [module, fields]}` - any other struct; it decodes to a
      plain map of its fields, because rebuilding an arbitrary struct named
      by stored data is not something a reader should do
    * `{"$opaque": text}` - a term with no data representation (pid,
      reference, port, function, improper list), stored as its `inspect/1`
      text and decoded as that string

  ## Atoms are never created from stored data

  Stored text is untrusted. An atom is decoded through a literal table of
  the atoms Nous's telemetry contract uses, then through
  `String.to_existing_atom/1` (atoms in metadata are data, never dispatched
  on, and an atom some loaded module mentions, such as a guard strategy's
  module name, compares equal to what that module expects). A name that is
  neither stays a string, flagged as `%{"$atom" => name}` so it cannot be
  mistaken for a genuine string; it re-encodes to the same tag. A map key
  that cannot be decoded stays a string key.
  """

  alias Nous.Eval.{JudgeCalibration, Run, Sample, Score, ScorerError, Trace}
  alias Nous.Eval.Store.RunSummary
  alias Nous.Eval.Trace.Event
  alias Nous.Message
  alias Nous.Message.ContentPart

  @known_events [
    [:nous, :agent, :run, :start],
    [:nous, :agent, :run, :stop],
    [:nous, :agent, :run, :exception],
    [:nous, :agent, :iteration, :start],
    [:nous, :agent, :iteration, :stop],
    [:nous, :agent, :model, :start],
    [:nous, :agent, :model, :stop],
    [:nous, :agent, :model, :exception],
    [:nous, :agent, :tool_call, :start],
    [:nous, :agent, :tool_call, :stop],
    [:nous, :agent, :structured_output, :retry],
    [:nous, :agent, :fallback, :used],
    [:nous, :fallback, :activated],
    [:nous, :router, :route],
    [:nous, :rate_limiter, :unavailable],
    [:nous, :provider, :request, :start],
    [:nous, :provider, :request, :stop],
    [:nous, :provider, :request, :exception],
    [:nous, :provider, :stream, :start],
    [:nous, :provider, :stream, :connected],
    [:nous, :provider, :stream, :exception],
    [:nous, :tool, :execute, :start],
    [:nous, :tool, :execute, :stop],
    [:nous, :tool, :execute, :exception],
    [:nous, :tool, :timeout],
    [:nous, :context, :update],
    [:nous, :callback, :execute],
    [:nous, :hook, :execute, :start],
    [:nous, :hook, :execute, :stop],
    [:nous, :hook, :denied],
    [:nous, :hook, :failed_closed],
    [:nous, :hook, :decision],
    [:nous, :decision_guard, :verdict],
    [:nous, :decision_guard, :canary_failed],
    [:nous, :decision_guard, :strategy_dropped],
    [:nous, :decision_guard, :strategy_verdict],
    [:nous, :input_guard, :strategy_dropped],
    [:nous, :input_guard, :strategy_verdict],
    [:nous, :input_guard, :verdict],
    [:nous, :loop_guard, :advisory],
    [:nous, :skill, :activate],
    [:nous, :skill, :deactivate],
    [:nous, :compaction, :start],
    [:nous, :compaction, :stop],
    [:nous, :compaction, :exception],
    [:nous, :decision_model, :decide, :start],
    [:nous, :decision_model, :decide, :stop],
    [:nous, :decision_model, :decide, :exception],
    [:nous, :session, :invariant, :violation],
    [:nous, :workflow, :run, :start],
    [:nous, :workflow, :run, :stop],
    [:nous, :workflow, :run, :exception],
    [:nous, :workflow, :node, :start],
    [:nous, :workflow, :node, :stop],
    [:nous, :workflow, :node, :exception]
  ]

  @event_table Map.new(@known_events, fn name -> {Enum.map(name, &Atom.to_string/1), name} end)

  # The closed sets of the telemetry contract (telemetry-naming.md §1, §5) and
  # the eval structs: values and the metadata/measurement keys. Being literals
  # here guarantees the atoms exist whenever this module is loaded, so a stored
  # trace decodes the same way before the emitting modules (or the scorer that
  # reads `metadata.outcome`) have been loaded.
  @known_atoms ~w(
    trace_id agent_run_id parent_agent_run_id parent_tool_call_id tool_call_id
    profile_id role sub_agent_template sub_agent_index
    agent_name model_provider model_name tool_count has_tools active_model_provider
    active_model_name fallback_used kind reason stacktrace
    system_time monotonic_time duration total_tokens input_tokens output_tokens
    requests iterations cache_creation_input_tokens cache_read_input_tokens
    time_to_first_token iteration max_iterations needs_response
    original_provider original_model active_provider active_model failed_provider
    failed_model next_provider next_model router granularity turn cause tier
    probabilities confidence count provider message_count has_tool_calls
    tool_name tool_module attempt max_retries has_timeout success will_retry
    keys_updated keys callback_type event hook_name hook_type result verdict
    canary_failed backend model chunk_count surface aggregation fail_closed
    strategy severity details skill_name group activation_type messages_before
    messages_after llm_called summarized usage bytes_before bytes_after
    question_count mode workflow_id workflow_name node_count status
    nodes_executed node_id node_type stream tool_names blocked_tool_names
    messages finish_reason requested_tool_calls response arguments outcome
    approval result_modified retries_left errors strategies dropped action
    chain_length threshold signatures id name media_type content_parts
    ok error pass fail skip label
    completed budget_exhausted aborted killed
    executed invalid_arguments collapsed hook_denied hook_stage_failed
    approval_rejected not_found timeout crashed
    not_required approved edited rejected
    agent judge simulator reflector
    system user assistant tool
    raised invalid_config missing_trace judge_unparseable judge_out_of_range
    judge_call_failed non_finite
    allow deny escalate safe suspicious blocked
    user_input tool_call tool_result model_output
    exit throw stop length tool_calls content_filter
    openai anthropic gemini vertex_ai groq mistral ollama lmstudio llamacpp
    openrouter together vllm sglang openai_compatible custom
    text image_url image file file_url thinking
  )a

  @atom_table Map.new(@known_atoms, &{Atom.to_string(&1), &1})

  @statuses %{
    "completed" => :completed,
    "budget_exhausted" => :budget_exhausted,
    "aborted" => :aborted
  }
  @outcomes %{
    "ok" => :ok,
    "error" => :error,
    "killed" => :killed,
    "budget_exhausted" => :budget_exhausted
  }
  @verdicts %{"pass" => :pass, "fail" => :fail, "error" => :error}
  @scorer_error_kinds Map.new(ScorerError.kinds(), &{Atom.to_string(&1), &1})

  @calibration_schema "nous.judge_calibration/1"
  @kappa_kinds %{"cohen" => :cohen, "quadratic_weighted" => :quadratic_weighted}

  @usage_fields Nous.Usage.__struct__() |> Map.from_struct() |> Map.keys()

  @typedoc "A JSON-safe map: only string keys, strings, numbers, booleans, nil, lists, maps."
  @type json_map :: %{String.t() => term()}

  ## Runs

  @doc """
  Encodes `run` as a JSON-safe map.

  Returns `{:error, {:invalid_field, {struct, field}, value}}` when a struct
  field does not hold the type its struct documents (an unknown `status`, a
  non-string `error`): such a record could not be read back faithfully.
  """
  @spec encode_run(Run.t()) :: {:ok, json_map()} | {:error, term()}
  def encode_run(%Run{} = run), do: catch_invalid(fn -> do_encode_run(run) end)

  @doc "Encodes `run` as its storage JSON text. See `encode_run/1`."
  @spec encode_run_json(Run.t()) :: {:ok, String.t()} | {:error, term()}
  def encode_run_json(%Run{} = run) do
    with {:ok, map} <- encode_run(run), do: {:ok, JSON.encode!(map)}
  end

  @doc """
  Decodes a map produced by `encode_run/1` (or read back from JSON).

  Returns `{:error, {:unsupported_schema_version, v}}` for a record newer
  than this release, `{:error, {:invalid_field, ...}}` /
  `{:error, {:invalid_value, ...}}` for a malformed one.
  """
  @spec decode_run(map()) :: {:ok, Run.t()} | {:error, term()}
  def decode_run(%{} = data) do
    with {:ok, version} <- check_version(data) do
      catch_invalid(fn -> do_decode_run(version, data) end)
    end
  end

  @doc "Decodes storage JSON text. See `decode_run/1`."
  @spec decode_run_json(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def decode_run_json(text) when is_binary(text) do
    with {:ok, data} <- decode_json(text), do: decode_run(data)
  end

  ## Summaries

  @doc "Encodes a `Nous.Eval.Store.RunSummary` as a JSON-safe map."
  @spec encode_summary(RunSummary.t()) :: {:ok, json_map()} | {:error, term()}
  def encode_summary(%RunSummary{} = summary),
    do: catch_invalid(fn -> do_encode_summary(summary) end)

  @doc "Encodes a `Nous.Eval.Store.RunSummary` as JSON text."
  @spec encode_summary_json(RunSummary.t()) :: {:ok, String.t()} | {:error, term()}
  def encode_summary_json(%RunSummary{} = summary) do
    with {:ok, map} <- encode_summary(summary), do: {:ok, JSON.encode!(map)}
  end

  @doc "Decodes a summary map. Versioned like `decode_run/1`."
  @spec decode_summary(map()) :: {:ok, RunSummary.t()} | {:error, term()}
  def decode_summary(%{} = data) do
    with {:ok, version} <- check_version(data) do
      catch_invalid(fn -> do_decode_summary(version, data) end)
    end
  end

  @doc "Decodes summary JSON text. See `decode_summary/1`."
  @spec decode_summary_json(String.t()) :: {:ok, RunSummary.t()} | {:error, term()}
  def decode_summary_json(text) when is_binary(text) do
    with {:ok, data} <- decode_json(text), do: decode_summary(data)
  end

  ## Judge calibrations

  @doc """
  Encodes a `Nous.Eval.JudgeCalibration.Result` as a JSON-safe map with
  `"schema": "nous.judge_calibration/1"`. Intervals become `{"estimate",
  "lower", "upper", "count", "n"}` objects; enumerated fields (`kappa_kind`,
  error `kind`) plain strings.
  """
  @spec encode_calibration(JudgeCalibration.Result.t()) :: {:ok, json_map()} | {:error, term()}
  def encode_calibration(%JudgeCalibration.Result{} = result),
    do: catch_invalid(fn -> do_encode_calibration(result) end)

  @doc "Encodes a calibration as JSON text. See `encode_calibration/1`."
  @spec encode_calibration_json(JudgeCalibration.Result.t()) ::
          {:ok, String.t()} | {:error, term()}
  def encode_calibration_json(%JudgeCalibration.Result{} = result) do
    with {:ok, map} <- encode_calibration(result), do: {:ok, JSON.encode!(map)}
  end

  @doc """
  Decodes a map produced by `encode_calibration/1`. A record with another
  `"schema"` is `{:error, {:unsupported_schema, schema}}`.
  """
  @spec decode_calibration(map()) :: {:ok, JudgeCalibration.Result.t()} | {:error, term()}
  def decode_calibration(%{"schema" => @calibration_schema} = data),
    do: catch_invalid(fn -> do_decode_calibration(data) end)

  def decode_calibration(%{} = data), do: {:error, {:unsupported_schema, data["schema"]}}

  @doc "Decodes calibration JSON text. See `decode_calibration/1`."
  @spec decode_calibration_json(String.t()) ::
          {:ok, JudgeCalibration.Result.t()} | {:error, term()}
  def decode_calibration_json(text) when is_binary(text) do
    with {:ok, data} <- decode_json(text), do: decode_calibration(data)
  end

  ## Open values

  @doc false
  @spec encode_value(term()) :: term()
  def encode_value(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value

  def encode_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$bin" => Base.encode64(value)}
  end

  def encode_value(value) when is_atom(value), do: %{"$atom" => Atom.to_string(value)}

  def encode_value(value) when is_list(value) do
    case encode_list(value, []) do
      :improper -> opaque(value)
      list -> list
    end
  end

  def encode_value(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> Enum.map(&encode_value/1)}

  def encode_value(%DateTime{} = dt), do: %{"$dt" => DateTime.to_iso8601(dt)}
  def encode_value(%NaiveDateTime{} = dt), do: %{"$ndt" => NaiveDateTime.to_iso8601(dt)}
  def encode_value(%Date{} = date), do: %{"$date" => Date.to_iso8601(date)}
  def encode_value(%Time{} = time), do: %{"$time" => Time.to_iso8601(time)}
  def encode_value(%Message{} = message), do: %{"$msg" => encode_message(message)}

  def encode_value(%ContentPart{} = part) do
    %{
      "$part" => %{
        "type" => encode_value(part.type),
        "content" => encode_value(part.content),
        "options" => encode_value(part.options)
      }
    }
  end

  def encode_value(%Nous.Usage{} = usage), do: %{"$usage" => encode_usage(usage)}

  def encode_value(%module{} = struct) do
    %{"$struct" => [Atom.to_string(module), encode_value(Map.from_struct(struct))]}
  end

  # A value that decoded from an unknown atom re-encodes as the same tag.
  def encode_value(%{"$atom" => name} = flagged) when is_binary(name) and map_size(flagged) == 1,
    do: flagged

  def encode_value(%{} = map) when map_size(map) == 0, do: %{}

  def encode_value(%{} = map) do
    cond do
      plain_object?(map) -> Map.new(map, fn {k, v} -> {k, encode_value(v)} end)
      Enum.all?(Map.keys(map), &is_atom/1) -> %{"$amap" => encode_atom_map(map)}
      true -> %{"$map" => Enum.map(map, fn {k, v} -> [encode_value(k), encode_value(v)] end)}
    end
  end

  def encode_value(other), do: opaque(other)

  @doc false
  @spec decode_value(term()) :: {:ok, term()} | {:error, term()}
  def decode_value(value), do: catch_invalid(fn -> dec(value) end)

  ## Run internals

  defp do_encode_run(%Run{} = run) do
    %{
      "schema_version" => Run.schema_version(),
      "id" => string!(run.id, {Run, :id}),
      "task" => opt_string!(run.task, {Run, :task}),
      "status" => enum_out!(@statuses, run.status, {Run, :status}),
      "started_at" => opt_dt_out!(run.started_at, {Run, :started_at}),
      "finished_at" => opt_dt_out!(run.finished_at, {Run, :finished_at}),
      "fingerprint" => map_out!(run.fingerprint, {Run, :fingerprint}),
      "dataset_hash" => opt_string!(run.dataset_hash, {Run, :dataset_hash}),
      "k" => int!(run.k, {Run, :k}),
      "seed" => opt_int!(run.seed, {Run, :seed}),
      "budget" => map_out!(run.budget, {Run, :budget}),
      "samples" => list!(run.samples, {Run, :samples}) |> Enum.map(&encode_sample/1),
      "summary" => map_out!(run.summary, {Run, :summary}),
      "metadata" => map_out!(run.metadata, {Run, :metadata})
    }
  end

  # One clause per record version: an older version is migrated here, field
  # by field, into the current struct.
  defp do_decode_run(1, data) do
    %Run{
      id: string!(data["id"], {Run, :id}),
      schema_version: data["schema_version"],
      task: opt_string!(data["task"], {Run, :task}),
      status: enum_in!(@statuses, data["status"], {Run, :status}),
      started_at: opt_dt_in!(data["started_at"], {Run, :started_at}),
      finished_at: opt_dt_in!(data["finished_at"], {Run, :finished_at}),
      fingerprint: map_in!(data["fingerprint"], {Run, :fingerprint}),
      dataset_hash: opt_string!(data["dataset_hash"], {Run, :dataset_hash}),
      k: int!(data["k"], {Run, :k}),
      seed: opt_int!(data["seed"], {Run, :seed}),
      budget: map_in!(data["budget"], {Run, :budget}),
      samples: list!(data["samples"], {Run, :samples}) |> Enum.map(&decode_sample/1),
      summary: map_in!(data["summary"], {Run, :summary}),
      metadata: map_in!(data["metadata"], {Run, :metadata})
    }
  end

  defp do_encode_summary(%RunSummary{} = s) do
    %{
      "schema_version" => Run.schema_version(),
      "id" => string!(s.id, {RunSummary, :id}),
      "task" => opt_string!(s.task, {RunSummary, :task}),
      "status" => enum_out!(@statuses, s.status, {RunSummary, :status}),
      "started_at" => opt_dt_out!(s.started_at, {RunSummary, :started_at}),
      "finished_at" => opt_dt_out!(s.finished_at, {RunSummary, :finished_at}),
      "dataset_hash" => opt_string!(s.dataset_hash, {RunSummary, :dataset_hash}),
      "k" => int!(s.k, {RunSummary, :k}),
      "seed" => opt_int!(s.seed, {RunSummary, :seed}),
      "sample_count" => int!(s.sample_count, {RunSummary, :sample_count}),
      "summary" => map_out!(s.summary, {RunSummary, :summary}),
      "metadata" => map_out!(s.metadata, {RunSummary, :metadata})
    }
  end

  defp do_decode_summary(1, data) do
    %RunSummary{
      id: string!(data["id"], {RunSummary, :id}),
      schema_version: data["schema_version"],
      task: opt_string!(data["task"], {RunSummary, :task}),
      status: enum_in!(@statuses, data["status"], {RunSummary, :status}),
      started_at: opt_dt_in!(data["started_at"], {RunSummary, :started_at}),
      finished_at: opt_dt_in!(data["finished_at"], {RunSummary, :finished_at}),
      dataset_hash: opt_string!(data["dataset_hash"], {RunSummary, :dataset_hash}),
      k: int!(data["k"], {RunSummary, :k}),
      seed: opt_int!(data["seed"], {RunSummary, :seed}),
      sample_count: int!(data["sample_count"], {RunSummary, :sample_count}),
      summary: map_in!(data["summary"], {RunSummary, :summary}),
      metadata: map_in!(data["metadata"], {RunSummary, :metadata})
    }
  end

  defp encode_sample(%Sample{} = s) do
    %{
      "case_id" => string!(s.case_id, {Sample, :case_id}),
      "index" => int!(s.index, {Sample, :index}),
      "seed" => opt_int!(s.seed, {Sample, :seed}),
      "trace_id" => opt_string!(s.trace_id, {Sample, :trace_id}),
      "outcome" => enum_out!(@outcomes, s.outcome, {Sample, :outcome}),
      "output" => encode_value(s.output),
      "error" => opt_string!(s.error, {Sample, :error}),
      "verdict" => opt_enum_out!(@verdicts, s.verdict, {Sample, :verdict}),
      "case_score" => opt_number!(s.case_score, {Sample, :case_score}),
      "scores" => list!(s.scores, {Sample, :scores}) |> Enum.map(&encode_score/1),
      "scorer_errors" =>
        list!(s.scorer_errors, {Sample, :scorer_errors}) |> Enum.map(&encode_scorer_error/1),
      "skipped" => list!(s.skipped, {Sample, :skipped}) |> Enum.map(&encode_skipped/1),
      "trace" => encode_trace(s.trace),
      "usage" => encode_usage(s.usage),
      "cost" => opt_number!(s.cost, {Sample, :cost}),
      "duration_ms" => int!(s.duration_ms, {Sample, :duration_ms}),
      "iterations" => int!(s.iterations, {Sample, :iterations})
    }
  end

  defp encode_sample(other), do: invalid!({Run, :samples}, other)

  defp decode_sample(%{} = d) do
    %Sample{
      case_id: string!(d["case_id"], {Sample, :case_id}),
      index: int!(d["index"], {Sample, :index}),
      seed: opt_int!(d["seed"], {Sample, :seed}),
      trace_id: opt_string!(d["trace_id"], {Sample, :trace_id}),
      outcome: enum_in!(@outcomes, d["outcome"], {Sample, :outcome}),
      output: dec(d["output"]),
      error: opt_string!(d["error"], {Sample, :error}),
      verdict: opt_enum_in!(@verdicts, d["verdict"], {Sample, :verdict}),
      case_score: opt_number!(d["case_score"], {Sample, :case_score}),
      scores: list!(d["scores"], {Sample, :scores}) |> Enum.map(&decode_score/1),
      scorer_errors:
        list!(d["scorer_errors"], {Sample, :scorer_errors}) |> Enum.map(&decode_scorer_error/1),
      skipped: list!(d["skipped"], {Sample, :skipped}) |> Enum.map(&decode_skipped/1),
      trace: decode_trace(d["trace"]),
      usage: decode_usage(d["usage"], {Sample, :usage}),
      cost: opt_number!(d["cost"], {Sample, :cost}),
      duration_ms: int!(d["duration_ms"], {Sample, :duration_ms}),
      iterations: int!(d["iterations"], {Sample, :iterations})
    }
  end

  defp decode_sample(other), do: invalid!({Run, :samples}, other)

  defp encode_score(%Score{} = s) do
    %{
      "name" => string!(s.name, {Score, :name}),
      "value" => encode_score_value(s.value),
      "passed" => bool!(s.passed?, {Score, :passed?}),
      "reason" => opt_string!(s.reason, {Score, :reason}),
      "details" => map_out!(s.details, {Score, :details}),
      "metadata" => map_out!(s.metadata, {Score, :metadata})
    }
  end

  defp encode_score(other), do: invalid!({Sample, :scores}, other)

  defp decode_score(%{} = d) do
    %Score{
      name: string!(d["name"], {Score, :name}),
      value: decode_score_value(d["value"]),
      passed?: bool!(d["passed"], {Score, :passed?}),
      reason: opt_string!(d["reason"], {Score, :reason}),
      details: map_in!(d["details"], {Score, :details}),
      metadata: map_in!(d["metadata"], {Score, :metadata})
    }
  end

  defp decode_score(other), do: invalid!({Sample, :scores}, other)

  defp encode_score_value(:pass), do: "pass"
  defp encode_score_value(:fail), do: "fail"
  defp encode_score_value(value) when is_number(value), do: value
  defp encode_score_value({:label, label}) when is_binary(label), do: %{"label" => label}
  defp encode_score_value(other), do: invalid!({Score, :value}, other)

  defp decode_score_value("pass"), do: :pass
  defp decode_score_value("fail"), do: :fail
  defp decode_score_value(value) when is_number(value), do: value
  defp decode_score_value(%{"label" => label}) when is_binary(label), do: {:label, label}
  defp decode_score_value(other), do: invalid!({Score, :value}, other)

  defp encode_scorer_error(%ScorerError{} = e) do
    %{
      "scorer" => string!(e.scorer, {ScorerError, :scorer}),
      "kind" => enum_out!(@scorer_error_kinds, e.kind, {ScorerError, :kind}),
      "reason" => opt_string!(e.reason, {ScorerError, :reason}),
      "details" => map_out!(e.details, {ScorerError, :details})
    }
  end

  defp encode_scorer_error(other), do: invalid!({Sample, :scorer_errors}, other)

  defp decode_scorer_error(%{} = d) do
    %ScorerError{
      scorer: string!(d["scorer"], {ScorerError, :scorer}),
      kind: enum_in!(@scorer_error_kinds, d["kind"], {ScorerError, :kind}),
      reason: opt_string!(d["reason"], {ScorerError, :reason}),
      details: map_in!(d["details"], {ScorerError, :details})
    }
  end

  defp decode_scorer_error(other), do: invalid!({Sample, :scorer_errors}, other)

  defp encode_skipped({scorer, reason}) when is_binary(scorer) and is_binary(reason),
    do: [scorer, reason]

  defp encode_skipped(other), do: invalid!({Sample, :skipped}, other)

  defp decode_skipped([scorer, reason]) when is_binary(scorer) and is_binary(reason),
    do: {scorer, reason}

  defp decode_skipped(other), do: invalid!({Sample, :skipped}, other)

  defp encode_trace(nil), do: nil

  defp encode_trace(%Trace{} = t) do
    %{
      "trace_id" => string!(t.trace_id, {Trace, :trace_id}),
      "truncated" => bool!(t.truncated?, {Trace, :truncated?}),
      "dropped" => int!(t.dropped, {Trace, :dropped}),
      "events" => list!(t.events, {Trace, :events}) |> Enum.map(&encode_event/1)
    }
  end

  defp encode_trace(other), do: invalid!({Sample, :trace}, other)

  defp decode_trace(nil), do: nil

  # An event whose name is not a known Nous event is dropped and counted,
  # exactly as if the collector had dropped it: the trace stays honest about
  # being incomplete.
  defp decode_trace(%{} = d) do
    {events, unknown} =
      d["events"]
      |> list!({Trace, :events})
      |> Enum.reduce({[], 0}, fn raw, {events, unknown} ->
        case decode_event(raw) do
          {:ok, event} -> {[event | events], unknown}
          :unknown_name -> {events, unknown + 1}
        end
      end)

    %Trace{
      trace_id: string!(d["trace_id"], {Trace, :trace_id}),
      truncated?: bool!(d["truncated"], {Trace, :truncated?}),
      dropped: int!(d["dropped"], {Trace, :dropped}) + unknown,
      events: Enum.reverse(events)
    }
  end

  defp decode_trace(other), do: invalid!({Sample, :trace}, other)

  defp encode_event(%Event{name: name} = e) when is_list(name) do
    unless Enum.all?(name, &is_atom/1), do: invalid!({Event, :name}, name)

    %{
      "name" => Enum.map(name, &Atom.to_string/1),
      "measurements" => map_out!(e.measurements, {Event, :measurements}),
      "metadata" => map_out!(e.metadata, {Event, :metadata}),
      "at" => int!(e.at, {Event, :at}),
      "seq" => int!(e.seq, {Event, :seq})
    }
  end

  defp encode_event(other), do: invalid!({Trace, :events}, other)

  defp decode_event(%{"name" => name} = d) when is_list(name) do
    case Map.fetch(@event_table, name) do
      {:ok, known} ->
        {:ok,
         %Event{
           name: known,
           measurements: map_in!(d["measurements"], {Event, :measurements}),
           metadata: map_in!(d["metadata"], {Event, :metadata}),
           at: int!(d["at"], {Event, :at}),
           seq: int!(d["seq"], {Event, :seq})
         }}

      :error ->
        :unknown_name
    end
  end

  defp decode_event(other), do: invalid!({Trace, :events}, other)

  defp encode_usage(%Nous.Usage{} = usage) do
    Map.new(@usage_fields, fn field ->
      {Atom.to_string(field), int!(Map.fetch!(usage, field), {Nous.Usage, field})}
    end)
  end

  defp encode_usage(other), do: invalid!({Sample, :usage}, other)

  # A counter missing from the record is zero, as in `Nous.Usage` itself;
  # keys that are not counters are ignored.
  defp decode_usage(%{} = d, _path) do
    fields =
      Map.new(@usage_fields, fn field ->
        {field, int!(Map.get(d, Atom.to_string(field), 0), {Nous.Usage, field})}
      end)

    struct(Nous.Usage, fields)
  end

  defp decode_usage(other, path), do: invalid!(path, other)

  defp encode_message(%Message{} = message) do
    fields = Message.Codec.to_fields(message)

    %{
      fields
      | "content" => encode_value(fields["content"]),
        "tool_calls" => encode_value(fields["tool_calls"]),
        "metadata" => encode_value(fields["metadata"]),
        "created_at" => fields["created_at"] && DateTime.to_iso8601(fields["created_at"])
    }
  end

  defp decode_message(%{} = d) do
    fields = %{
      d
      | "content" => dec(d["content"]),
        "tool_calls" => dec(d["tool_calls"]),
        "metadata" => dec(d["metadata"]),
        "created_at" => opt_dt_in!(d["created_at"], {Message, :created_at})
    }

    case Message.Codec.from_fields(fields) do
      {:ok, message} -> message
      {:error, reason} -> throw({:nous_eval_codec, reason})
    end
  end

  defp decode_message(other), do: invalid_value!({:message, other})

  ## Open-value internals

  defp encode_list([head | tail], acc), do: encode_list(tail, [encode_value(head) | acc])
  defp encode_list([], acc), do: Enum.reverse(acc)
  defp encode_list(_improper_tail, _acc), do: :improper

  defp encode_atom_map(map),
    do: Map.new(map, fn {k, v} -> {Atom.to_string(k), encode_value(v)} end)

  # A map stays a plain JSON object when its keys are all UTF-8 strings and it
  # cannot be mistaken for a tag (a lone key starting with "$").
  defp plain_object?(map) do
    Enum.all?(Map.keys(map), &(is_binary(&1) and String.valid?(&1))) and
      not (map_size(map) == 1 and map |> Map.keys() |> hd() |> String.starts_with?("$"))
  end

  defp opaque(term),
    do: %{"$opaque" => inspect(term, limit: :infinity, printable_limit: :infinity)}

  defp dec(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp dec(value) when is_binary(value), do: value
  defp dec(value) when is_list(value), do: Enum.map(value, &dec/1)

  defp dec(%{} = map) when map_size(map) == 1 do
    [{key, inner}] = Map.to_list(map)

    if is_binary(key) and String.starts_with?(key, "$"),
      do: dec_tagged(key, inner),
      else: %{key => dec(inner)}
  end

  defp dec(%{} = map), do: Map.new(map, fn {k, v} -> {k, dec(v)} end)
  defp dec(other), do: invalid_value!(other)

  defp dec_tagged("$atom", name) when is_binary(name), do: decode_atom(name)

  defp dec_tagged("$amap", %{} = map),
    do: Map.new(map, fn {k, v} -> {decode_atom_key(k), dec(v)} end)

  defp dec_tagged("$map", pairs) when is_list(pairs) do
    Map.new(pairs, fn
      [k, v] -> {dec(k), dec(v)}
      other -> invalid_value!({:map_pair, other})
    end)
  end

  defp dec_tagged("$tuple", items) when is_list(items),
    do: items |> Enum.map(&dec/1) |> List.to_tuple()

  defp dec_tagged("$dt", iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> invalid_value!({:datetime, iso})
    end
  end

  defp dec_tagged("$ndt", iso) when is_binary(iso), do: from_iso!(NaiveDateTime, iso)
  defp dec_tagged("$date", iso) when is_binary(iso), do: from_iso!(Date, iso)
  defp dec_tagged("$time", iso) when is_binary(iso), do: from_iso!(Time, iso)

  defp dec_tagged("$bin", b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> invalid_value!({:base64, b64})
    end
  end

  defp dec_tagged("$msg", fields), do: decode_message(fields)

  defp dec_tagged("$part", %{} = d) do
    %ContentPart{
      type: dec(d["type"]),
      content: dec(d["content"]),
      options: dec(d["options"] || %{})
    }
  end

  defp dec_tagged("$usage", %{} = d), do: decode_usage(d, {Nous.Usage, :fields})

  defp dec_tagged("$struct", [module, fields]) when is_binary(module) do
    case dec(fields) do
      %{} = map -> map
      other -> invalid_value!({:struct_fields, module, other})
    end
  end

  defp dec_tagged("$opaque", text) when is_binary(text), do: text
  defp dec_tagged(tag, inner), do: invalid_value!({tag, inner})

  defp from_iso!(module, iso) do
    case module.from_iso8601(iso) do
      {:ok, value} -> value
      {:error, _} -> invalid_value!({module, iso})
    end
  end

  defp decode_atom(name) do
    case lookup_atom(name) do
      {:ok, atom} -> atom
      :error -> %{"$atom" => name}
    end
  end

  defp decode_atom_key(name) do
    case lookup_atom(name) do
      {:ok, atom} -> atom
      :error -> name
    end
  end

  defp lookup_atom(name) do
    case Map.fetch(@atom_table, name) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        try do
          {:ok, String.to_existing_atom(name)}
        rescue
          ArgumentError -> :error
        end
    end
  end

  ## Field checks

  defp check_version(%{"schema_version" => v}) when is_integer(v) and v >= 1 do
    if v > Run.schema_version(), do: {:error, {:unsupported_schema_version, v}}, else: {:ok, v}
  end

  defp check_version(%{"schema_version" => v}), do: {:error, {:invalid_schema_version, v}}
  defp check_version(_data), do: {:error, :missing_schema_version}

  defp decode_json(text) do
    case JSON.decode(text) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, other} -> {:error, {:invalid_json, {:not_an_object, other}}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  ## Calibration internals

  @calibration JudgeCalibration.Result

  defp do_encode_calibration(%JudgeCalibration.Result{} = r) do
    %{
      "schema" => @calibration_schema,
      "fingerprint_id" => string!(r.fingerprint_id, {@calibration, :fingerprint_id}),
      "judge" => map_out!(r.judge, {@calibration, :judge}),
      "dataset_hash" => string!(r.dataset_hash, {@calibration, :dataset_hash}),
      "labels" => strings!(r.labels, {@calibration, :labels}),
      "n_cases" => int!(r.n_cases, {@calibration, :n_cases}),
      "n_tune" => int!(r.n_tune, {@calibration, :n_tune}),
      "n_holdout" => int!(r.n_holdout, {@calibration, :n_holdout}),
      "n_scored" => int!(r.n_scored, {@calibration, :n_scored}),
      "n_errors" => int!(r.n_errors, {@calibration, :n_errors}),
      "agreement" => interval_out!(r.agreement, {@calibration, :agreement}),
      "kappa" => opt_number!(r.kappa, {@calibration, :kappa}),
      "kappa_kind" => enum_out!(@kappa_kinds, r.kappa_kind, {@calibration, :kappa_kind}),
      "confusion" => confusion_out!(r.confusion),
      "false_pass" => interval_out!(r.false_pass, {@calibration, :false_pass}),
      "error_rate" => interval_out!(r.error_rate, {@calibration, :error_rate}),
      "errors" => Enum.map(list!(r.errors, {@calibration, :errors}), &calibration_error_out!/1),
      "usage" => encode_usage(r.usage),
      "calibrated_at" => opt_dt_out!(r.calibrated_at, {@calibration, :calibrated_at})
    }
  end

  defp do_decode_calibration(d) do
    %JudgeCalibration.Result{
      fingerprint_id: string!(d["fingerprint_id"], {@calibration, :fingerprint_id}),
      judge: map_in!(d["judge"], {@calibration, :judge}),
      dataset_hash: string!(d["dataset_hash"], {@calibration, :dataset_hash}),
      labels: strings!(d["labels"], {@calibration, :labels}),
      n_cases: int!(d["n_cases"], {@calibration, :n_cases}),
      n_tune: int!(d["n_tune"], {@calibration, :n_tune}),
      n_holdout: int!(d["n_holdout"], {@calibration, :n_holdout}),
      n_scored: int!(d["n_scored"], {@calibration, :n_scored}),
      n_errors: int!(d["n_errors"], {@calibration, :n_errors}),
      agreement: interval_in!(d["agreement"], {@calibration, :agreement}),
      kappa: opt_float!(d["kappa"], {@calibration, :kappa}),
      kappa_kind: enum_in!(@kappa_kinds, d["kappa_kind"], {@calibration, :kappa_kind}),
      confusion: confusion_in!(d["confusion"]),
      false_pass: interval_in!(d["false_pass"], {@calibration, :false_pass}),
      error_rate: interval_in!(d["error_rate"], {@calibration, :error_rate}),
      errors: Enum.map(list!(d["errors"], {@calibration, :errors}), &calibration_error_in!/1),
      usage: decode_usage(d["usage"], {@calibration, :usage}),
      calibrated_at: opt_dt_in!(d["calibrated_at"], {@calibration, :calibrated_at})
    }
  end

  defp interval_out!(nil, _path), do: nil

  defp interval_out!(%{estimate: e, ci: {lo, hi}, count: count, n: n}, _path)
       when is_number(e) and is_number(lo) and is_number(hi) and is_integer(count) and
              is_integer(n) do
    %{"estimate" => e, "lower" => lo, "upper" => hi, "count" => count, "n" => n}
  end

  defp interval_out!(other, path), do: invalid!(path, other)

  defp interval_in!(nil, _path), do: nil

  defp interval_in!(
         %{"estimate" => e, "lower" => lo, "upper" => hi, "count" => c, "n" => n},
         path
       ) do
    %{
      estimate: float!(e, path),
      ci: {float!(lo, path), float!(hi, path)},
      count: int!(c, path),
      n: int!(n, path)
    }
  end

  defp interval_in!(other, path), do: invalid!(path, other)

  defp confusion_out!(%{labels: labels, matrix: matrix}) do
    path = {@calibration, :confusion}

    %{
      "labels" => strings!(labels, path),
      "matrix" =>
        Enum.map(list!(matrix, path), fn row -> Enum.map(list!(row, path), &int!(&1, path)) end)
    }
  end

  defp confusion_out!(other), do: invalid!({@calibration, :confusion}, other)

  defp confusion_in!(%{"labels" => labels, "matrix" => matrix}) do
    path = {@calibration, :confusion}

    %{
      labels: strings!(labels, path),
      matrix:
        Enum.map(list!(matrix, path), fn row -> Enum.map(list!(row, path), &int!(&1, path)) end)
    }
  end

  defp confusion_in!(other), do: invalid!({@calibration, :confusion}, other)

  defp calibration_error_out!(%{case_id: id, kind: kind} = error) do
    path = {@calibration, :errors}

    %{
      "case_id" => string!(id, path),
      "kind" => enum_out!(@scorer_error_kinds, kind, path),
      "reason" => opt_string!(Map.get(error, :reason), path)
    }
  end

  defp calibration_error_out!(other), do: invalid!({@calibration, :errors}, other)

  defp calibration_error_in!(%{"case_id" => id, "kind" => kind} = error) do
    path = {@calibration, :errors}

    %{
      case_id: string!(id, path),
      kind: enum_in!(@scorer_error_kinds, kind, path),
      reason: opt_string!(error["reason"], path)
    }
  end

  defp calibration_error_in!(other), do: invalid!({@calibration, :errors}, other)

  defp strings!(v, path) when is_list(v), do: Enum.map(v, &string!(&1, path))
  defp strings!(v, path), do: invalid!(path, v)

  defp float!(v, _path) when is_number(v), do: v / 1
  defp float!(v, path), do: invalid!(path, v)

  defp opt_float!(nil, _path), do: nil
  defp opt_float!(v, path), do: float!(v, path)

  defp catch_invalid(fun) do
    {:ok, fun.()}
  catch
    {:nous_eval_codec, reason} -> {:error, reason}
  end

  defp invalid!(path, value), do: throw({:nous_eval_codec, {:invalid_field, path, value}})
  defp invalid_value!(value), do: throw({:nous_eval_codec, {:invalid_value, value}})

  defp string!(v, _path) when is_binary(v), do: v
  defp string!(v, path), do: invalid!(path, v)

  defp opt_string!(nil, _path), do: nil
  defp opt_string!(v, path), do: string!(v, path)

  defp int!(v, _path) when is_integer(v), do: v
  defp int!(v, path), do: invalid!(path, v)

  defp opt_int!(nil, _path), do: nil
  defp opt_int!(v, path), do: int!(v, path)

  defp opt_number!(v, _path) when is_number(v) or is_nil(v), do: v
  defp opt_number!(v, path), do: invalid!(path, v)

  defp bool!(v, _path) when is_boolean(v), do: v
  defp bool!(v, path), do: invalid!(path, v)

  defp list!(v, _path) when is_list(v), do: v
  defp list!(v, path), do: invalid!(path, v)

  defp map_out!(%{} = v, _path) when not is_struct(v), do: encode_value(v)
  defp map_out!(v, path), do: invalid!(path, v)

  defp map_in!(v, path) do
    case dec(v) do
      %{} = map when not is_struct(map) -> map
      other -> invalid!(path, other)
    end
  end

  defp enum_out!(table, v, path) when is_atom(v) do
    name = Atom.to_string(v)
    if Map.get(table, name) == v, do: name, else: invalid!(path, v)
  end

  defp enum_out!(_table, v, path), do: invalid!(path, v)

  defp opt_enum_out!(_table, nil, _path), do: nil
  defp opt_enum_out!(table, v, path), do: enum_out!(table, v, path)

  defp enum_in!(table, v, path) when is_binary(v) do
    case Map.fetch(table, v) do
      {:ok, atom} -> atom
      :error -> invalid!(path, v)
    end
  end

  defp enum_in!(_table, v, path), do: invalid!(path, v)

  defp opt_enum_in!(_table, nil, _path), do: nil
  defp opt_enum_in!(table, v, path), do: enum_in!(table, v, path)

  defp opt_dt_out!(nil, _path), do: nil
  defp opt_dt_out!(%DateTime{} = dt, _path), do: DateTime.to_iso8601(dt)
  defp opt_dt_out!(v, path), do: invalid!(path, v)

  defp opt_dt_in!(nil, _path), do: nil

  defp opt_dt_in!(iso, path) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> invalid!(path, iso)
    end
  end

  defp opt_dt_in!(v, path), do: invalid!(path, v)
end

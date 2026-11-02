defmodule Nous.Eval.Online.OTel do
  @moduledoc """
  Maps an online-eval `Nous.Eval.Sample` to OpenTelemetry spans following the
  GenAI semantic conventions (pinned to semconv `1.37.0`, see
  `semconv_version/0`).

  ## What is mapped

    * each agent run → an `"invoke_agent <agent_name>"` span (kind
      `:internal`) whose span id is the run's `agent_run_id`; a sub-agent run
      is parented to the `execute_tool` span that spawned it, else to its
      parent run
    * each model request → a `"chat <model_name>"` span (kind `:client`) with
      the request/response model, token usage and finish reasons
    * each tool call → an `"execute_tool <tool_name>"` span with the tool name,
      call id, outcome and approval; a call that spawned a sub-agent run also
      carries `gen_ai.transfer.target.name`
    * guard, loop-guard and hook events → span events `nous.<guard>.<event>`
      on the enclosing run span, with skeleton attributes only (verdict,
      severity, action, surface, tier, hook name, tool call id)
    * each score and scorer error → a `"gen_ai.evaluation.result"` event on
      the root run span

  ## Content

  This mapping only ever sees redacted samples: the online pipeline removes
  (`redact: :drop_content`) or rewrites content keys before a sample reaches
  an exporter. Even so, content attributes (`gen_ai.input.messages`,
  `gen_ai.output.messages`, `gen_ai.tool.call.arguments`,
  `gen_ai.tool.call.result`) and score explanations are emitted only with
  `export_content: true` (default `false`), as JSON of the already-redacted
  value. Under `redact: :drop_content` they never appear, since the content
  keys are absent. No other content key (`reason`, `error`, `details`, …) is
  ever exported; a failed run reports only its `error_kind`.

  ## OpenTelemetry API

  `spans/2` is pure and needs no dependency. `export/2` calls the
  OpenTelemetry Erlang API only when it is loaded (`:otel_tracer`), and
  returns `{:error, :opentelemetry_not_loaded}` otherwise. Nous does not
  depend on OpenTelemetry.
  """

  alias Nous.Eval.{Codec, Sample, Score, ScorerError, Scoring}
  alias Nous.Eval.Trace
  alias Nous.Eval.Trace.Event

  @semconv_version "1.37.0"

  @run_start [:nous, :agent, :run, :start]
  @run_stop [:nous, :agent, :run, :stop]
  @run_exception [:nous, :agent, :run, :exception]
  @model_start [:nous, :agent, :model, :start]
  @model_stop [:nous, :agent, :model, :stop]
  @model_exception [:nous, :agent, :model, :exception]
  @tool_start [:nous, :agent, :tool_call, :start]
  @tool_stop [:nous, :agent, :tool_call, :stop]

  @guard_events [
    [:nous, :decision_guard, :verdict],
    [:nous, :input_guard, :verdict],
    [:nous, :loop_guard, :advisory],
    [:nous, :hook, :denied],
    [:nous, :hook, :decision]
  ]
  @guard_keys [:verdict, :severity, :action, :surface, :tier, :hook_name, :tool_call_id]

  @type scalar :: String.t() | boolean() | integer() | float()
  @type attributes :: %{String.t() => scalar() | [scalar()]}
  @type span_event :: %{name: String.t(), time: integer(), attributes: attributes()}
  @type span :: %{
          name: String.t(),
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          kind: :internal | :client,
          start_time: integer(),
          end_time: integer(),
          attributes: attributes(),
          events: [span_event()],
          status: :unset | :ok | :error
        }

  @doc "The GenAI semantic-conventions version this mapping follows."
  @spec semconv_version() :: String.t()
  def semconv_version, do: @semconv_version

  @doc """
  The spans for `sample`, parents before children.

  Options:

    * `:export_content` - emit content attributes and score explanations
      (default `false`)

  Total: malformed events are skipped. A sample without a valid 32-hex
  `trace_id` yields `[]`.
  """
  @spec spans(Sample.t(), keyword()) :: [span()]
  def spans(%Sample{} = sample, opts \\ []) do
    content? = Keyword.get(opts, :export_content, false) == true
    events = events(sample)

    case trace_id(sample) do
      nil -> []
      tid -> build(tid, events, sample, content?)
    end
  end

  @doc """
  Exports `sample` through the OpenTelemetry API when it is loaded.

  Takes the same options as `spans/2`.
  """
  @spec export(Sample.t(), keyword()) :: :ok | {:error, :opentelemetry_not_loaded}
  def export(%Sample{} = sample, opts \\ []) do
    if Code.ensure_loaded?(:otel_tracer) do
      sample |> spans(opts) |> emit()
    else
      {:error, :opentelemetry_not_loaded}
    end
  end

  @doc "A 1-arity exporter for the online `exporter:` option."
  @spec exporter(keyword()) :: (Sample.t() -> :ok | {:error, :opentelemetry_not_loaded})
  def exporter(opts \\ []), do: fn sample -> export(sample, opts) end

  # -- building ---------------------------------------------------------------

  defp events(%Sample{trace: %Trace{events: events}}) when is_list(events),
    do: Enum.filter(events, &valid_event?/1)

  defp events(_sample), do: []

  defp valid_event?(%Event{name: name, metadata: meta, at: at, seq: seq}),
    do: is_list(name) and is_map(meta) and is_integer(at) and is_integer(seq)

  defp valid_event?(_), do: false

  defp trace_id(%Sample{trace_id: tid, trace: trace}) do
    tid = if is_binary(tid), do: tid, else: trace_tid(trace)
    if hex?(tid, 32), do: String.downcase(tid)
  end

  defp trace_tid(%Trace{trace_id: tid}), do: tid
  defp trace_tid(_), do: nil

  defp hex?(value, size) when is_binary(value),
    do: byte_size(value) == size and value =~ ~r/\A[0-9a-fA-F]+\z/

  defp hex?(_, _), do: false

  defp build(tid, events, sample, content?) do
    runs = runs(events)
    tools = tools(tid, events, content?)
    models = models(tid, events, runs, content?)
    root = root_run(runs)

    run_spans =
      Enum.map(runs, fn run ->
        run_span(tid, run, runs, tools, events, root, sample, content?)
      end)

    tool_spans = Enum.flat_map(tools, &tool_span(tid, &1, runs))

    order(run_spans ++ models ++ tool_spans)
  end

  # Runs: start events with a 16-hex agent_run_id, closed by stop/exception.
  defp runs(events) do
    {runs, order} =
      Enum.reduce(events, {%{}, []}, fn
        %Event{name: @run_start, metadata: meta} = e, {acc, order} ->
          id = meta[:agent_run_id]

          if hex?(id, 16) and not Map.has_key?(acc, id),
            do: {Map.put(acc, id, %{id: id, start: e, stop: nil}), [id | order]},
            else: {acc, order}

        %Event{name: name, metadata: meta} = e, {acc, order}
        when name in [@run_stop, @run_exception] ->
          case Map.fetch(acc, meta[:agent_run_id]) do
            {:ok, %{stop: nil} = run} -> {Map.put(acc, run.id, %{run | stop: e}), order}
            _ -> {acc, order}
          end

        _e, acc ->
          acc
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(runs, &1))
  end

  defp root_run(runs) do
    Enum.find(runs, fn %{start: %Event{metadata: m}} ->
      is_nil(m[:parent_agent_run_id]) and is_nil(m[:parent_tool_call_id])
    end)
  end

  defp run_span(tid, run, runs, tools, events, root, sample, content?) do
    %{start: %Event{metadata: meta} = start, stop: stop} = run
    name = str(meta[:agent_name])

    {status, err_attrs} =
      case stop do
        %Event{name: @run_exception, metadata: m} -> {:error, %{"error.type" => error_kind(m)}}
        %Event{} -> {:ok, %{}}
        nil -> {:unset, %{}}
      end

    attributes =
      %{
        "gen_ai.operation.name" => "invoke_agent",
        "gen_ai.agent.name" => name,
        "gen_ai.provider.name" => str(meta[:model_provider]),
        "gen_ai.request.model" => str(meta[:model_name]),
        "nous.agent_run_id" => run.id,
        "nous.role" => str(meta[:role]),
        "nous.sub_agent_template" => str(meta[:sub_agent_template])
      }
      |> Map.merge(err_attrs)
      |> compact()

    guard_events = guard_events(events, run.id, root)

    score_events =
      if root && root.id == run.id, do: score_events(sample, start, content?), else: []

    %{
      name: join("invoke_agent", name),
      trace_id: tid,
      span_id: run.id,
      parent_span_id: run_parent(meta, runs, tools),
      kind: :internal,
      start_time: start.at,
      end_time: end_time(start, stop),
      attributes: attributes,
      events: guard_events ++ score_events,
      status: status
    }
  end

  defp run_parent(meta, runs, tools) do
    tool = Enum.find(tools, &(&1.id == meta[:parent_tool_call_id] and is_binary(&1.id)))
    parent = meta[:parent_agent_run_id]

    cond do
      tool -> tool.span_id
      is_binary(parent) and Enum.any?(runs, &(&1.id == parent)) -> parent
      true -> nil
    end
  end

  defp error_kind(meta) do
    case meta[:error_kind] do
      k when is_atom(k) and not is_nil(k) and not is_boolean(k) -> Atom.to_string(k)
      k when is_binary(k) -> k
      _ -> "error"
    end
  end

  defp guard_events(events, run_id, root) do
    root_id = root && root.id

    for %Event{name: name, metadata: meta, at: at} <- events,
        name in @guard_events,
        owner(meta[:agent_run_id], root_id) == run_id do
      [_nous, guard, event] = name

      attrs =
        for key <- @guard_keys, value = scalar(meta[key]), value != nil, into: %{} do
          {"nous." <> Atom.to_string(key), value}
        end

      %{name: "nous.#{guard}.#{event}", time: at, attributes: attrs}
    end
  end

  # A guard event without a run id belongs to the root run.
  defp owner(id, _root_id) when is_binary(id), do: id
  defp owner(_id, root_id), do: root_id

  defp score_events(%Sample{scores: scores, scorer_errors: errors} = sample, start, content?) do
    time = sample_time(sample, start)

    score_events =
      for %Score{} = score <- List.wrap(scores) do
        %{
          name: "gen_ai.evaluation.result",
          time: time,
          attributes: score_attrs(score, content?)
        }
      end

    error_events =
      for %ScorerError{} = error <- List.wrap(errors) do
        %{
          name: "gen_ai.evaluation.result",
          time: time,
          attributes:
            compact(%{
              "gen_ai.evaluation.name" => str(error.scorer),
              "error.type" => str(error.kind)
            })
        }
      end

    score_events ++ error_events
  end

  defp sample_time(%Sample{trace: %Trace{events: [_ | _] = events}}, _start) do
    events |> Enum.filter(&valid_event?/1) |> Enum.map(& &1.at) |> Enum.max()
  end

  defp sample_time(_sample, %Event{at: at}), do: at

  defp score_attrs(%Score{} = score, content?) do
    labels =
      case score.metadata do
        %{label_values: lv} when is_map(lv) -> lv
        _ -> %{}
      end

    value =
      case safe_float(score.value, labels) do
        {:ok, f} -> f
        _ -> nil
      end

    label =
      case score.value do
        :pass -> "pass"
        :fail -> "fail"
        {:label, l} when is_binary(l) -> l
        _ -> nil
      end

    explanation = if content? and is_binary(score.reason), do: score.reason

    compact(%{
      "gen_ai.evaluation.name" => str(score.name),
      "gen_ai.evaluation.score.value" => value,
      "gen_ai.evaluation.score.label" => label,
      "gen_ai.evaluation.explanation" => explanation
    })
  end

  defp safe_float(value, labels) do
    Scoring.value_to_float(value, labels)
  rescue
    FunctionClauseError -> :error
  end

  # Model calls: a start pairs with the next stop/exception of the same run.
  defp models(tid, events, runs, content?) do
    run_ids = MapSet.new(runs, & &1.id)

    {done, pending} =
      Enum.reduce(events, {[], %{}}, fn
        %Event{name: @model_start, metadata: m} = e, {done, pending} ->
          run_id = m[:agent_run_id]

          if MapSet.member?(run_ids, run_id) do
            done = if p = pending[run_id], do: [{p, nil} | done], else: done
            {done, Map.put(pending, run_id, e)}
          else
            {done, pending}
          end

        %Event{name: name, metadata: m} = e, {done, pending}
        when name in [@model_stop, @model_exception] ->
          case Map.pop(pending, m[:agent_run_id]) do
            {nil, _} -> {done, pending}
            {start, pending} -> {[{start, e} | done], pending}
          end

        _e, acc ->
          acc
      end)

    (done ++ Enum.map(pending, fn {_run, start} -> {start, nil} end))
    |> Enum.sort_by(fn {start, _} -> start.seq end)
    |> Enum.map(&model_span(tid, &1, content?))
  end

  defp model_span(tid, {%Event{metadata: meta} = start, stop}, content?) do
    run_id = meta[:agent_run_id]
    model = str(meta[:model_name])
    stop_meta = (stop && stop.metadata) || %{}
    measurements = (stop && is_map(stop.measurements) && stop.measurements) || %{}

    {status, err} =
      case stop do
        %Event{name: @model_exception, metadata: m} -> {:error, %{"error.type" => kind(m)}}
        %Event{} -> {:ok, %{}}
        nil -> {:unset, %{}}
      end

    finish =
      case stop_meta[:finish_reason] do
        r when is_binary(r) -> [r]
        r when is_atom(r) and not is_nil(r) and not is_boolean(r) -> [Atom.to_string(r)]
        _ -> nil
      end

    content =
      if content?,
        do: %{
          "gen_ai.input.messages" => json(meta, :messages),
          "gen_ai.output.messages" => json(stop_meta, :response)
        },
        else: %{}

    attributes =
      %{
        "gen_ai.operation.name" => "chat",
        "gen_ai.request.model" => model,
        "gen_ai.response.model" => str(stop_meta[:active_model_name]),
        "gen_ai.usage.input_tokens" => int(measurements[:input_tokens]),
        "gen_ai.usage.output_tokens" => int(measurements[:output_tokens]),
        "gen_ai.response.finish_reasons" => finish
      }
      |> Map.merge(err)
      |> Map.merge(content)
      |> compact()

    %{
      name: join("chat", model),
      trace_id: tid,
      span_id: derive_id(tid, run_id, Integer.to_string(start.seq)),
      parent_span_id: run_id,
      kind: :client,
      start_time: start.at,
      end_time: end_time(start, stop),
      attributes: attributes,
      events: [],
      status: status
    }
  end

  defp kind(meta) do
    case meta[:kind] do
      k when is_atom(k) and not is_nil(k) and not is_boolean(k) -> Atom.to_string(k)
      _ -> "error"
    end
  end

  # Tool calls by tool_call_id.
  defp tools(tid, events, content?) do
    {calls, order} =
      Enum.reduce(events, {%{}, []}, fn
        %Event{name: @tool_start, metadata: m} = e, {acc, order} ->
          id = m[:tool_call_id]

          if is_binary(id) and not Map.has_key?(acc, id),
            do: {Map.put(acc, id, %{id: id, start: e, stop: nil}), [id | order]},
            else: {acc, order}

        %Event{name: @tool_stop, metadata: m} = e, {acc, order} ->
          id = m[:tool_call_id]

          case Map.fetch(acc, id) do
            {:ok, %{stop: nil} = call} ->
              {Map.put(acc, id, %{call | stop: e}), order}

            {:ok, _} ->
              {acc, order}

            :error when is_binary(id) ->
              {Map.put(acc, id, %{id: id, start: e, stop: e}), [id | order]}

            :error ->
              {acc, order}
          end

        _e, acc ->
          acc
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn id ->
      call = Map.fetch!(calls, id)
      Map.merge(call, %{span_id: derive_id(tid, "tool", id), content?: content?})
    end)
  end

  defp tool_span(tid, call, runs) do
    %{start: %Event{metadata: meta} = start, stop: stop} = call
    stop_meta = (stop && stop.metadata) || %{}
    run_id = meta[:agent_run_id] || stop_meta[:agent_run_id]

    if Enum.any?(runs, &(&1.id == run_id)) do
      name = str(meta[:tool_name] || stop_meta[:tool_name])
      outcome = stop_meta[:outcome]

      target =
        Enum.find_value(runs, fn %{start: %Event{metadata: m}} ->
          if m[:parent_tool_call_id] == call.id, do: str(m[:agent_name])
        end)

      content =
        if call.content?,
          do: %{
            "gen_ai.tool.call.arguments" => json(meta, :arguments) || json(stop_meta, :arguments),
            "gen_ai.tool.call.result" => json(stop_meta, :result)
          },
          else: %{}

      attributes =
        %{
          "gen_ai.operation.name" => "execute_tool",
          "gen_ai.tool.name" => name,
          "gen_ai.tool.call.id" => call.id,
          "nous.tool.outcome" => str(outcome),
          "nous.tool.approval" => str(stop_meta[:approval]),
          "gen_ai.transfer.target.name" => target
        }
        |> Map.merge(content)
        |> compact()

      status =
        cond do
          is_nil(stop) -> :unset
          outcome == :executed -> :ok
          true -> :error
        end

      [
        %{
          name: join("execute_tool", name),
          trace_id: tid,
          span_id: call.span_id,
          parent_span_id: run_id,
          kind: :internal,
          start_time: start.at,
          end_time: end_time(start, stop),
          attributes: attributes,
          events: [],
          status: status
        }
      ]
    else
      []
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Parents before children; spans whose parent is never emitted are dropped.
  defp order(spans), do: order(spans, MapSet.new([nil]), [])

  defp order([], _seen, acc), do: Enum.reverse(acc)

  defp order(spans, seen, acc) do
    {ready, rest} = Enum.split_with(spans, &MapSet.member?(seen, &1.parent_span_id))

    if ready == [] do
      Enum.reverse(acc)
    else
      seen = Enum.reduce(ready, seen, &MapSet.put(&2, &1.span_id))
      order(rest, seen, Enum.reverse(ready, acc))
    end
  end

  defp derive_id(tid, a, b) do
    :crypto.hash(:sha256, [tid, to_string(a), b])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp end_time(%Event{at: start}, %Event{at: stop}) when stop >= start, do: stop
  defp end_time(%Event{at: start}, _stop), do: start

  defp json(meta, key) do
    case Map.fetch(meta, key) do
      {:ok, nil} -> nil
      {:ok, value} -> value |> Codec.encode_value() |> JSON.encode!()
      :error -> nil
    end
  end

  defp join(op, nil), do: op
  defp join(op, name), do: op <> " " <> name

  defp str(v) when is_binary(v), do: v
  defp str(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: Atom.to_string(v)
  defp str(_), do: nil

  defp int(v) when is_integer(v), do: v
  defp int(_), do: nil

  defp scalar(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp scalar(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp scalar(_), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  # -- OpenTelemetry API ------------------------------------------------------

  # [UNVERIFIED] Nous has no OpenTelemetry dependency to test against; this
  # path follows the opentelemetry_api docs and is called only when
  # `:otel_tracer` is loaded. `apply/3` keeps it compiling without the dep.
  defp emit([]), do: :ok

  defp emit([root | _] = spans) do
    tracer = apply(:opentelemetry, :get_application_tracer, [__MODULE__])

    remote =
      apply(:otel_tracer, :from_remote_span, [hex_int(root.trace_id), hex_int(root.span_id), 1])

    _span_ctxs =
      Enum.reduce(spans, %{}, fn span, ctxs ->
        parent = Map.get(ctxs, span.parent_span_id, remote)
        ctx = apply(:otel_tracer, :set_current_span, [apply(:otel_ctx, :new, []), parent])

        span_ctx =
          apply(:otel_tracer, :start_span, [
            ctx,
            tracer,
            span.name,
            %{start_time: span.start_time, kind: span.kind, attributes: span.attributes}
          ])

        Enum.each(span.events, fn event ->
          apply(:otel_span, :add_event, [span_ctx, event.name, event.attributes])
        end)

        if span.status == :error do
          status = apply(:opentelemetry, :status, [:error, ""])
          apply(:otel_span, :set_status, [span_ctx, status])
        end

        apply(:otel_span, :end_span, [span_ctx, span.end_time])
        Map.put(ctxs, span.span_id, span_ctx)
      end)

    :ok
  end

  defp hex_int(hex), do: String.to_integer(hex, 16)
end

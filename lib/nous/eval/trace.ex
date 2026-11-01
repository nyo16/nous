defmodule Nous.Eval.Trace do
  @moduledoc """
  The telemetry events one eval sample produced, in emission order.

  A trace is everything Nous emitted under the sample's `trace_id`: the root
  run, its model and tool calls, guard verdicts, and every sub-agent run
  (linked through `parent_agent_run_id` / `parent_tool_call_id`). It
  survives failed and killed runs, so a failing sample can be inspected up
  to the point it stopped.

  Events carry the metadata documented in `Nous.Telemetry`. Content keys
  (`messages`, `response`, `arguments`, `result`, `details`, `errors`) hold
  user data.

  `truncated?` is true when the per-trace event or byte cap was reached; the
  tail of the trace is then missing, and a scorer that needs to prove an
  absence ("tool X was never called") must not pass on it.

  ## Queries

  Scorers read a trace through the pure functions below rather than
  walking events: `tool_calls/2`, `model_calls/1`, `guard_verdicts/2`,
  `output_retries/2`, `runs/1`, `usage/1` and `transcript/2`. They are
  total: an unknown event or an event with malformed metadata is ignored,
  never raised on.

  ### Scope

  Functions taking `:scope` select runs of the run tree:

    * `:root` - the root run only (a `delegate_task` call is a root call; the
      sub-agent's own calls are not)
    * `:tree` - every run
    * `{:run, agent_run_id}` - one run
    * `{:sub_agent, template}` - the runs whose start event carries
      `sub_agent_template: template` (not their descendants)
  """

  alias Nous.Eval.Trace.{AgentRun, Event, GuardVerdict, ModelCall, ToolCall}

  @type t :: %__MODULE__{
          trace_id: String.t(),
          events: [Event.t()],
          truncated?: boolean(),
          dropped: non_neg_integer()
        }

  @type scope :: :root | :tree | {:run, String.t()} | {:sub_agent, String.t()}

  @enforce_keys [:trace_id]
  defstruct [:trace_id, events: [], truncated?: false, dropped: 0]

  @run_start [:nous, :agent, :run, :start]
  @run_stop [:nous, :agent, :run, :stop]
  @run_exception [:nous, :agent, :run, :exception]
  @model_start [:nous, :agent, :model, :start]
  @model_stop [:nous, :agent, :model, :stop]
  @model_exception [:nous, :agent, :model, :exception]
  @tool_start [:nous, :agent, :tool_call, :start]
  @tool_stop [:nous, :agent, :tool_call, :stop]
  @output_retry [:nous, :agent, :structured_output, :retry]
  @decision_guard_verdict [:nous, :decision_guard, :verdict]
  @input_guard_verdict [:nous, :input_guard, :verdict]
  @loop_guard_advisory [:nous, :loop_guard, :advisory]
  @hook_decision [:nous, :hook, :decision]

  @stop_outcomes ToolCall.outcomes() -- [:incomplete]
  @approvals [:not_required, :approved, :edited, :rejected]
  @guards [:decision_guard, :input_guard, :loop_guard, :hook]

  # ── tool calls ─────────────────────────────────────────────────────────────

  @doc """
  The tool calls in the trace, in request order.

  Options:

    * `:scope` - see "Scope" in the moduledoc (default `:root`)
    * `:include` - which outcomes count: a list of `Nous.Eval.Trace.ToolCall`
      outcomes, or `:all` (default `[:executed]`; failed, denied and
      incomplete attempts are excluded)

  A start event without a matching stop yields a call with outcome
  `:incomplete`. When the stop reports `approval: :edited`, `arguments` are
  the edited arguments the tool ran with.
  """
  @spec tool_calls(t(), keyword()) :: [ToolCall.t()]
  def tool_calls(%__MODULE__{} = trace, opts \\ []) do
    scope = scope_opt(opts, :root)
    include = include_opt(opts)
    runs = run_index(trace)
    in_scope = scope_filter(scope, runs)

    trace
    |> valid_events()
    |> pair_tool_calls(runs)
    |> Enum.filter(&(in_scope.(&1) and included?(&1, include)))
  end

  defp pair_tool_calls(events, runs) do
    {calls, order} =
      Enum.reduce(events, {%{}, []}, fn event, acc -> tool_event(event, acc, runs) end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(calls, &1))
  end

  defp tool_event(%Event{name: @tool_start, metadata: meta, seq: seq}, {calls, order}, runs) do
    with id when is_binary(id) <- meta[:tool_call_id],
         false <- Map.has_key?(calls, id) do
      run_id = string_or_nil(meta[:agent_run_id])
      iteration = int_or_nil(meta[:iteration])
      arguments = map_or_nil(meta[:arguments])

      call = %ToolCall{
        id: id,
        name: string_or_nil(meta[:tool_name]),
        arguments: arguments,
        original_arguments: arguments,
        outcome: :incomplete,
        iteration: iteration,
        agent_run_id: run_id,
        parent_agent_run_id: parent_of(run_id, meta, runs),
        batch: {run_id, iteration},
        seq: seq
      }

      {Map.put(calls, id, call), [id | order]}
    else
      _ -> {calls, order}
    end
  end

  defp tool_event(%Event{name: @tool_stop, metadata: meta, seq: seq}, {calls, order}, runs) do
    with id when is_binary(id) <- meta[:tool_call_id],
         outcome when outcome in @stop_outcomes <- meta[:outcome] do
      case Map.fetch(calls, id) do
        {:ok, %ToolCall{outcome: :incomplete} = call} ->
          {Map.put(calls, id, finish_tool_call(call, outcome, meta)), order}

        {:ok, _already_stopped} ->
          {calls, order}

        :error ->
          run_id = string_or_nil(meta[:agent_run_id])
          iteration = int_or_nil(meta[:iteration])

          call = %ToolCall{
            id: id,
            name: string_or_nil(meta[:tool_name]),
            iteration: iteration,
            agent_run_id: run_id,
            parent_agent_run_id: parent_of(run_id, meta, runs),
            batch: {run_id, iteration},
            seq: seq
          }

          {Map.put(calls, id, finish_tool_call(call, outcome, meta)), [id | order]}
      end
    else
      _ -> {calls, order}
    end
  end

  defp tool_event(_event, acc, _runs), do: acc

  defp finish_tool_call(%ToolCall{} = call, outcome, meta) do
    approval = if meta[:approval] in @approvals, do: meta[:approval]

    arguments =
      case {approval, meta[:arguments]} do
        {:edited, edited} when is_map(edited) -> edited
        _ -> call.arguments || map_or_nil(meta[:arguments])
      end

    %ToolCall{
      call
      | name: call.name || string_or_nil(meta[:tool_name]),
        outcome: outcome,
        approval: approval,
        arguments: arguments,
        original_arguments: call.original_arguments || arguments,
        result: meta[:result],
        error: meta[:error]
    }
  end

  defp included?(_call, :all), do: true
  defp included?(%ToolCall{outcome: outcome}, include), do: outcome in include

  # ── model calls ────────────────────────────────────────────────────────────

  @doc """
  The model requests in the trace (every run), in request order.

  Each `Nous.Eval.Trace.ModelCall` pairs a model start with the next stop
  or exception of the same run; a start with neither is `:incomplete`.
  """
  @spec model_calls(t()) :: [ModelCall.t()]
  def model_calls(%__MODULE__{} = trace) do
    runs = run_index(trace)

    {done, pending} =
      trace
      |> valid_events()
      |> Enum.reduce({[], %{}}, &model_event(&1, &2, runs))

    (done ++ Map.values(pending))
    |> Enum.sort_by(& &1.seq)
  end

  defp model_event(%Event{name: @model_start, metadata: meta, seq: seq}, {done, pending}, runs) do
    run_id = string_or_nil(meta[:agent_run_id])

    call = %ModelCall{
      agent_run_id: run_id,
      parent_agent_run_id: parent_of(run_id, meta, runs),
      iteration: int_or_nil(meta[:iteration]),
      outcome: :incomplete,
      model_provider: atom_or_nil(meta[:model_provider]),
      model_name: string_or_nil(meta[:model_name]),
      stream: bool_or_nil(meta[:stream]),
      tool_names: list_or_nil(meta[:tool_names]),
      messages: list_or_nil(meta[:messages]),
      seq: seq
    }

    # A second start before a stop means the first request never finished.
    done =
      case Map.fetch(pending, run_id) do
        {:ok, prev} -> [prev | done]
        :error -> done
      end

    {done, Map.put(pending, run_id, call)}
  end

  defp model_event(%Event{name: @model_stop} = event, {done, pending}, runs) do
    %Event{metadata: meta, measurements: measurements} = event
    {%ModelCall{} = call, pending} = take_pending(pending, event, runs)

    call = %ModelCall{
      call
      | outcome: :ok,
        iteration: call.iteration || int_or_nil(meta[:iteration]),
        model_provider: call.model_provider || atom_or_nil(meta[:model_provider]),
        model_name: call.model_name || string_or_nil(meta[:model_name]),
        active_model_provider: atom_or_nil(meta[:active_model_provider]),
        active_model_name: string_or_nil(meta[:active_model_name]),
        fallback_used: bool_or_nil(meta[:fallback_used]),
        finish_reason: meta[:finish_reason],
        requested_tool_calls: list_or_nil(meta[:requested_tool_calls]),
        response: response_or_nil(meta[:response]),
        usage: usage_from(measurements),
        duration: int_or_nil(measurements[:duration])
    }

    {[call | done], pending}
  end

  defp model_event(%Event{name: @model_exception} = event, {done, pending}, runs) do
    %Event{metadata: meta, measurements: measurements} = event
    {%ModelCall{} = call, pending} = take_pending(pending, event, runs)

    call = %ModelCall{
      call
      | outcome: :error,
        iteration: call.iteration || int_or_nil(meta[:iteration]),
        model_provider: call.model_provider || atom_or_nil(meta[:model_provider]),
        model_name: call.model_name || string_or_nil(meta[:model_name]),
        error: {meta[:kind], meta[:reason]},
        duration: int_or_nil(measurements[:duration])
    }

    {[call | done], pending}
  end

  defp model_event(_event, acc, _runs), do: acc

  defp take_pending(pending, %Event{metadata: meta, seq: seq}, runs) do
    run_id = string_or_nil(meta[:agent_run_id])

    case Map.pop(pending, run_id) do
      {nil, pending} ->
        orphan = %ModelCall{
          agent_run_id: run_id,
          parent_agent_run_id: parent_of(run_id, meta, runs),
          outcome: :incomplete,
          seq: seq
        }

        {orphan, pending}

      {call, pending} ->
        {call, pending}
    end
  end

  defp usage_from(measurements) do
    input = non_neg(measurements[:input_tokens])
    output = non_neg(measurements[:output_tokens])

    total =
      case measurements[:total_tokens] do
        n when is_integer(n) and n >= 0 -> n
        _ -> input + output
      end

    %Nous.Usage{
      requests: 1,
      tool_calls: non_neg(measurements[:tool_calls]),
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cache_creation_input_tokens: non_neg(measurements[:cache_creation_input_tokens]),
      cache_read_input_tokens: non_neg(measurements[:cache_read_input_tokens])
    }
  end

  @doc """
  The token usage of every completed model request in the trace (the whole
  run tree), summed into one `Nous.Usage`. `requests` counts model stop
  events; `tool_calls` counts the tool calls the responses requested.
  """
  @spec usage(t()) :: Nous.Usage.t()
  def usage(%__MODULE__{} = trace) do
    trace
    |> model_calls()
    |> Enum.filter(&(&1.outcome == :ok))
    |> Enum.reduce(%Nous.Usage{}, &Nous.Usage.add(&2, &1.usage))
  end

  # ── guard verdicts ─────────────────────────────────────────────────────────

  @doc """
  The guard decisions in the trace, in emission order, as
  `Nous.Eval.Trace.GuardVerdict`s.

  Options:

    * `:guard` - `:decision_guard | :input_guard | :loop_guard | :hook |
      :all` (default `:all`). `:hook` is a decision hook that is not one of
      DecisionGuard's surfaces: a DecisionGuard hook surface reports both a
      `[:nous, :decision_guard, :verdict]` and a `[:nous, :hook, :decision]`
      whose `hook_name` starts with `"decision_guard:"`; the hook event is
      dropped so each decision counts once.
    * `:scope` - see "Scope" in the moduledoc (default `:tree`)
  """
  @spec guard_verdicts(t(), keyword()) :: [GuardVerdict.t()]
  def guard_verdicts(%__MODULE__{} = trace, opts \\ []) do
    guard = Keyword.get(opts, :guard, :all)

    unless guard == :all or guard in @guards do
      raise ArgumentError,
            "unknown guard #{inspect(guard)}; expected :all or one of #{inspect(@guards)}"
    end

    runs = run_index(trace)
    in_scope = scope_filter(scope_opt(opts, :tree), runs)

    trace
    |> valid_events()
    |> Enum.flat_map(&guard_verdict(&1, runs))
    |> Enum.filter(&((guard == :all or &1.guard == guard) and in_scope.(&1)))
  end

  defp guard_verdict(%Event{name: @decision_guard_verdict, metadata: meta, seq: seq}, runs) do
    [
      verdict(:decision_guard, meta, seq, runs,
        verdict: atom_or_nil(meta[:verdict]),
        surface: atom_or_nil(meta[:surface]),
        action: atom_or_nil(meta[:result])
      )
    ]
  end

  defp guard_verdict(%Event{name: @input_guard_verdict, metadata: meta, seq: seq}, runs) do
    [
      verdict(:input_guard, meta, seq, runs,
        verdict: atom_or_nil(meta[:severity]),
        action: atom_or_nil(meta[:action])
      )
    ]
  end

  defp guard_verdict(%Event{name: @loop_guard_advisory, metadata: meta, seq: seq}, runs) do
    [verdict(:loop_guard, meta, seq, runs, verdict: :advisory)]
  end

  defp guard_verdict(%Event{name: @hook_decision, metadata: meta, seq: seq}, runs) do
    if decision_guard_hook?(meta[:hook_name]) do
      []
    else
      [
        verdict(:hook, meta, seq, runs,
          verdict: atom_or_nil(meta[:verdict]),
          surface: atom_or_nil(meta[:event]),
          action: atom_or_nil(meta[:result])
        )
      ]
    end
  end

  defp guard_verdict(_event, _runs), do: []

  defp decision_guard_hook?("decision_guard:" <> _surface), do: true
  defp decision_guard_hook?(_name), do: false

  defp verdict(guard, meta, seq, runs, fields) do
    run_id = string_or_nil(meta[:agent_run_id])

    struct!(
      GuardVerdict,
      [
        guard: guard,
        agent_run_id: run_id,
        parent_agent_run_id: parent_of(run_id, meta, runs),
        tool_call_id: string_or_nil(meta[:tool_call_id]),
        metadata: meta,
        seq: seq
      ] ++ fields
    )
  end

  # ── structured output retries ──────────────────────────────────────────────

  @doc """
  The structured-output retries (`[:nous, :agent, :structured_output,
  :retry]`) in the trace, in order, as maps with `:agent_run_id`,
  `:parent_agent_run_id`, `:attempt`, `:retries_left`, `:errors` and
  `:seq`.

  Options: `:scope` (default `:tree`; see "Scope" in the moduledoc).
  """
  @spec output_retries(t(), keyword()) :: [map()]
  def output_retries(%__MODULE__{} = trace, opts \\ []) do
    runs = run_index(trace)
    in_scope = scope_filter(scope_opt(opts, :tree), runs)

    trace
    |> valid_events()
    |> Enum.flat_map(fn
      %Event{name: @output_retry, metadata: meta, measurements: measurements, seq: seq} ->
        run_id = string_or_nil(meta[:agent_run_id])

        [
          %{
            agent_run_id: run_id,
            parent_agent_run_id: parent_of(run_id, meta, runs),
            attempt: int_or_nil(meta[:attempt]),
            retries_left: int_or_nil(measurements[:retries_left]),
            errors: meta[:errors],
            seq: seq
          }
        ]

      _ ->
        []
    end)
    |> Enum.filter(in_scope)
  end

  # ── runs ───────────────────────────────────────────────────────────────────

  @doc """
  The agent runs in the trace as `Nous.Eval.Trace.AgentRun`s in start order,
  with `children` linking each run to the runs it started. The root run is
  the one without a `parent_agent_run_id`.
  """
  @spec runs(t()) :: [AgentRun.t()]
  def runs(%__MODULE__{} = trace) do
    by_id =
      trace
      |> valid_events()
      |> Enum.reduce(%{}, &run_event/2)

    ordered = by_id |> Map.values() |> Enum.sort_by(& &1.seq)

    children =
      Enum.group_by(
        ordered,
        & &1.parent_agent_run_id,
        & &1.agent_run_id
      )

    Enum.map(ordered, fn %AgentRun{} = run ->
      %AgentRun{run | children: Map.get(children, run.agent_run_id, [])}
    end)
  end

  @doc """
  The `agent_run_id` of the root run, or `nil` when the trace has no root
  run start event.
  """
  @spec root_run_id(t()) :: String.t() | nil
  def root_run_id(%__MODULE__{} = trace) do
    trace
    |> runs()
    |> Enum.find_value(fn run -> if is_nil(run.parent_agent_run_id), do: run.agent_run_id end)
  end

  defp run_event(%Event{name: @run_start, metadata: meta, seq: seq}, acc) do
    case meta[:agent_run_id] do
      id when is_binary(id) and not is_map_key(acc, id) ->
        run = %AgentRun{
          agent_run_id: id,
          parent_agent_run_id: string_or_nil(meta[:parent_agent_run_id]),
          parent_tool_call_id: string_or_nil(meta[:parent_tool_call_id]),
          role: atom_or_nil(meta[:role]),
          agent_name: string_or_nil(meta[:agent_name]),
          sub_agent_template: string_or_nil(meta[:sub_agent_template]),
          sub_agent_index: int_or_nil(meta[:sub_agent_index]),
          seq: seq
        }

        Map.put(acc, id, run)

      _ ->
        acc
    end
  end

  defp run_event(%Event{name: @run_stop, metadata: meta}, acc),
    do: end_run(acc, meta, :ok, nil)

  defp run_event(%Event{name: @run_exception, metadata: meta}, acc),
    do: end_run(acc, meta, :error, meta[:reason])

  defp run_event(_event, acc), do: acc

  defp end_run(acc, meta, status, error) do
    case Map.fetch(acc, meta[:agent_run_id]) do
      {:ok, %AgentRun{status: :incomplete} = run} ->
        Map.put(acc, run.agent_run_id, %AgentRun{run | status: status, error: error})

      _ ->
        acc
    end
  end

  defp run_index(trace), do: Map.new(runs(trace), &{&1.agent_run_id, &1})

  # ── transcript ─────────────────────────────────────────────────────────────

  @doc """
  Rebuilds the message history of a run from its events, for runs that
  failed before returning a context.

  The result is the request messages of the run's last model request, its
  response (when it completed), and a tool message for every tool call
  that finished after that response. Returns `[]` when the run made no
  model request.

  Options: `:run` - the `agent_run_id` (default: the root run).
  """
  @spec transcript(t(), keyword()) :: [Nous.Message.t()]
  def transcript(%__MODULE__{} = trace, opts \\ []) do
    run_id = Keyword.get_lazy(opts, :run, fn -> root_run_id(trace) end)

    trace
    |> model_calls()
    |> Enum.filter(&(&1.agent_run_id == run_id and is_list(&1.messages)))
    |> List.last()
    |> case do
      nil ->
        []

      %ModelCall{} = last ->
        response = if last.response, do: [last.response], else: []

        tool_messages =
          trace
          |> tool_calls(scope: {:run, run_id}, include: :all)
          |> Enum.filter(&(&1.seq > last.seq and &1.outcome != :incomplete))
          |> Enum.map(&tool_message/1)

        last.messages ++ response ++ tool_messages
    end
  end

  defp tool_message(%ToolCall{} = call) do
    content =
      case call do
        %ToolCall{result: result} when is_binary(result) or is_map(result) -> result
        %ToolCall{error: error} when is_binary(error) -> error
        %ToolCall{error: nil, result: nil} -> ""
        %ToolCall{error: nil, result: result} -> inspect(result)
        %ToolCall{error: error} -> inspect(error)
      end

    opts = if call.name, do: [name: call.name], else: []
    Nous.Message.tool(call.id, content, opts)
  end

  # ── shared ─────────────────────────────────────────────────────────────────

  # Events with the shape the queries rely on, in `seq` order; anything else
  # is skipped so a malformed event can never make a query raise.
  defp valid_events(%__MODULE__{events: events}) when is_list(events) do
    events
    |> Enum.flat_map(fn
      %Event{name: name, metadata: meta, seq: seq} = event
      when is_list(name) and is_map(meta) and is_integer(seq) ->
        measurements = if is_map(event.measurements), do: event.measurements, else: %{}
        [%Event{event | measurements: measurements}]

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.seq)
  end

  defp valid_events(_trace), do: []

  defp scope_opt(opts, default) do
    case Keyword.get(opts, :scope, default) do
      scope when scope in [:root, :tree] -> scope
      {:run, id} = scope when is_binary(id) -> scope
      {:sub_agent, template} = scope when is_binary(template) -> scope
      other -> raise ArgumentError, "invalid trace scope #{inspect(other)}"
    end
  end

  defp include_opt(opts) do
    case Keyword.get(opts, :include, [:executed]) do
      :all ->
        :all

      list when is_list(list) ->
        if Enum.all?(list, &(&1 in ToolCall.outcomes())),
          do: list,
          else: raise(ArgumentError, "invalid tool call include #{inspect(list)}")

      other ->
        raise ArgumentError, "invalid tool call include #{inspect(other)}"
    end
  end

  defp scope_filter(:tree, _runs), do: fn _item -> true end
  defp scope_filter(:root, _runs), do: &is_nil(&1.parent_agent_run_id)
  defp scope_filter({:run, id}, _runs), do: &(&1.agent_run_id == id)

  defp scope_filter({:sub_agent, template}, runs) do
    ids =
      for {id, %AgentRun{sub_agent_template: ^template}} <- runs, into: MapSet.new(), do: id

    &MapSet.member?(ids, &1.agent_run_id)
  end

  # The run start event is authoritative for the parent; the correlation key
  # on the event itself covers traces whose start event was not captured.
  defp parent_of(run_id, meta, runs) do
    case Map.fetch(runs, run_id) do
      {:ok, %AgentRun{parent_agent_run_id: parent}} -> parent
      :error -> string_or_nil(meta[:parent_agent_run_id])
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_value), do: nil

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil

  defp list_or_nil(value) when is_list(value), do: value
  defp list_or_nil(_value), do: nil

  defp bool_or_nil(value) when is_boolean(value), do: value
  defp bool_or_nil(_value), do: nil

  defp atom_or_nil(value) when is_atom(value) and not is_boolean(value), do: value
  defp atom_or_nil(_value), do: nil

  defp response_or_nil(%Nous.Message{} = message), do: message
  defp response_or_nil(_value), do: nil

  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: 0
end

defmodule Nous.Eval.TraceBuilder do
  @moduledoc false
  # Builds synthetic `Nous.Eval.Trace`s whose events mirror the telemetry
  # contract (research/telemetry-naming.md §5): every event carries the
  # correlation keys `trace_id`, `agent_run_id` and `parent_agent_run_id`;
  # tool call events carry `tool_call_id`.

  alias Nous.Eval.{Case, ScoreInput, Trace}
  alias Nous.Eval.Trace.Event

  defstruct trace_id: "0123456789abcdef0123456789abcdef",
            events: [],
            seq: 0,
            parents: %{},
            call_n: 0

  def new(trace_id \\ "0123456789abcdef0123456789abcdef"), do: %__MODULE__{trace_id: trace_id}

  def build(%__MODULE__{} = b, opts \\ []) do
    %Trace{
      trace_id: b.trace_id,
      events: Enum.reverse(b.events),
      truncated?: Keyword.get(opts, :truncated?, false),
      dropped: Keyword.get(opts, :dropped, 0)
    }
  end

  @doc "Appends an event emitted inside `run_id` (nil = outside any run)."
  def event(%__MODULE__{} = b, name, measurements, metadata, run_id) do
    correlation = %{
      trace_id: b.trace_id,
      agent_run_id: run_id,
      parent_agent_run_id: Map.get(b.parents, run_id)
    }

    event = %Event{
      name: name,
      measurements: measurements,
      metadata: Map.merge(correlation, metadata),
      at: b.seq * 1_000,
      seq: b.seq
    }

    %{b | events: [event | b.events], seq: b.seq + 1}
  end

  # ── runs ──

  def run_start(b, run_id, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    b = %{b | parents: Map.put(b.parents, run_id, parent)}

    event(
      b,
      [:nous, :agent, :run, :start],
      %{system_time: 0, monotonic_time: 0},
      %{
        agent_name: Keyword.get(opts, :agent_name, "agent"),
        model_name: "test-model",
        role: Keyword.get(opts, :role, :agent),
        parent_tool_call_id: Keyword.get(opts, :parent_tool_call_id),
        profile_id: nil,
        sub_agent_template: Keyword.get(opts, :sub_agent_template),
        sub_agent_index: Keyword.get(opts, :sub_agent_index)
      },
      run_id
    )
  end

  def run_stop(b, run_id),
    do: event(b, [:nous, :agent, :run, :stop], %{duration: 10}, %{agent_name: "agent"}, run_id)

  def run_exception(b, run_id, reason),
    do:
      event(
        b,
        [:nous, :agent, :run, :exception],
        %{duration: 10},
        %{kind: :error, reason: reason, agent_name: "agent"},
        run_id
      )

  # ── model ──

  def model_start(b, run_id, opts \\ []) do
    event(
      b,
      [:nous, :agent, :model, :start],
      %{system_time: 0, monotonic_time: 0},
      %{
        iteration: Keyword.get(opts, :iteration, 1),
        model_provider: Keyword.get(opts, :model_provider, :openai),
        model_name: Keyword.get(opts, :model_name, "gpt-4o"),
        stream: false,
        tool_names: Keyword.get(opts, :tool_names, []),
        blocked_tool_names: [],
        messages: Keyword.get(opts, :messages, []),
        agent_name: "agent"
      },
      run_id
    )
  end

  def model_stop(b, run_id, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{})
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)

    event(
      b,
      [:nous, :agent, :model, :stop],
      %{
        duration: 100,
        input_tokens: input,
        output_tokens: output,
        total_tokens: Map.get(usage, :total_tokens, input + output),
        cache_creation_input_tokens: Map.get(usage, :cache_creation_input_tokens, 0),
        cache_read_input_tokens: Map.get(usage, :cache_read_input_tokens, 0),
        tool_calls: Keyword.get(opts, :tool_calls, 0)
      },
      %{
        iteration: Keyword.get(opts, :iteration, 1),
        model_provider: Keyword.get(opts, :model_provider, :openai),
        model_name: Keyword.get(opts, :model_name, "gpt-4o"),
        active_model_provider:
          Keyword.get(opts, :active_model_provider, Keyword.get(opts, :model_provider, :openai)),
        active_model_name:
          Keyword.get(opts, :active_model_name, Keyword.get(opts, :model_name, "gpt-4o")),
        fallback_used: false,
        finish_reason: Keyword.get(opts, :finish_reason, "stop"),
        requested_tool_calls: [],
        response: Keyword.get(opts, :response),
        agent_name: "agent"
      },
      run_id
    )
  end

  def model_exception(b, run_id, reason, opts \\ []) do
    event(
      b,
      [:nous, :agent, :model, :exception],
      %{duration: 50},
      %{
        iteration: Keyword.get(opts, :iteration, 1),
        model_provider: :openai,
        model_name: "gpt-4o",
        kind: :error,
        reason: reason,
        agent_name: "agent"
      },
      run_id
    )
  end

  # ── tool calls ──

  def tool_start(b, run_id, call_id, name, args, opts \\ []) do
    event(
      b,
      [:nous, :agent, :tool_call, :start],
      %{system_time: 0, monotonic_time: 0},
      %{
        tool_call_id: call_id,
        tool_name: name,
        arguments: args,
        iteration: Keyword.get(opts, :iteration, 1),
        agent_name: "agent"
      },
      run_id
    )
  end

  def tool_stop(b, run_id, call_id, name, opts \\ []) do
    metadata = %{
      tool_call_id: call_id,
      tool_name: name,
      outcome: Keyword.get(opts, :outcome, :executed),
      approval: Keyword.get(opts, :approval, :not_required),
      result: Keyword.get(opts, :result, "ok"),
      result_modified: false,
      error: Keyword.get(opts, :error),
      agent_name: "agent"
    }

    metadata =
      case Keyword.fetch(opts, :arguments) do
        {:ok, edited} -> Map.put(metadata, :arguments, edited)
        :error -> metadata
      end

    event(b, [:nous, :agent, :tool_call, :stop], %{duration: 5}, metadata, run_id)
  end

  @doc "A complete call (start + stop). Options go to both; `:id` overrides the generated id."
  def tool_call(b, run_id, name, args, opts \\ []) do
    {id, b} = next_id(b, opts)

    b
    |> tool_start(run_id, id, name, args, opts)
    |> tool_stop(run_id, id, name, opts)
  end

  defp next_id(b, opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} -> {id, b}
      :error -> {"call_#{b.call_n}", %{b | call_n: b.call_n + 1}}
    end
  end

  @doc """
  A root run whose model responses request the given calls. Each element is
  one model response: a `{name, args}` call, a `{name, args, opts}` call, or
  a list of those (a parallel batch). Iterations count from 1.
  """
  def trajectory(steps, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "root0000root0000")

    steps
    |> Enum.with_index(1)
    |> Enum.reduce(new() |> run_start(run_id), fn {step, iteration}, b ->
      step
      |> List.wrap()
      |> Enum.reduce(b, fn
        {name, args}, b ->
          tool_call(b, run_id, name, args, iteration: iteration)

        {name, args, call_opts}, b ->
          tool_call(b, run_id, name, args, [iteration: iteration] ++ call_opts)
      end)
    end)
    |> run_stop(run_id)
    |> build(Keyword.take(opts, [:truncated?]))
  end

  # ── guards ──

  def decision_guard_verdict(b, run_id, surface, verdict, opts \\ []) do
    b =
      event(
        b,
        [:nous, :decision_guard, :verdict],
        %{duration: 1, chunk_count: 1},
        %{
          surface: surface,
          verdict: verdict,
          result: Keyword.get(opts, :result, verdict_result(verdict)),
          probabilities: %{},
          canary_failed: 0,
          error: nil,
          agent_name: "agent",
          tool_call_id: Keyword.get(opts, :tool_call_id)
        },
        run_id
      )

    # DecisionGuard hook surfaces also report through the hook runner.
    if surface == :user_input do
      b
    else
      hook_decision(b, run_id, "decision_guard:#{surface}", verdict, opts)
    end
  end

  def hook_decision(b, run_id, hook_name, verdict, opts \\ []) do
    event(
      b,
      [:nous, :hook, :decision],
      %{duration: 1, chunk_count: 1},
      %{
        event: Keyword.get(opts, :event, :pre_tool_use),
        hook_name: hook_name,
        verdict: verdict,
        result: verdict_result(verdict),
        probabilities: %{},
        canary_failed: 0,
        backend: :test,
        model: "m",
        error: nil,
        tool_call_id: Keyword.get(opts, :tool_call_id)
      },
      run_id
    )
  end

  defp verdict_result(:deny), do: :deny
  defp verdict_result(_verdict), do: :allow

  def input_guard_verdict(b, run_id, severity, action \\ :allow) do
    event(
      b,
      [:nous, :input_guard, :verdict],
      %{duration: 1, strategies: 1, dropped: 0},
      %{
        severity: severity,
        aggregation: :any,
        fail_closed: false,
        action: action,
        agent_name: "agent"
      },
      run_id
    )
  end

  def loop_guard_advisory(b, run_id, tier \\ 0) do
    event(
      b,
      [:nous, :loop_guard, :advisory],
      %{chain_length: 3},
      %{threshold: 3, tier: tier, signatures: ["search:abc"], agent_name: "agent"},
      run_id
    )
  end

  def output_retry(b, run_id, attempt) do
    event(
      b,
      [:nous, :agent, :structured_output, :retry],
      %{retries_left: 3 - attempt},
      %{attempt: attempt, errors: "name: can't be blank", agent_name: "agent"},
      run_id
    )
  end

  # ── score input ──

  def input(trace, opts \\ []) do
    %ScoreInput{
      case: Keyword.get(opts, :case, %Case{id: "case-1", input: "question"}),
      sample: 0,
      run_outcome: Keyword.get(opts, :run_outcome, {:ok, %{}}),
      trace: trace,
      output: Keyword.get(opts, :output),
      usage: Keyword.get(opts, :usage, %Nous.Usage{}),
      duration_ms: Keyword.get(opts, :duration_ms, 0)
    }
  end
end

defmodule Nous.Telemetry do
  @moduledoc """
  Telemetry integration for Nous AI: the catalog of every event Nous emits.

  All times are in `:native` time unit. Use `System.convert_time_unit/3` to
  convert to the unit you report in.

  ## Correlation keys

  Every event below carries these metadata keys, always present:

    * `trace_id` — 32 lowercase hex chars. One trace spans a root agent run and
      every run nested in it (a sub-agent, an agent a tool starts).
    * `agent_run_id` — 16 lowercase hex chars, unique per agent run. Minted by
      `Nous.run/3`, `Nous.AgentRunner.run/3`, `run_with_context/3`,
      `run_stream/3` and every `Nous.AgentServer` turn; concurrent runs never
      share one.
    * `parent_agent_run_id` — the enclosing run's `agent_run_id`, or `nil` for a
      root run.
    * `tool_call_id` — the provider tool-call id being executed, or `nil`.
      Set on everything a tool body emits (its `[:nous, :tool, *]` events, a
      provider call it makes), and explicitly on `[:nous, :agent, :tool_call, *]`,
      hook events about a tool call and DecisionGuard verdicts on tool
      surfaces. A run nested in a tool starts with `tool_call_id: nil` and
      records the spawning call as `parent_tool_call_id` on its run start.

  The values are `nil` outside an agent run, so a handler can match
  `%{trace_id: trace_id}` uniformly. Ids are opaque strings, never atoms.
  `[:nous, :agent, :run, :start]` additionally carries `parent_tool_call_id`
  (the tool call that started this run, e.g. a `Nous.Plugins.SubAgent`
  delegation), `role` (`:agent`, or `:judge | :simulator | :reflector` for
  runs Nous starts on its own behalf), `profile_id` (the id of the
  `Nous.Profile` the run's agent applies, `nil` without one) and, for
  sub-agent runs, `sub_agent_template` (the template name, `nil` for an
  inline model) and `sub_agent_index` (the task's position in a
  `spawn_agents` call, else `nil`).

  The ids follow the work across processes Nous starts: parallel tool calls,
  timed tool bodies, hook and guard tasks, sub-agents, AgentServer turn tasks,
  and a `run_stream/3` stream enumerated in another process. A process you
  start yourself with `Task` inherits them through `$callers`; one started
  with `spawn/1` or a GenServer does not.

  ## Content keys and off-box handlers

  Several keys carry user and model content by reference: `messages` and
  `response` (model events), `arguments` and `result` (tool-call events),
  `details`/`reason` (guard strategy verdicts), `errors` (structured-output
  retries), and every raw `reason`/`stacktrace`/`error`. They are safe for
  in-process handlers, but a model response or tool result can contain
  secrets or personal data, so **any subscriber that forwards these events
  off-box (Sentry, Honeycomb, log shippers) MUST scrub those keys first.**
  Nous does not redact, to preserve debuggability for trusted handlers.

  ## Agent Events

    * `[:nous, :agent, :run, :start]` - an agent run starts (every entry point).
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string,
        tool_count: integer, has_tools: boolean, trace_id, agent_run_id,
        parent_agent_run_id, tool_call_id, parent_tool_call_id, role, profile_id,
        sub_agent_template, sub_agent_index}`

    * `[:nous, :agent, :run, :stop]` - an agent run completes. Also fires after
      a successful structured-output retry; for `run_stream/3` it fires when the
      stream yields `{:complete, _}` (a consumer that stops enumerating earlier
      leaves a start without a stop).
      * Measurement: `%{duration: native_time, total_tokens: integer, input_tokens: integer,
        output_tokens: integer, tool_calls: integer, requests: integer, iterations: integer}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string,
        active_model_provider: atom, active_model_name: string, fallback_used: boolean,
        profile_id: string | nil}`.
        `model_*` is the configured model, `active_model_*` the one the run's
        last request went to (routing or a fallback may differ).

    * `[:nous, :agent, :run, :exception]` - an agent run fails: it returned
      `{:error, reason}` (`kind: :error`, `stacktrace: []`), or raised, threw or
      exited (`kind` and the real `stacktrace`; the raise then propagates). A
      process killed mid-run emits nothing.
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{agent_name: string, model_provider: atom, model_name: string,
        kind: atom, reason: term, stacktrace: list, profile_id: string | nil}`

    * `[:nous, :agent, :iteration, :start]` - before each agent iteration
      * Measurement: `%{system_time: native_time}`
      * Metadata: `%{agent_name: string, iteration: integer, max_iterations: integer}`

    * `[:nous, :agent, :iteration, :stop]` - after each agent iteration
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{agent_name: string, iteration: integer, tool_calls: integer, needs_response: boolean}`

    * `[:nous, :agent, :model, :start]` - one model request of a run (fallback
      chain and rate limiter included), from the agent loop and `run_stream/3`.
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{agent_name, iteration: integer, model_provider: atom,
        model_name: string, stream: boolean, tool_names: [string],
        blocked_tool_names: [string], messages: [Nous.Message.t()]}`.
        `model_*` is the model the request was built for; `tool_names` the
        tools offered; `blocked_tool_names` the tools the agent's permission
        policy removed from the offer.

    * `[:nous, :agent, :model, :stop]` - the model answered.
      * Measurement: `%{duration: native_time, input_tokens, output_tokens,
        total_tokens, cache_creation_input_tokens, cache_read_input_tokens,
        tool_calls: integer}` (token keys are the `Nous.Usage` fields; 0 when
        the provider reported none) plus `time_to_first_token: native_time`
        on streamed requests that produced output.
      * Metadata: `%{agent_name, iteration, model_provider, model_name,
        active_model_provider, active_model_name, fallback_used: boolean,
        finish_reason: term, requested_tool_calls: [%{tool_call_id, tool_name}],
        response: Nous.Message.t()}`

    * `[:nous, :agent, :model, :exception]` - the request failed (after the
      whole fallback chain).
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{agent_name, iteration, model_provider, model_name, kind: atom, reason: term}`

    * `[:nous, :agent, :tool_call, :start]` - the runner starts handling one
      tool call the model requested (before hooks and approval).
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{agent_name, tool_call_id, tool_name, arguments, iteration}`
        (`iteration` matches the model span that requested the call)

    * `[:nous, :agent, :tool_call, :stop]` - the call's result message is final.
      Failures are outcomes, never a separate exception event; a crash of the
      run process itself leaves a start without a stop.
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{agent_name, tool_call_id, tool_name, outcome, approval,
        result, result_modified: boolean, error}` and, when `approval: :edited`,
        the post-edit `arguments`.
        * `outcome`: `:executed` (the tool ran to a return; `error` holds an
          `{:error, term}` it returned), `:invalid_arguments` (unparseable JSON or
          a schema refusal), `:collapsed` (not callable under Code Mode),
          `:hook_denied`, `:hook_stage_failed` (the parallel pre_tool_use stage
          crashed or timed out), `:approval_rejected`, `:not_found`, `:timeout`,
          `:crashed` (raised, threw or exited)
        * `approval`: `:not_required` (no approval was consulted: the tool needs
          none, or the call never reached the gate), `:approved`, `:edited`,
          `:rejected`
        * `result`: the content the model sees (after post_tool_use hooks);
          `result_modified`: a post_tool_use hook rewrote it

    * `[:nous, :agent, :structured_output, :retry]` - structured output failed
      validation and the runner asks the model again.
      * Measurement: `%{retries_left: integer}` (remaining after this retry)
      * Metadata: `%{agent_name, attempt: integer, errors: string}`

  ## Provider Events

    * `[:nous, :provider, :request, :start]` - Dispatched before calling provider API
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{provider: atom, model_name: string, message_count: integer}`

    * `[:nous, :provider, :request, :stop]` - Dispatched after provider responds
      * Measurement: `%{duration: native_time, input_tokens: integer, output_tokens: integer, total_tokens: integer}`
      * Metadata: `%{provider: atom, model_name: string, has_tool_calls: boolean}`

    * `[:nous, :provider, :request, :exception]` - Dispatched when provider request fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string, kind: atom, reason: term}`

  ## Provider Streaming Events

    * `[:nous, :provider, :stream, :start]` - Dispatched before starting a streaming request
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{provider: atom, model_name: string, message_count: integer}`

    * `[:nous, :provider, :stream, :connected]` - Dispatched when stream connection is established
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string}`

    * `[:nous, :provider, :stream, :exception]` - Dispatched when streaming request fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{provider: atom, model_name: string, kind: atom, reason: term}`

  There is no provider stream `:stop`; the model span's `:stop` carries a
  streamed request's usage and `time_to_first_token`.

  ## Tool Events

  Emitted by `Nous.ToolExecutor` for every attempt; inside an agent run they
  carry the call's `tool_call_id` from the correlation keys.

    * `[:nous, :tool, :execute, :start]` - Dispatched before tool execution
      * Measurement: `%{system_time: native_time, monotonic_time: monotonic_time}`
      * Metadata: `%{tool_name: string, tool_module: module | nil, attempt: integer, max_retries: integer, has_timeout: boolean}`

    * `[:nous, :tool, :execute, :stop]` - Dispatched after tool completes
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{tool_name: string, attempt: integer, success: boolean}`

    * `[:nous, :tool, :execute, :exception]` - Dispatched when tool fails
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{tool_name: string, attempt: integer, will_retry: boolean, kind: atom, reason: term, stacktrace: list}`
        (the timeout variant has `kind: :timeout` and no `stacktrace`)

    * `[:nous, :tool, :timeout]` - Dispatched when tool times out
      * Measurement: `%{timeout: integer}`
      * Metadata: `%{tool_name: string}`

  ## Context Events

    * `[:nous, :context, :update]` - Dispatched when context deps are updated by a tool
      * Measurement: `%{keys_updated: integer}`
      * Metadata: `%{agent_name: string, keys: list(atom)}`

  ## Callback Events

    * `[:nous, :callback, :execute]` - Dispatched when a callback is executed
      * Measurement: `%{duration: native_time}`
      * Metadata: `%{callback_type: atom, agent_name: string}`

  ## Fallback Events

    * `[:nous, :agent, :fallback, :used]` - Dispatched when a model other than
      the one the request was built for (the routed model, else the agent's)
      answered (sticky-fallback). Use this to alert on provider degradation.
      * Measurement: `%{system_time: native_time}`
      * Metadata: `%{agent_name, iteration, original_provider, original_model,
        active_provider, active_model}`

    * `[:nous, :fallback, :activated]` - Dispatched when the fallback chain
      promotes to the next model after one returns a fallback-eligible error
      (the prefix is configurable with `Nous.Fallback`'s `:telemetry_prefix`).
      * Measurement: `%{system_time: native_time}`
      * Metadata: `%{failed_provider: atom, failed_model: string,
        next_provider: atom, next_model: string, reason: term}`

  ## Router Events

    * `[:nous, :router, :route]` - Dispatched each time the agent's
      `Nous.Router` is consulted.
      * Measurement: `%{duration: native_time}` (the router call's latency)
      * Metadata: `%{agent_name, router, granularity, turn, iteration, cause,
        tier, probabilities, confidence, reason, model_provider, model_name}`

  ## Rate Limiter Events

    * `[:nous, :rate_limiter, :unavailable]` - a team `Nous.Teams.RateLimiter`
      could not be reached; the request went through un-limited (fail open).
      * Measurement: `%{count: 1}`
      * Metadata: `%{agent_name}`

  ## Hook Events

  `tool_call_id` on every hook event is the `:pre_tool_use` /
  `:post_tool_use` payload's `:tool_id` (else the correlation key).

    * `[:nous, :hook, :execute, :start]` / `[:nous, :hook, :execute, :stop]`
      * Measurement: `%{system_time | duration}`
      * Metadata: `%{event, hook_name, hook_type, tool_call_id, result?}`
    * `[:nous, :hook, :denied]` - emitted when a blocking hook returns :deny
      or when a fail_closed hook errors.
      * Metadata: `%{event, hook_name, hook_type, tool_call_id, reason?}`
    * `[:nous, :hook, :failed_closed]` - emitted when a `fail_closed: true` hook
      errors (including a timeout): the event was denied, or on `:post_tool_use`
      the tool result was withheld.
      * Measurement: `%{system_time}`
      * Metadata: `%{event, hook_name, hook_type, tool_call_id, reason}`
    * `[:nous, :hook, :decision]` - one evaluation of a `:decision` hook
      (`Nous.Hook.Decision`).
      * Measurement: `%{duration, chunk_count}`
      * Metadata: `%{event, hook_name, tool_call_id, verdict, result,
        probabilities, backend, model, canary_failed, error}`

  ## Guard Events

    * `[:nous, :decision_guard, :verdict]` - one check by
      `Nous.Plugins.DecisionGuard`, on any surface. On hook surfaces the same
      check also emits `[:nous, :hook, :decision]` (hook name
      `"decision_guard:<surface>"`).
      * Measurement: `%{duration, chunk_count}`
      * Metadata: `%{surface, agent_name, tool_call_id, verdict, result,
        probabilities, canary_failed, error}`
    * `[:nous, :decision_guard, :canary_failed]` - a DecisionGuard canary was
      answered wrongly.
      * Measurement: `%{count}`
      * Metadata: `%{surface}`
    * `[:nous, :input_guard, :verdict]` - the aggregate verdict of one
      `Nous.Plugins.InputGuard` check (all unchecked user messages of a request).
      * Measurement: `%{duration, strategies: integer, dropped: integer}`
        (`strategies` configured per message; `dropped` summed over messages)
      * Metadata: `%{agent_name, severity: :safe | :suspicious | :blocked,
        aggregation, fail_closed: boolean, action}`. `fail_closed` is true when
        the verdict is a fail-closed result; `action` is the policy action
        taken (`Nous.Plugins.InputGuard.Policy.action_for/2`).
    * `[:nous, :input_guard, :strategy_verdict]` /
      `[:nous, :decision_guard, :strategy_verdict]` - one strategy's verdict
      (`Nous.Plugins.InputGuard.Engine`).
      * Measurement: `%{duration}`
      * Metadata: `%{strategy: module, severity, reason, details: map, error}`
    * `[:nous, :input_guard, :strategy_dropped]` /
      `[:nous, :decision_guard, :strategy_dropped]` - one or more strategies
      produced no verdict (`Nous.Plugins.InputGuard.Engine`).
      * Measurement: `%{count}`
      * Metadata: `%{aggregation, fail_closed}`
    * `[:nous, :loop_guard, :advisory]` - `Nous.Plugins.LoopGuard` injected an
      advisory about a repeated tool call.
      * Measurement: `%{chain_length}`
      * Metadata: `%{agent_name, threshold, tier, signatures: [tool_name]}`

  ## Skill Events

    * `[:nous, :skill, :activate]`
      * Metadata: `%{skill_name, group, activation_type}`
    * `[:nous, :skill, :deactivate]`
      * Metadata: `%{skill_name, group}`

  ## Compaction Events

  Emitted by `Nous.Plugins.Summarization` (see its moduledoc).

    * `[:nous, :compaction, :start]`
      * Measurement: `%{system_time, monotonic_time}`
      * Metadata: `%{agent_name, messages_before}`
    * `[:nous, :compaction, :stop]`
      * Measurement: `%{duration, bytes_before, bytes_after}`
      * Metadata: `%{agent_name, messages_before, messages_after, llm_called,
        summarized, provider, model, usage}`
    * `[:nous, :compaction, :exception]`
      * Measurement: `%{duration}`
      * Metadata: `%{agent_name, messages_before, messages_after, llm_called,
        kind, reason, stacktrace}`

  ## Decision Model Events

  Emitted by `Nous.DecisionModel.decide/4` (guard and router classifier cost).

    * `[:nous, :decision_model, :decide, :start]`
      * Measurement: `%{system_time, monotonic_time}`
      * Metadata: `%{backend, model, question_count}`
    * `[:nous, :decision_model, :decide, :stop]`
      * Measurement: `%{duration, input_tokens}`
      * Metadata: `%{backend, model, question_count}`
    * `[:nous, :decision_model, :decide, :exception]`
      * Measurement: `%{duration}`
      * Metadata: `%{backend, model, question_count, kind, reason, stacktrace?}`

  ## Profile Events

    * `[:nous, :profile, :switched]` - a run continued a context started
      under another `Nous.Profile` (or none), so the conversation's system
      prompt was rebuilt from this run's profile before the first request.
      * Measurement: `%{system_time: native_time}`
      * Metadata: `%{agent_name: string, profile_id: string | nil,
        previous_profile_id: string | nil, action: :replaced | :updated}`.
        `:replaced` - the leading system message was replaced (a logged
        message event); `:updated` - the transcript has no system message
        (the AgentServer shape), so only `ctx.system_prompt` changed.

  ## Session Events

    * `[:nous, :session, :invariant, :violation]` - a request's message list
      broke a session invariant (`Nous.Session.Invariant`).
      * Measurement: `%{count: 1}`
      * Metadata: the violation details (`kind`, …) plus `agent_name, mode`

  ## Workflow Events

    * `[:nous, :workflow, :run, :start]` / `[:nous, :workflow, :run, :stop]`
      / `[:nous, :workflow, :run, :exception]`
    * `[:nous, :workflow, :node, :start]` / `[:nous, :workflow, :node, :stop]`
      / `[:nous, :workflow, :node, :exception]`
      * See `Nous.Workflow.Telemetry` for full measurement/metadata payloads.
        The correlation keys identify the enclosing agent run, if any — never
        the workflow execution.

  ## Default Handler

  Nous provides a default handler that logs events at appropriate levels:

      Nous.Telemetry.attach_default_handler()

  This is useful for development and debugging.

  ## Custom Handlers

      :telemetry.attach(
        "my-nous-handler",
        [:nous, :agent, :run, :stop],
        fn _event, measurements, metadata, _config ->
          MyApp.Metrics.track_agent_run(
            metadata.agent_name,
            measurements.duration,
            measurements.total_tokens
          )
        end,
        nil
      )

  ## Metrics Integration

  For production metrics, consider integrating with:
  - `telemetry_metrics` for Prometheus/StatsD
  - `telemetry_poller` for periodic metrics
  - Phoenix LiveDashboard for visualization

      defmodule MyApp.Telemetry do
        use Supervisor
        import Telemetry.Metrics

        def metrics do
          [
            counter("nous.agent.run.start.count"),
            distribution("nous.agent.run.stop.duration",
              unit: {:native, :millisecond}
            ),
            sum("nous.agent.run.stop.total_tokens"),
            counter("nous.tool.execute.stop.count",
              tags: [:tool_name]
            ),
            counter("nous.tool.timeout.count",
              tags: [:tool_name]
            )
          ]
        end
      end

  ## Examples

  Every event above is a plain `:telemetry` event, so attaching to one is just
  `:telemetry.attach/4`. This handler forwards tool timeouts to the calling
  process — the same shape you would use in a test to assert an event fired:

      iex> :telemetry.attach(
      ...>   "nous-doc-example",
      ...>   [:nous, :tool, :timeout],
      ...>   fn _event, measurements, metadata, pid ->
      ...>     send(pid, {:tool_timeout, metadata.tool_name, measurements.timeout})
      ...>   end,
      ...>   self()
      ...> )
      :ok
      iex> :telemetry.execute([:nous, :tool, :timeout], %{timeout: 5000}, %{tool_name: "bash"})
      :ok
      iex> receive do
      ...>   {:tool_timeout, tool_name, timeout} -> {tool_name, timeout}
      ...> after
      ...>   0 -> :no_event
      ...> end
      {"bash", 5000}
      iex> :telemetry.detach("nous-doc-example")
      :ok

  Durations are in `:native` units, so convert before reporting them:

      iex> System.convert_time_unit(System.convert_time_unit(120, :millisecond, :native), :native, :millisecond)
      120

  For local development, skip the wiring entirely and let Nous log everything
  it emits:

      Nous.Telemetry.attach_default_handler()
      {:ok, result} = Nous.run(agent, "Summarise this file")
      # [Nous] Agent assistant completed in 1832ms (947 tokens, 1 tool calls, 2 iterations)
      Nous.Telemetry.detach_default_handler()

  """

  require Logger

  # Every event Nous emits under its default names: the catalog above as data.
  # Consumers that must see everything (the eval trace collector) attach to
  # this list, and stored traces decode event names only through it
  # (`Nous.Eval.Codec`), so an event added to the catalog belongs here too.
  @events [
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
    [:nous, :profile, :switched],
    [:nous, :session, :invariant, :violation],
    [:nous, :workflow, :run, :start],
    [:nous, :workflow, :run, :stop],
    [:nous, :workflow, :run, :exception],
    [:nous, :workflow, :node, :start],
    [:nous, :workflow, :node, :stop],
    [:nous, :workflow, :node, :exception]
  ]

  @doc """
  Every event name Nous emits, as documented in the catalog above.

  Names are the defaults: an event whose prefix is configurable (the
  `Nous.Fallback` `:telemetry_prefix`, a guard engine's prefix) appears here
  under its default prefix only.

      :telemetry.attach_many("my-handler", Nous.Telemetry.events(), &MyApp.handle/4, nil)

  """
  @spec events() :: [[atom(), ...]]
  def events, do: @events

  @doc """
  Attaches the default logging handler for Nous events.

  This handler logs:
  - Agent runs (info level)
  - Provider requests (debug level)
  - Tool executions (debug level)
  - Exceptions (error level)

  Returns `{:error, :already_exists}` if it is already attached.

  ## Example

      Nous.Telemetry.attach_default_handler()

  """
  @spec attach_default_handler() :: :ok | {:error, :already_exists}
  def attach_default_handler do
    events = [
      # Agent events
      [:nous, :agent, :run, :start],
      [:nous, :agent, :run, :stop],
      [:nous, :agent, :run, :exception],
      [:nous, :agent, :iteration, :start],
      [:nous, :agent, :iteration, :stop],
      # Provider events
      [:nous, :provider, :request, :start],
      [:nous, :provider, :request, :stop],
      [:nous, :provider, :request, :exception],
      [:nous, :provider, :stream, :start],
      [:nous, :provider, :stream, :connected],
      [:nous, :provider, :stream, :exception],
      # Tool events
      [:nous, :tool, :execute, :start],
      [:nous, :tool, :execute, :stop],
      [:nous, :tool, :execute, :exception],
      [:nous, :tool, :timeout],
      # Context events
      [:nous, :context, :update],
      # Callback events
      [:nous, :callback, :execute]
    ]

    :telemetry.attach_many(
      "nous-default-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detaches the default handler.

  Returns `{:error, :not_found}` if it was never attached.
  """
  @spec detach_default_handler() :: :ok | {:error, :not_found}
  def detach_default_handler do
    :telemetry.detach("nous-default-handler")
  end

  # Event handlers

  defp handle_event([:nous, :agent, :run, :start], _measurements, metadata, _config) do
    Logger.info(
      "[Nous] Agent #{metadata.agent_name} starting (#{metadata.model_provider}:#{metadata.model_name})"
    )
  end

  defp handle_event([:nous, :agent, :run, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "[Nous] Agent #{metadata.agent_name} completed in #{duration_ms}ms " <>
        "(#{measurements.total_tokens} tokens, #{measurements.tool_calls} tool calls, #{measurements.iterations} iterations)"
    )
  end

  defp handle_event([:nous, :agent, :run, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Nous] Agent #{metadata.agent_name} failed after #{duration_ms}ms: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  defp handle_event([:nous, :provider, :request, :start], _measurements, metadata, _config) do
    Logger.debug("[Nous] Provider request to #{metadata.provider}:#{metadata.model_name}")
  end

  defp handle_event([:nous, :provider, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Provider #{metadata.provider}:#{metadata.model_name} responded in #{duration_ms}ms " <>
        "(#{measurements.total_tokens} tokens)"
    )
  end

  defp handle_event([:nous, :provider, :request, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Nous] Provider #{metadata.provider}:#{metadata.model_name} failed after #{duration_ms}ms: " <>
        summarize_reason(metadata.reason)
    )
  end

  defp handle_event([:nous, :provider, :stream, :start], _measurements, metadata, _config) do
    Logger.debug("[Nous] Stream request to #{metadata.provider}:#{metadata.model_name}")
  end

  defp handle_event([:nous, :provider, :stream, :connected], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Stream #{metadata.provider}:#{metadata.model_name} connected in #{duration_ms}ms"
    )
  end

  defp handle_event([:nous, :provider, :stream, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error(
      "[Nous] Stream #{metadata.provider}:#{metadata.model_name} failed after #{duration_ms}ms: " <>
        summarize_reason(metadata.reason)
    )
  end

  defp handle_event([:nous, :tool, :execute, :start], _measurements, metadata, _config) do
    Logger.debug("[Nous] Tool #{metadata.tool_name} executing (attempt #{metadata.attempt})")
  end

  defp handle_event([:nous, :tool, :execute, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Tool #{metadata.tool_name} #{if metadata.success, do: "succeeded", else: "failed"} " <>
        "in #{duration_ms}ms (attempt #{metadata.attempt})"
    )
  end

  defp handle_event([:nous, :tool, :execute, :exception], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    retry_msg = if metadata.will_retry, do: " (will retry)", else: " (final attempt)"

    Logger.warning(
      "[Nous] Tool #{metadata.tool_name} failed after #{duration_ms}ms#{retry_msg}: " <>
        "#{inspect(metadata.reason)}"
    )
  end

  # Tool timeout
  defp handle_event([:nous, :tool, :timeout], measurements, metadata, _config) do
    Logger.warning("[Nous] Tool #{metadata.tool_name} timed out after #{measurements.timeout}ms")
  end

  # Agent iteration events
  defp handle_event([:nous, :agent, :iteration, :start], _measurements, metadata, _config) do
    Logger.debug(
      "[Nous] Agent #{metadata.agent_name} iteration #{metadata.iteration}/#{metadata.max_iterations}"
    )
  end

  defp handle_event([:nous, :agent, :iteration, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    continue_msg = if metadata.needs_response, do: " (continuing)", else: " (done)"

    Logger.debug(
      "[Nous] Agent #{metadata.agent_name} iteration #{metadata.iteration} completed in #{duration_ms}ms" <>
        " (#{metadata.tool_calls} tool calls)#{continue_msg}"
    )
  end

  # Context update events
  defp handle_event([:nous, :context, :update], measurements, metadata, _config) do
    Logger.debug(
      "[Nous] Context updated for #{metadata.agent_name}: #{measurements.keys_updated} keys (#{inspect(metadata.keys)})"
    )
  end

  # Callback events
  defp handle_event([:nous, :callback, :execute], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[Nous] Callback #{metadata.callback_type} executed for #{metadata.agent_name} in #{duration_ms}ms"
    )
  end

  # Ignore unknown events for forward compatibility
  defp handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end

  # Reduce a provider error to a bounded, header/body-light summary. The raw
  # term is an HTTP error map (%{status, body, headers}) whose body can be large
  # and echo provider-side context; logging it verbatim is a log-volume and
  # reconnaissance risk. Drop headers, cap the body snippet.
  defp summarize_reason(%{status: status} = err) do
    "status=#{status}#{body_snippet(Map.get(err, :body))}"
  end

  defp summarize_reason(reason) when is_exception(reason), do: Exception.message(reason)

  defp summarize_reason(reason) do
    reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 300)
  end

  defp body_snippet(body) when is_binary(body), do: " body=#{String.slice(body, 0, 200)}"
  defp body_snippet(_), do: ""
end

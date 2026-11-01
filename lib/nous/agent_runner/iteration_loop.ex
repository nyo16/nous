defmodule Nous.AgentRunner.IterationLoop do
  @moduledoc false
  # Iteration orchestration for Nous.AgentRunner: the cancellation-checked
  # request/tool-call loop, per-iteration telemetry, model dispatch through the
  # rate limiter and fallback chain, and the response/error handling that
  # decides whether to loop again. Internal to the runner.
  #
  # Extracted verbatim from the AgentRunner facade (arch-review: "the
  # orchestration loop never left the facade" — do_iteration_body/3 was a
  # 199-line function reaching into 8 contexts). Pure move: the public API and
  # every telemetry event are unchanged.
  #
  # ## Turns and steps
  #
  # This module owns the iteration, so it is where turn and step boundaries are
  # recorded as durable events (`:turn_start`, `:step_start`, `:step_end`,
  # `:turn_end`) through `Nous.Agent.Context.log_event/3`:
  #
  #   * a **step** is one model request plus the tools it calls. A step is
  #     logged only when a request is actually dispatched, so counting
  #     `:step_start` events counts requests.
  #   * a **turn** is zero or more steps. It opens on entry to
  #     `execute_loop/3`, before its first input is claimed, and closes when
  #     nothing is owed. A turn with **zero steps is legal**: a `:pre_request`
  #     hook that denies the first claimed batch leaves exactly that, which is
  #     how a rejected attempt still leaves a record.
  #
  # `execute_loop/3` is therefore the turn boundary and is NOT the recursion
  # target; `loop/3` is. Recursing through `execute_loop/3` would nest one turn
  # inside another per iteration.
  #
  # `Nous.AgentRunner.run_stream/3` runs exactly one iteration, never enters
  # this loop, and is **explicitly out of scope for turns, steps and the
  # inbox** by decision. Do not retrofit them onto it: a stream is a single
  # request whose consumer owns the iteration, so "zero or more steps until
  # nothing is owed" has nothing to describe there.
  #
  # ## Claiming input mid-run
  #
  # When `ctx.deps[:claim_inbox]` holds a 1-arity function it is called at the
  # turn boundary with `:next_turn` and at every step boundary with
  # `:next_step`, and every `Nous.Message` it returns is appended to the log
  # before the request is built. That is the seam `Nous.Session.Inbox` and
  # `Nous.AgentServer.steer/2` are wired through; the loop itself knows nothing
  # about servers or queues. Without the key, nothing changes.

  alias Nous.{Errors, Hook, Message, Plugin, ToolCall}
  alias Nous.Agent.{Behaviour, Callbacks, Context}
  alias Nous.AgentRunner.{PromptAssembly, RequestDispatch, Routing, ToolExecution}
  alias Nous.Session.{Event, Log}

  require Logger

  # `ctx.deps` key holding this turn's exit reason once something other than
  # "nothing is owed" decided it. Runtime-only, and removed when the turn
  # closes so it never reaches `result.deps` or a persisted context.
  @exit_reason_key :__turn_exit_reason__

  # `ctx.deps` key holding the sticky fallback model once a fallback answered.
  # Runtime-only: see clear_runtime_models/1.
  @active_model_key :active_model

  # `ctx.deps` flag set once any request of the run was answered by a
  # fallback. Runtime-only; outlives the sticky model, which a routing
  # boundary clears.
  @fallback_used_key :__fallback_used__

  # A turn: opens before its first input is claimed, closes when nothing is
  # owed. `loop/3` is the recursion target — see the moduledoc note.
  def execute_loop(agent, behaviour, ctx) do
    case check_cancellation(ctx) do
      {:error, _} = err ->
        err

      # Checked before open_turn/1 so a run cancelled before it starts neither
      # logs a turn nor claims from the inbox — a claim into a context that is
      # about to be discarded would silently eat the queued input. `loop/3`
      # checks for every subsequent iteration, so this stays one check per step.
      :ok ->
        {ctx, turn} = open_turn(ctx)

        case do_iteration(agent, behaviour, ctx) do
          {:ok, ctx} ->
            {:ok, close_turn(ctx, turn)}

          # An error return carries no context, so this turn's `:turn_end` has
          # nowhere to live: AgentRunner discards the context on error and
          # AgentServer never persists it, which discards this turn's
          # `:turn_start` along with it. The log stays consistent by losing
          # both. A `:turn_start` that DID reach storage before a crash is
          # `Nous.Session.Recovery`'s problem, and `:interrupted` is its marker.
          {:error, _} = err ->
            err
        end
    end
  end

  defp loop(agent, behaviour, ctx) do
    case check_cancellation(ctx) do
      {:error, _} = err -> err
      :ok -> do_iteration(agent, behaviour, ctx)
    end
  end

  def check_cancellation(ctx) do
    if ctx.cancellation_check do
      try do
        ctx.cancellation_check.()
        :ok
      catch
        {:cancelled, reason} ->
          Logger.info("Agent execution cancelled: #{reason}")
          error = Errors.ExecutionCancelled.exception(reason: reason)
          {:error, error}
      end
    else
      :ok
    end
  end

  def do_iteration(agent, behaviour, ctx) do
    # Step boundary. Claim anything steered or injected since the last request
    # *before* asking whether anything is owed: a message that arrived mid-run
    # is exactly what makes another step owed, and claiming after the check
    # would strand it until some unrelated run began.
    {ctx, claimed} = claim(ctx, :next_step)

    cond do
      not ctx.needs_response ->
        {:ok, ctx}

      Context.max_iterations_reached?(ctx) ->
        Logger.error("""
        Max iterations exceeded
          Agent: #{agent.name}
          Max iterations: #{ctx.max_iterations}
          Total tokens used: #{ctx.usage.total_tokens}
        """)

        {:error, Errors.MaxIterationsExceeded.exception(max_iterations: ctx.max_iterations)}

      true ->
        instrumented_iteration(agent, behaviour, ctx, claimed)
    end
  end

  defp instrumented_iteration(agent, behaviour, ctx, claimed) do
    iteration_start = System.monotonic_time()

    :telemetry.execute(
      [:nous, :agent, :iteration, :start],
      %{system_time: System.system_time()},
      %{
        agent_name: agent.name,
        iteration: ctx.iteration,
        max_iterations: ctx.max_iterations
      }
    )

    result = do_iteration_body(agent, behaviour, ctx, claimed)

    iteration_duration = System.monotonic_time() - iteration_start

    iteration_meta = %{
      agent_name: agent.name,
      iteration: ctx.iteration,
      tool_calls:
        case result do
          {:ok, %{usage: %{tool_calls: tc}}} -> tc
          _ -> 0
        end,
      needs_response:
        case result do
          {:ok, %{needs_response: nr}} -> nr
          _ -> false
        end
    }

    :telemetry.execute(
      [:nous, :agent, :iteration, :stop],
      %{duration: iteration_duration},
      iteration_meta
    )

    result
  end

  def do_iteration_body(agent, behaviour, ctx, claimed) do
    {ctx, all_tools, pre_step_result} = prepare_tools(agent, behaviour, ctx, claimed)

    # If a plugin (e.g. InputGuard) halted execution or a hook denied, skip the
    # LLM call. A denial here is the `pre_step` rejection: the claimed batch
    # stays in the transcript (it happened, and dropping user input to record a
    # refusal would be a poor trade), but no step is spent on it, so the turn
    # closes with `reason: :rejected` — and with zero steps when this was the
    # first claim.
    if ctx.needs_response and not denied?(pre_step_result) do
      ctx = log_step_start(ctx)

      # One effective model per iteration: tool schemas, structured-output
      # settings and the dispatch chain are all built for the same model, so a
      # routed tier or a sticky fallback on another provider gets that
      # provider's formats. Routing runs here, after the pre_request verdict,
      # so a denied step spends no routing decision.
      {ctx, model} = effective_model(agent, ctx)
      request_agent = %{agent | model: model}

      {ctx, messages, model_settings} =
        prepare_request(agent, request_agent, behaviour, ctx, all_tools)

      Logger.debug(
        "Agent iteration #{ctx.iteration + 1}/#{ctx.max_iterations}: requesting model response"
      )

      case dispatch(request_agent, ctx, messages, model_settings, all_tools) do
        {:ok, response, active_model} ->
          ctx = record_active_model(agent, ctx, request_agent.model, active_model)
          handle_response(agent, behaviour, ctx, response, all_tools)

        {:error, reason} ->
          # Close the step before the error handler runs, so an unclosed
          # `:step_start` in a recovered log means "died inside the step" and
          # never "the request came back an error".
          ctx = log_step_end(ctx, :error)
          handle_request_error(agent, behaviour, ctx, reason)
      end
    else
      {:ok, note_rejection(ctx, pre_step_result)}
    end
  end

  # Assemble the tool set the model will see this iteration (behaviour tools +
  # plugin tools, minus anything the permission policy blocks) and run the
  # pre_request hooks — which double as the `pre_step` interception point, since
  # a step IS one model request. Returns `{ctx, all_tools, pre_step_verdict}`.
  def prepare_tools(agent, behaviour, ctx, claimed) do
    # Get tools from behaviour + plugins
    tools = behaviour.get_tools(agent)
    plugin_tools = Plugin.collect_tools(agent.plugins, agent, ctx)
    all_tools = tools ++ plugin_tools

    # Run plugin before_request hooks
    {ctx, all_tools} = Plugin.run_before_request(agent.plugins, agent, ctx, all_tools)

    # Plugin system prompt fragments are built AFTER before_request, because
    # that is where plugins react to the input in front of them (a skill with
    # `{:on_match, _}` activates there); built before it, a matched skill's
    # instructions never reached the model (#109). They are built on the first
    # iteration and again only when this step claimed new user input — the
    # only way input changes mid-run — so ordinary tool-loop iterations keep a
    # stable system prompt (provider prompt caches) and don't re-run plugins
    # whose prompt queries a store (Nous.Plugins.Decisions).
    ctx =
      if ctx.iteration == 0 or claimed != [],
        do: PromptAssembly.apply_plugin_system_prompts(agent, ctx),
        else: ctx

    # Enforce the permission policy: blocked tools are removed from the set the
    # model ever sees (and therefore can't be called). Approval is enforced
    # separately at execution time (see Nous.Permissions.enforce_approval/2).
    # Code Mode's `run_code` is injected after that filter — see
    # ToolExecution.visible_tools/2 for why it sits outside the restriction.
    all_tools = ToolExecution.visible_tools(agent, all_tools)

    # Run pre_request hooks (can block the LLM call). `claimed`/`claimed_content`
    # describe the batch this step boundary just took from the inbox, which is
    # what lets a hook reject *this input* instead of only "a request". Text,
    # not structs: a command hook JSON-encodes this payload and %Message{} is
    # not encodable.
    pre_step_result =
      Hook.Runner.run(
        ctx.hook_registry,
        :pre_request,
        %{
          agent_name: agent.name,
          tool_count: length(all_tools),
          iteration: ctx.iteration,
          claimed: length(claimed),
          claimed_content: Enum.map(claimed, &Message.extract_text/1)
        },
        fn -> Hook.Decision.env(ctx, agent.name) end
      )

    {ctx, all_tools, pre_step_result}
  end

  # Build the messages and model settings for this iteration's model call.
  # Returns `{ctx, messages, model_settings}` — ctx is threaded back out because
  # the tool-schema memo lives in it.
  #
  # `request_agent` carries the model this request is built for (see
  # effective_model/2): provider-shaped settings (tool schemas, structured
  # output) follow it. Messages and the behaviour's `before_request` stay on
  # the configured `agent`.
  def prepare_request(agent, request_agent, behaviour, ctx, all_tools) do
    # Build messages via behaviour
    messages = behaviour.build_messages(agent, ctx)

    # Add tools to model settings if any. Tool-schema conversion is memoized
    # per run on the (provider, tool-name set) — the set is stable across
    # iterations in the common case, so this skips re-converting every loop
    # (Anthropic conversion alone is ~12µs + ~90KB per iteration).
    {model_settings, ctx} =
      if Enum.empty?(all_tools) do
        {agent.model_settings, ctx}
      else
        {tool_schemas, ctx} =
          converted_tool_schemas(ctx, request_agent.model.provider, all_tools)

        {Map.put(agent.model_settings, :tools, tool_schemas), ctx}
      end

    # Inject structured output settings
    model_settings =
      if agent.output_type != :string do
        PromptAssembly.inject_structured_output_settings(
          request_agent,
          model_settings,
          all_tools
        )
      else
        model_settings
      end

    # Apply before_request callback if implemented
    model_settings =
      Behaviour.call(
        behaviour,
        :before_request,
        [agent, ctx, Keyword.new(model_settings)],
        Keyword.new(model_settings)
      )
      |> Map.new()

    {ctx, messages, model_settings}
  end

  # The model this iteration's request is built for and dispatched to: the
  # sticky fallback recorded earlier in this run, else the routed model, else
  # the configured one. At a routing boundary (Nous.Router granularity) the
  # router is consulted first and its new decision clears the sticky fallback.
  defp effective_model(%{router: nil} = agent, ctx) do
    {ctx, Map.get(ctx.deps, @active_model_key) || agent.model}
  end

  defp effective_model(agent, ctx) do
    {turn, _steps} = turn_cursor(ctx)

    ctx =
      case Routing.route(agent, ctx, turn) do
        {:boundary, ctx} -> %{ctx | deps: Map.delete(ctx.deps, @active_model_key)}
        {:hold, ctx} -> ctx
      end

    {ctx, Map.get(ctx.deps, @active_model_key) || Routing.routed_model(ctx) || agent.model}
  end

  # Make the model request (with fallback chain if configured). `request_agent`
  # already carries the effective model (effective_model/2), so the chain starts
  # there and settings are re-converted only for models of another provider.
  #
  # Enforce a team RateLimiter when one is wired into deps: reserve before the
  # call, reconcile actual usage after (or release on error). A denied acquire
  # surfaces as a normal {:error, reason} request result.
  def dispatch(request_agent, ctx, messages, model_settings, all_tools) do
    RequestDispatch.acquire_and_request(
      RequestDispatch.resolve_rate_limiter(ctx),
      request_agent,
      messages,
      fn ->
        if ctx.stream do
          RequestDispatch.stream_request_with_fallback(
            request_agent,
            messages,
            model_settings,
            all_tools,
            ctx
          )
        else
          RequestDispatch.request_with_fallback(
            request_agent,
            messages,
            model_settings,
            all_tools,
            ctx
          )
        end
      end
    )
  end

  # Record which model answered. A fallback happened only when the answering
  # model is not the one this request was built for (the routed model, when a
  # router chose one); it becomes sticky until the next routing boundary (the
  # rest of the run without a router) and is labelled once per change, so a
  # run that stays on the fallback emits `[:nous, :agent, :fallback, :used]`
  # exactly once. Track it in ctx for telemetry, but do NOT mutate
  # agent.model: mutating made the start-of-run telemetry tag one provider and
  # the stop another.
  defp record_active_model(agent, ctx, intended_model, active_model) do
    if active_model != intended_model and active_model != Map.get(ctx.deps, @active_model_key) do
      original = Routing.routed_model(ctx) || agent.model

      :telemetry.execute(
        [:nous, :agent, :fallback, :used],
        %{system_time: System.system_time()},
        %{
          agent_name: agent.name,
          original_provider: original.provider,
          original_model: original.model,
          active_provider: active_model.provider,
          active_model: active_model.model
        }
      )

      deps =
        ctx.deps
        |> Map.put(@active_model_key, active_model)
        |> Map.put(@fallback_used_key, true)

      %{ctx | deps: deps}
    else
      ctx
    end
  end

  @doc false
  # The model the run's last request went to: the sticky fallback, else the
  # routed model; nil when that was the configured model.
  def served_model(%Context{deps: deps} = ctx) do
    Map.get(deps, @active_model_key) || Routing.routed_model(ctx)
  end

  @doc false
  # Whether any request of this run was answered by a fallback model.
  def fallback_used?(%Context{deps: deps}), do: Map.get(deps, @fallback_used_key, false)

  @doc false
  # The sticky fallback, the fallback flag and the routing decision are
  # runtime-only, like the turn exit reason: dropped at run start (a new run
  # or AgentServer turn starts at the primary again and routes afresh) and
  # from the result's deps/context so they are never persisted.
  def clear_runtime_models(%Context{} = ctx) do
    deps = Map.drop(ctx.deps, [@active_model_key, @fallback_used_key])
    Routing.clear(%{ctx | deps: deps})
  end

  # Fold a successful model response into the context (usage, the blocking
  # post_response hook, callbacks, plugin after-response, behaviour processing,
  # tool calls) and re-enter the loop.
  def handle_response(agent, behaviour, ctx, response, all_tools) do
    # Update usage. Accounting stays before the post_response hook: a denied
    # response was still paid for.
    usage_update = response.metadata.usage || %{}
    ctx = Context.add_usage(ctx, usage_update)
    ctx = Context.increment_iteration(ctx)

    # Get total tokens safely from struct or map
    tokens_added =
      case usage_update do
        %{total_tokens: t} when is_integer(t) -> t
        _ -> 0
      end

    Logger.debug(
      "Model response received (tokens: +#{tokens_added}, total: #{ctx.usage.total_tokens})"
    )

    # post_response hooks run BEFORE anything else sees the response — the
    # callbacks (notify_pid, PubSub), plugins and the transcript — so a deny
    # actually withholds it. Deltas already emitted under `stream: true` cannot
    # be recalled.
    case run_post_response_hooks(agent, ctx, response) do
      {:deny, reason} ->
        # The runner hands back a string reason (`Nous.Hook.Runner` inspects
        # any other). The run ends here, so there is no context to close the
        # step on.
        Logger.info("Model response denied by post_response hook: #{reason}")
        {:error, Errors.ResponseDenied.exception(reason: reason)}

      {:ok, response} ->
        continue_response(agent, behaviour, ctx, response, all_tools)
    end
  end

  defp continue_response(agent, behaviour, ctx, response, all_tools) do
    # Execute callback
    Callbacks.execute(ctx, :on_llm_new_message, response)

    # Run plugin after_response hooks
    ctx = Plugin.run_after_response(agent.plugins, agent, response, ctx)

    # Process response via behaviour - this handles tool calls and updates needs_response
    ctx = behaviour.process_response(agent, response, ctx)

    # Check if we need to handle tool calls (behaviour may have set this up)
    ctx =
      if Message.has_tool_calls?(response) do
        ToolExecution.handle_tool_calls(agent, behaviour, ctx, response, all_tools)
      else
        ctx
      end

    # Close the step: one model request plus the tools it called.
    ctx = log_step_end(ctx, :ok)

    # Continue loop
    loop(agent, behaviour, ctx)
  end

  # Text, not structs, for the same reason as :pre_request: a command hook
  # JSON-encodes the payload. `{:modify, %{response: text}}` replaces the
  # message content before anything else sees it.
  defp run_post_response_hooks(agent, ctx, response) do
    if ctx.hook_registry && Hook.Registry.has_hooks?(ctx.hook_registry, :post_response) do
      payload = %{
        agent_name: agent.name,
        iteration: ctx.iteration,
        content: Message.extract_text(response),
        tool_calls:
          Enum.map(response.tool_calls, fn call ->
            %{name: ToolCall.field(call, :name), arguments: ToolCall.field(call, :arguments)}
          end)
      }

      env = fn -> Hook.Decision.env(ctx, agent.name) end

      case Hook.Runner.run(ctx.hook_registry, :post_response, payload, env) do
        :deny -> {:deny, "response denied by hook"}
        {:deny, reason} -> {:deny, reason}
        {:modify, %{response: text}} when is_binary(text) -> {:ok, %{response | content: text}}
        _allow -> {:ok, response}
      end
    else
      {:ok, response}
    end
  end

  # A failed model request: give the behaviour's handle_error a chance to retry
  # or continue before surfacing the error.
  def handle_request_error(agent, behaviour, ctx, reason) do
    Logger.error("""
    Model request failed in iteration #{ctx.iteration + 1}
      Agent: #{agent.name}
      Model: #{agent.model.provider}:#{agent.model.model}
      Reason: #{inspect(reason)}
    """)

    # Try error handler if implemented
    case Behaviour.call(behaviour, :handle_error, [agent, reason, ctx], {:error, reason}) do
      {:retry, new_ctx} ->
        loop(agent, behaviour, new_ctx)

      {:continue, new_ctx} ->
        loop(agent, behaviour, new_ctx)

      {:error, _} = err ->
        err
    end
  end

  # Convert tools to provider schemas, memoized per run in a runtime-only ctx
  # field. The tool set (and its provider) is stable across loop iterations in
  # the common case, so we re-convert ONLY when the (provider, tool-name set)
  # changes — e.g. a plugin's before_request adds/removes a tool. Returns
  # `{schemas, ctx}` so the caller threads the updated cache forward.
  #
  # The name-set is the staleness guard the design accepts: a plugin swapping a
  # tool for one with the SAME name but a different schema mid-run would not be
  # detected (pathological; tools are otherwise stable structs).
  #
  # NOT applied to: run_stream/3 (single-shot — converts once per call, never
  # reused) or rebuild_settings_for_model/4 (rare fallback path, different
  # provider, no ctx in scope). Both intentionally re-convert.
  def converted_tool_schemas(ctx, provider, all_tools) do
    names = all_tools |> Enum.map(& &1.name) |> MapSet.new()
    key = {provider, names}

    case ctx.tool_schema_cache do
      {^key, schemas} ->
        {schemas, ctx}

      _ ->
        schemas = RequestDispatch.convert_tools_for_provider(provider, all_tools)
        {schemas, %{ctx | tool_schema_cache: {key, schemas}}}
    end
  end

  # ── turn and step bookkeeping ──────────────────────────────────────────────

  # The reasons a live loop may write to `:turn_end`. `:interrupted` is NOT
  # among them and must never be emitted here: `Nous.Session.Recovery` uses it
  # as the unambiguous marker of a turn that never closed because the VM went
  # away mid-run. A live loop emitting it would make a crash indistinguishable
  # from an orderly exit and would silently break recovery's risk
  # classification of lost tool results.
  @live_turn_end_reasons [:complete, :rejected]

  defp open_turn(ctx) do
    {previous_turns, _steps} = turn_cursor(ctx)
    turn = previous_turns + 1

    ctx =
      ctx
      |> clear_exit_reason()
      |> Context.log_event(:turn_start, %{turn: turn})
      |> claim_into(:next_turn)

    {ctx, turn}
  end

  defp close_turn(ctx, turn) do
    {_turn, steps} = turn_cursor(ctx)
    reason = exit_reason(ctx)

    ctx
    |> clear_exit_reason()
    |> Context.log_event(:turn_end, %{turn: turn, steps: steps, reason: reason})
  end

  defp log_step_start(ctx) do
    {turn, steps} = turn_cursor(ctx)
    Context.log_event(ctx, :step_start, %{turn: turn, step: steps + 1})
  end

  defp log_step_end(ctx, outcome) do
    {turn, step} = turn_cursor(ctx)
    Context.log_event(ctx, :step_end, %{turn: turn, step: step, outcome: outcome})
  end

  # `{turns_opened, steps_started_in_the_current_turn}`, read back off the log
  # rather than carried in the context. Two reasons: %Context{} has no field for
  # it and inventing one would put loop bookkeeping into a struct that gets
  # serialized, and a restored session keeps counting where it left off for
  # free. One pass over the events per boundary — noise beside the model request
  # it brackets.
  defp turn_cursor(%Context{log: log}) do
    Enum.reduce(Log.events(log), {0, 0}, fn
      %Event{type: :turn_start}, {turn, _steps} -> {turn + 1, 0}
      %Event{type: :step_start}, {turn, steps} -> {turn, steps + 1}
      _event, acc -> acc
    end)
  end

  # `Hook.Runner.run/3` answers a blocking event with `:deny` OR
  # `{:deny, reason}`; matching only the bare atom let every hook that bothered
  # to explain itself through.
  defp denied?(:deny), do: true
  defp denied?({:deny, _reason}), do: true
  defp denied?(_allowed), do: false

  defp note_rejection(ctx, verdict) do
    if denied?(verdict), do: put_exit_reason(ctx, :rejected), else: ctx
  end

  defp put_exit_reason(%Context{} = ctx, reason) when reason in @live_turn_end_reasons do
    %{ctx | deps: Map.put(ctx.deps, @exit_reason_key, reason)}
  end

  defp exit_reason(%Context{deps: deps}) do
    case Map.get(deps, @exit_reason_key) do
      reason when reason in @live_turn_end_reasons -> reason
      _nothing_owed -> :complete
    end
  end

  defp clear_exit_reason(%Context{} = ctx) do
    %{ctx | deps: Map.delete(ctx.deps, @exit_reason_key)}
  end

  # ── claiming from the inbox ────────────────────────────────────────────────

  defp claim_into(ctx, target), do: ctx |> claim(target) |> elem(0)

  defp claim(%Context{} = ctx, target) do
    case Map.get(ctx.deps, :claim_inbox) do
      claim_fun when is_function(claim_fun, 1) ->
        case safe_claim(claim_fun, target) do
          [] -> {ctx, []}
          messages -> {Context.add_messages(ctx, messages), messages}
        end

      _absent ->
        {ctx, []}
    end
  end

  # The claim crosses a process boundary — the inbox of record lives with the
  # run's owner, not in this task's copy of the context — so it can time out or
  # find that owner gone. Catching every kind is deliberate and not a swallowed
  # error: the reason is logged in full, and killing a live agent run because a
  # steering queue was briefly unreachable is strictly worse than making this
  # one request without the claimed input, which the next boundary picks up
  # anyway. Non-message values are dropped for the same reason — `claim_inbox`
  # is an extension seam, and a badly written one must not crash the run either.
  defp safe_claim(claim_fun, target) do
    case claim_fun.(target) do
      messages when is_list(messages) -> Enum.filter(messages, &match?(%Message{}, &1))
      _other -> []
    end
  catch
    kind, reason ->
      Logger.warning(
        "Nous.AgentRunner: inbox claim for #{inspect(target)} failed " <>
          "(#{inspect(kind)}: #{inspect(reason)}); continuing without claimed input"
      )

      []
  end
end

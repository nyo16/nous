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

  alias Nous.{Errors, Hook, Message, Model, Plugin, Tool}
  alias Nous.Agent
  alias Nous.Agent.{Behaviour, Callbacks, Context}
  alias Nous.AgentRunner.{PromptAssembly, RequestDispatch, ToolExecution}

  require Logger

  # The loop's verdict: the folded context, or the first error that ended the
  # run. Errors are exception structs from this module's own guards and
  # whatever term a provider or behaviour surfaced, so the reason stays open.
  @type loop_result :: {:ok, Context.t()} | {:error, term()}

  @spec execute_loop(Agent.t(), module(), Context.t()) :: loop_result()
  def execute_loop(agent, behaviour, ctx) do
    # Check for cancellation
    case check_cancellation(ctx) do
      {:error, _} = err ->
        err

      :ok ->
        do_iteration(agent, behaviour, ctx)
    end
  end

  @spec check_cancellation(Context.t()) :: :ok | {:error, Errors.ExecutionCancelled.t()}
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

  @spec do_iteration(Agent.t(), module(), Context.t()) :: loop_result()
  def do_iteration(_agent, _behaviour, %{needs_response: false} = ctx), do: {:ok, ctx}

  def do_iteration(agent, behaviour, ctx) do
    if Context.max_iterations_reached?(ctx) do
      Logger.error("""
      Max iterations exceeded
        Agent: #{agent.name}
        Max iterations: #{ctx.max_iterations}
        Total tokens used: #{ctx.usage.total_tokens}
      """)

      error = Errors.MaxIterationsExceeded.exception(max_iterations: ctx.max_iterations)
      {:error, error}
    else
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

      result = do_iteration_body(agent, behaviour, ctx)

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
  end

  @spec do_iteration_body(Agent.t(), module(), Context.t()) :: loop_result()
  def do_iteration_body(agent, behaviour, ctx) do
    {ctx, all_tools, pre_request_result} = prepare_tools(agent, behaviour, ctx)

    # If a plugin (e.g. InputGuard) halted execution or a hook denied, skip the
    # LLM call. `Hook.denied?/1` and not `!= :deny`: a hook returning
    # `{:deny, reason}` used to sail straight through this guard.
    if ctx.needs_response and not Hook.denied?(pre_request_result) do
      {ctx, messages, model_settings} = prepare_request(agent, behaviour, ctx, all_tools)

      Logger.debug(
        "Agent iteration #{ctx.iteration + 1}/#{ctx.max_iterations}: requesting model response"
      )

      case dispatch(agent, ctx, messages, model_settings, all_tools) do
        {:ok, response, active_model} ->
          handle_response(agent, behaviour, ctx, response, active_model, all_tools)

        {:error, reason} ->
          handle_request_error(agent, behaviour, ctx, reason)
      end
    else
      {:ok, ctx}
    end
  end

  # Assemble the tool set the model will see this iteration (behaviour tools +
  # plugin tools, minus anything the permission policy blocks) and run the
  # pre-request hooks. Returns `{ctx, all_tools, pre_request_verdict}`.
  @spec prepare_tools(Agent.t(), module(), Context.t()) ::
          {Context.t(), [Tool.t()], Hook.result()}
  def prepare_tools(agent, behaviour, ctx) do
    # Get tools from behaviour + plugins
    tools = behaviour.get_tools(agent)
    plugin_tools = Plugin.collect_tools(agent.plugins, agent, ctx)
    all_tools = tools ++ plugin_tools

    # Apply plugin system prompt fragments only on first iteration
    ctx =
      if ctx.iteration == 0,
        do: PromptAssembly.apply_plugin_system_prompts(agent, ctx),
        else: ctx

    # Run plugin before_request hooks
    {ctx, all_tools} = Plugin.run_before_request(agent.plugins, agent, ctx, all_tools)

    # Enforce the permission policy: blocked tools are removed from the set the
    # model ever sees (and therefore can't be called). Approval is enforced
    # separately at execution time (see ToolExecution.enforce_policy_approval/2).
    all_tools = ToolExecution.maybe_filter_by_policy(agent.permissions, all_tools)

    # Run pre_request hooks (can block the LLM call)
    pre_request_result =
      Hook.Runner.run(ctx.hook_registry, :pre_request, %{
        agent_name: agent.name,
        tool_count: length(all_tools),
        iteration: ctx.iteration
      })

    {ctx, all_tools, pre_request_result}
  end

  # Build the messages and model settings for this iteration's model call.
  # Returns `{ctx, messages, model_settings}` — ctx is threaded back out because
  # the tool-schema memo lives in it.
  @spec prepare_request(Agent.t(), module(), Context.t(), [Tool.t()]) ::
          {Context.t(), [Message.t()], map()}
  def prepare_request(agent, behaviour, ctx, all_tools) do
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
        {tool_schemas, ctx} = converted_tool_schemas(ctx, agent.model.provider, all_tools)
        {Map.put(agent.model_settings, :tools, tool_schemas), ctx}
      end

    # Inject structured output settings
    model_settings =
      if agent.output_type != :string do
        PromptAssembly.inject_structured_output_settings(agent, model_settings, all_tools)
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

  # Make the model request (with fallback chain if configured).
  #
  # Sticky-fallback: if a previous iteration already promoted to a fallback
  # model (recorded in ctx.deps[:active_model]), call into
  # request_with_fallback with that model first to avoid retrying a known-bad
  # primary on every iteration.
  #
  # Enforce a team RateLimiter when one is wired into deps: reserve before the
  # call, reconcile actual usage after (or release on error). A denied acquire
  # surfaces as a normal {:error, reason} request result.
  @spec dispatch(Agent.t(), Context.t(), [Message.t()], map(), [Tool.t()]) ::
          RequestDispatch.request_result()
  def dispatch(agent, ctx, messages, model_settings, all_tools) do
    request_agent =
      case get_in(ctx.deps, [:active_model]) do
        nil -> agent
        am -> %{agent | model: am}
      end

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
            all_tools
          )
        end
      end
    )
  end

  # Fold a successful model response into the context (usage, callbacks,
  # plugin/hook after-response, behaviour processing, tool calls) and re-enter
  # the loop.
  @spec handle_response(Agent.t(), module(), Context.t(), Message.t(), Model.t(), [Tool.t()]) ::
          loop_result()
  def handle_response(agent, behaviour, ctx, response, active_model, all_tools) do
    # Track active_model in ctx for downstream telemetry / observability,
    # but do NOT mutate agent.model. Mutating made the start-of-run
    # telemetry tag with one provider and the stop with another, with
    # no fallback_used indicator - operational metrics drifted apart
    # for any agent that ever fell back.
    ctx =
      if active_model != agent.model do
        :telemetry.execute(
          [:nous, :agent, :fallback, :used],
          %{system_time: System.system_time()},
          %{
            agent_name: agent.name,
            original_provider: agent.model.provider,
            original_model: agent.model.model,
            active_provider: active_model.provider,
            active_model: active_model.model
          }
        )

        %{ctx | deps: Map.put(ctx.deps, :active_model, active_model)}
      else
        ctx
      end

    # Update usage
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

    # Execute callback
    Callbacks.execute(ctx, :on_llm_new_message, response)

    # Run plugin after_response hooks
    ctx = Plugin.run_after_response(agent.plugins, agent, response, ctx)

    # Run post_response hooks
    Hook.Runner.run(ctx.hook_registry, :post_response, %{
      agent_name: agent.name,
      iteration: ctx.iteration
    })

    # Process response via behaviour - this handles tool calls and updates needs_response
    ctx = behaviour.process_response(agent, response, ctx)

    # Check if we need to handle tool calls (behaviour may have set this up)
    ctx =
      if Message.has_tool_calls?(response) do
        ToolExecution.handle_tool_calls(agent, behaviour, ctx, response, all_tools)
      else
        ctx
      end

    # Continue loop
    execute_loop(agent, behaviour, ctx)
  end

  # A failed model request: give the behaviour's handle_error a chance to retry
  # or continue before surfacing the error.
  @spec handle_request_error(Agent.t(), module(), Context.t(), term()) :: loop_result()
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
        execute_loop(agent, behaviour, new_ctx)

      {:continue, new_ctx} ->
        execute_loop(agent, behaviour, new_ctx)

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
  @spec converted_tool_schemas(Context.t(), Model.provider(), [Tool.t()]) ::
          {[map()], Context.t()}
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
end

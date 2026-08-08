defmodule Nous.AgentRunner do
  @moduledoc """
  Executes agent runs with tool calling loop.

  The AgentRunner is responsible for:
  - Building messages with system prompts and instructions
  - Calling the model via the provider
  - Detecting and executing tool calls
  - Looping until `needs_response` is false
  - Extracting and validating output
  - Executing callbacks and sending process notifications

  ## Context-Based Execution

  The runner uses a `Context` struct to manage all state during execution:

      ctx = Context.new(
        deps: %{database: MyDB},
        callbacks: %{on_llm_new_delta: fn _, d -> IO.write(d) end},
        notify_pid: self()
      )

  ## Behaviour Integration

  Different agent types can customize behavior by implementing
  `Nous.Agent.Behaviour` and setting `behaviour_module` on the agent.
  """

  alias Nous.{
    Agent,
    Hook,
    Message,
    Messages,
    OutputSchema,
    Plugin,
    RunContext,
    Errors
  }

  alias Nous.Agent.{Behaviour, Callbacks, Context}

  alias Nous.AgentRunner.{IterationLoop, PromptAssembly, RequestDispatch, Streaming}

  require Logger

  @max_iterations 10

  @doc """
  Run agent to completion.

  ## Options
    * `:deps` - Dependencies for tools
    * `:message_history` - Previous messages
    * `:usage_limits` - Usage limits (not implemented yet)
    * `:model_settings` - Override model settings
    * `:max_iterations` - Maximum iterations (default: 10)
    * `:cancellation_check` - Function to check if execution should be cancelled.
      Under `stream: true`, also invoked between every streamed chunk; on
      cancellation the consumer aborts cleanly without partial tool execution.
    * `:callbacks` - Map of callback functions
    * `:notify_pid` - PID to receive event messages
    * `:context` - Existing context to continue from
    * `:output_type` - Override the agent's `output_type` for this run
    * `:structured_output` - Override the agent's `structured_output` options for this run
    * `:stream` - When `true`, the LLM call streams chunks while still running
      the tool-call loop (default: `false`). Fires `:on_llm_new_delta` per
      text chunk and `:on_llm_new_thinking_delta` per reasoning chunk.
      `:on_llm_new_message` still fires once per iteration with the assembled
      message, identical in shape to the non-streaming path. Works across all
      providers (OpenAI-compatible, Anthropic, Gemini) and is compatible with
      `output_type` (the synthetic-tool path is honored under streaming).

  """
  @spec run(Agent.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Agent{} = agent, prompt, opts \\ []) do
    agent = apply_runtime_overrides(agent, opts)
    {ctx, behaviour, start_time} = start_run(agent, prompt, opts)
    loop_result = IterationLoop.execute_loop(agent, behaviour, ctx)
    duration = System.monotonic_time() - start_time

    finish_run(agent, behaviour, ctx, loop_result, duration)
  after
    # The run warmed the provider-payload cache in THIS process, as a side
    # effect the caller never asked for (`Nous.Messages.Cache`). Release it
    # instead of retaining a whole converted history until the process happens
    # to convert another one -- `AGENTS.md` documents that process as a
    # long-lived LiveView. `after`, not a trailing call, so a raising tool,
    # provider or callback does not leak it either.
    Messages.Cache.clear()
  end

  @doc """
  Run agent with an existing context.

  Useful for continuing from a previous run or with pre-built context.
  """
  @spec run_with_context(Agent.t(), Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_with_context(%Agent{} = agent, %Context{} = ctx, opts \\ []) do
    agent = apply_runtime_overrides(agent, opts)
    # Merge any additional options into context
    ctx =
      ctx
      |> maybe_update_callbacks(opts)
      |> maybe_update_notify_pid(opts)
      |> maybe_update_stream(opts)
      |> Context.set_needs_response(true)
      |> Context.patch_dangling_tool_calls()

    # Get behaviour module
    behaviour = Behaviour.get_module(agent)

    # Deliberately NOT routed through finish_run/5: that path also emits the
    # run stop/exception telemetry, fires :session_end and invokes the
    # :on_agent_complete / :on_error callbacks, none of which this entry point
    # has ever done. Only the result building is genuinely shared.
    case IterationLoop.execute_loop(agent, behaviour, ctx) do
      {:ok, final_ctx} ->
        extract_context_output(agent, behaviour, final_ctx)

      {:error, _} = err ->
        err
    end
  after
    Messages.Cache.clear()
  end

  @doc """
  Run agent with streaming.

  Returns a stream that yields events as they occur.

  ## Events
    * `{:text_delta, text}` - Incremental text update
    * `{:thinking_delta, text}` - Thinking content (reasoning models)
    * `{:tool_call, call}` - Tool is being called
    * `{:tool_result, result}` - Tool execution completed
    * `{:finish, reason}` - Stream finished
    * `{:complete, result}` - Final result
  """
  @spec run_stream(Agent.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_stream(%Agent{} = agent, prompt, opts \\ []) do
    agent = apply_runtime_overrides(agent, opts)
    ctx = build_context(agent, prompt, opts)
    behaviour = Behaviour.get_module(agent)

    # Streaming runs the SAME preparation pipeline as run/3, via IterationLoop.
    # It used to hand-roll a second copy of prepare_tools/3 + prepare_request/4
    # that never built a hook registry, so the entire hook layer — the
    # :pre_request deny gate included — was a silent no-op on every streamed
    # run, and Behaviour.before_request never fired: an operator's deny/redact
    # hook evaporated purely by switching transport. Do not re-inline this.
    ctx = Plugin.run_init(agent.plugins, agent, ctx)
    ctx = init_hook_registry(agent, ctx)

    # Deliberately NO :session_start / :session_end pair here, unlike run/3.
    # This function returns a LAZY stream: a consumer is free to abandon it
    # (`Enum.take(stream, 5)`), so there is no point at which the session is
    # known to have ended, and emitting only the opening half leaks one open
    # session per streamed run in any hook that pairs them. Firing :session_end
    # from the stream's terminal clause would not fix that, only make it rarer.
    # The hook REGISTRY is what the streaming path was missing, and it is built
    # above; the :pre_request gate below is what depends on it.

    {ctx, all_tools, pre_request_result} = IterationLoop.prepare_tools(agent, behaviour, ctx)

    cond do
      Hook.denied?(pre_request_result) ->
        {:ok, denied_stream(ctx, pre_request_result)}

      not ctx.needs_response ->
        # A plugin (e.g. InputGuard) halted the request before any LLM call.
        # Emit the guard's message as a terminal stream instead of streaming a
        # model response.
        {:ok, blocked_stream(ctx)}

      true ->
        {ctx, messages, model_settings} =
          IterationLoop.prepare_request(agent, behaviour, ctx, all_tools)

        case RequestDispatch.stream_with_fallback(agent, messages, model_settings, all_tools) do
          {:ok, stream} ->
            # Wrap stream to execute callbacks, then accumulate result
            wrapped_stream =
              stream
              |> Streaming.wrap_stream_with_callbacks(ctx)
              |> Streaming.wrap_stream_with_result()

            {:ok, wrapped_stream}

          error ->
            error
        end
    end
  after
    # Unlike the :session_start/:session_end pair above, this IS expressible for
    # a lazy stream: every payload conversion on this path is eager (the request
    # is issued before the stream is handed back, and the wrappers only map
    # events -- there is no per-turn tool loop here), so nothing warms the cache
    # after this point.
    Messages.Cache.clear()
  end

  defp init_hook_registry(%Agent{hooks: []}, ctx), do: ctx

  defp init_hook_registry(%Agent{hooks: hooks}, ctx) do
    %{ctx | hook_registry: Hook.Registry.from_hooks(hooks)}
  end

  # Build a one-shot stream carrying the guard/plugin block message, so callers
  # get the same {:text_delta, _} / {:finish, _} / {:complete, _} event shape
  # they would from a real stream — without ever calling the model.
  defp blocked_stream(ctx) do
    blocked_text =
      case List.last(ctx.messages) do
        %Message{content: content} when is_binary(content) -> content
        _ -> ""
      end

    terminal_stream(ctx, blocked_text)
  end

  # A :pre_request hook denied the call. Surface the hook's own reason rather
  # than the last message, which on a deny is the user's prompt.
  defp denied_stream(ctx, {:deny, reason}) when is_binary(reason),
    do: terminal_stream(ctx, reason)

  defp denied_stream(ctx, _result), do: terminal_stream(ctx, "")

  defp terminal_stream(ctx, text) do
    events =
      if text == "",
        do: [{:finish, "stop"}],
        else: [{:text_delta, text}, {:finish, "stop"}]

    events
    |> Streaming.wrap_stream_with_callbacks(ctx)
    |> Streaming.wrap_stream_with_result()
  end

  # Private functions

  # Everything that must happen before the first model call: start telemetry,
  # context construction, then behaviour / plugin / hook initialization in that
  # order. Returns the start timestamp so the caller can measure the whole run.
  defp start_run(agent, prompt, opts) do
    start_time = System.monotonic_time()

    Logger.info(
      "Starting agent run: #{agent.name} with model #{agent.model.provider}:#{agent.model.model}"
    )

    Logger.debug("Agent has #{length(agent.tools)} tools available")

    :telemetry.execute(
      [:nous, :agent, :run, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        agent_name: agent.name,
        model_provider: agent.model.provider,
        model_name: agent.model.model,
        tool_count: length(agent.tools),
        has_tools: length(agent.tools) > 0
      }
    )

    ctx = build_context(agent, prompt, opts)

    Callbacks.execute(ctx, :on_agent_start, %{agent: agent})

    behaviour = Behaviour.get_module(agent)

    ctx = Behaviour.call(behaviour, :init_context, [agent, ctx], ctx)
    ctx = Plugin.run_init(agent.plugins, agent, ctx)
    ctx = init_hook_registry(agent, ctx)

    Hook.Runner.run(ctx.hook_registry, :session_start, %{agent_name: agent.name})

    {ctx, behaviour, start_time}
  end

  # Turn the loop's outcome into the run's return value. `ctx` is the pre-loop
  # context and is used only when the loop failed outright, in which case no
  # final context exists to report against.
  defp finish_run(agent, behaviour, _ctx, {:ok, final_ctx}, duration) do
    case behaviour.extract_output(agent, final_ctx) do
      {:ok, output} ->
        complete_run(agent, final_ctx, output, duration)

      {:error, %Errors.ValidationError{} = err} ->
        retry_validation_or_fail(agent, behaviour, final_ctx, err, duration)

      {:error, reason} ->
        fail_run(agent, final_ctx, reason, duration)
    end
  end

  defp finish_run(agent, _behaviour, ctx, {:error, error}, duration) do
    fail_run(agent, ctx, error, duration)
  end

  # Output extracted cleanly: build the result (letting plugins amend the
  # context first), fire :session_end, then log/emit/notify.
  #
  # Only the returned result picks up a plugin's context changes; the teardown
  # below deliberately reports `final_ctx`, since usage and iteration counts are
  # the loop's, not a plugin's.
  defp complete_run(agent, final_ctx, output, duration) do
    {agent_result, updated_ctx} = build_result_with_plugins(agent, final_ctx, output)

    Hook.Runner.run(updated_ctx.hook_registry, :session_end, %{
      agent_name: agent.name,
      output: output
    })

    log_run_completion(agent, final_ctx, duration)
    emit_run_stop_telemetry(agent, final_ctx, duration)

    Callbacks.execute(final_ctx, :on_agent_complete, agent_result)

    {:ok, agent_result}
  end

  # Structured output failed validation. A successful retry short-circuits the
  # teardown above: no after_run plugins, no :session_end, no stop telemetry.
  defp retry_validation_or_fail(agent, behaviour, final_ctx, err, duration) do
    max_retries = Keyword.get(agent.structured_output, :max_retries, 0)

    case maybe_retry_validation(agent, behaviour, final_ctx, err, max_retries) do
      {:ok, retry_ctx, output} ->
        agent_result = build_result(agent, retry_ctx, output)
        Callbacks.execute(retry_ctx, :on_agent_complete, agent_result)
        {:ok, agent_result}

      {:error, reason} ->
        fail_run(agent, final_ctx, reason, duration)
    end
  end

  defp fail_run(agent, ctx, reason, duration) do
    emit_error_telemetry(agent, duration, reason)
    Callbacks.execute(ctx, :on_error, reason)
    {:error, reason}
  end

  defp log_run_completion(agent, ctx, duration) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.info("""
    Agent run completed: #{agent.name}
      Duration: #{duration_ms}ms
      Iterations: #{ctx.iteration}
      Tokens: #{ctx.usage.total_tokens} (in: #{ctx.usage.input_tokens}, out: #{ctx.usage.output_tokens})
      Tool calls: #{ctx.usage.tool_calls}
      Requests: #{ctx.usage.requests}
    """)
  end

  defp emit_run_stop_telemetry(agent, ctx, duration) do
    active_model = get_in(ctx.deps, [:active_model]) || agent.model

    :telemetry.execute(
      [:nous, :agent, :run, :stop],
      %{
        duration: duration,
        total_tokens: ctx.usage.total_tokens,
        input_tokens: ctx.usage.input_tokens,
        output_tokens: ctx.usage.output_tokens,
        tool_calls: ctx.usage.tool_calls,
        requests: ctx.usage.requests,
        iterations: ctx.iteration
      },
      %{
        agent_name: agent.name,
        model_provider: agent.model.provider,
        model_name: agent.model.model,
        # When fallback fired, surface BOTH so observability can
        # split metrics by original (intended) and active (used).
        active_model_provider: active_model.provider,
        active_model_name: active_model.model,
        fallback_used: active_model != agent.model
      }
    )
  end

  # Apply per-run overrides for output_type, structured_output and model_settings
  defp apply_runtime_overrides(agent, opts) do
    agent
    |> then(fn a ->
      case Keyword.fetch(opts, :output_type) do
        {:ok, ot} -> %{a | output_type: ot}
        :error -> a
      end
    end)
    |> then(fn a ->
      case Keyword.fetch(opts, :structured_output) do
        {:ok, so} -> %{a | structured_output: so}
        :error -> a
      end
    end)
    |> then(fn a ->
      # :model_settings is documented as a per-run override but was never read.
      # Merge over the agent's settings so callers can tune temperature/max_tokens
      # for a single run.
      case Keyword.fetch(opts, :model_settings) do
        {:ok, ms} when is_map(ms) -> %{a | model_settings: Map.merge(a.model_settings, ms)}
        _ -> a
      end
    end)
  end

  # The result half of run_with_context/3: extract the output the behaviour
  # produced and, when it fails schema validation, spend the configured
  # retries before surfacing the error.
  defp extract_context_output(agent, behaviour, final_ctx) do
    case behaviour.extract_output(agent, final_ctx) do
      {:ok, output} ->
        {agent_result, _updated_ctx} = build_result_with_plugins(agent, final_ctx, output)
        {:ok, agent_result}

      {:error, %Errors.ValidationError{} = err} ->
        max_retries = Keyword.get(agent.structured_output, :max_retries, 0)

        case maybe_retry_validation(agent, behaviour, final_ctx, err, max_retries) do
          {:ok, retry_ctx, output} ->
            {:ok, build_result(agent, retry_ctx, output)}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # The one point where run/3 (via start_run/3) and run_stream/3 both build
  # their context, which is why the dangling-tool-call patch lives here rather
  # than in start_run/3: run_stream/3 accepts `:context` and `:message_history`
  # through this function too, so it carried the identical hazard and skipped
  # the identical fix -- switching transport turned a resumable session into a
  # provider 400. run_with_context/3 is the third entry point and patches on
  # its own behalf, since it never comes through here.
  defp build_context(agent, prompt, opts) do
    ctx =
      case Keyword.get(opts, :context) do
        %Context{} = existing_ctx ->
          # Continue from existing context, add new user message
          existing_ctx
          |> Context.add_message(Message.user(prompt))
          |> Context.set_needs_response(true)
          |> maybe_update_callbacks(opts)
          |> maybe_update_notify_pid(opts)
          |> maybe_update_stream(opts)

        nil ->
          build_fresh_context(agent, prompt, opts)
      end

    # Only bites when continuing from a caller-supplied context or a
    # `:message_history`, either of which can carry an assistant tool call whose
    # result never arrived. Providers reject that history with a 400.
    Context.patch_dangling_tool_calls(ctx)
  end

  # A run that isn't continuing from a caller-supplied context.
  defp build_fresh_context(agent, prompt, opts) do
    message_history = Keyword.get(opts, :message_history, [])
    stream = Keyword.get(opts, :stream, false)

    system_prompt = build_system_prompt(agent, opts)

    # Build initial messages
    messages = build_initial_messages(message_history, prompt, system_prompt)

    Context.new(
      messages: messages,
      system_prompt: system_prompt,
      deps: Keyword.get(opts, :deps, %{}),
      max_iterations: Keyword.get(opts, :max_iterations, @max_iterations),
      callbacks: Keyword.get(opts, :callbacks, %{}),
      notify_pid: Keyword.get(opts, :notify_pid),
      agent_name: agent.name,
      cancellation_check: Keyword.get(opts, :cancellation_check),
      pubsub: Keyword.get(opts, :pubsub),
      pubsub_topic: Keyword.get(opts, :pubsub_topic),
      stream: stream
    )
  end

  # The run's system prompt: the agent's instructions (or its system_prompt),
  # then the todo section, then the structured-output schema instructions. Each
  # stage tolerates a nil prompt — an agent may carry neither instructions nor a
  # system prompt and still want a todo or schema section.
  defp build_system_prompt(agent, opts) do
    base = resolve_prompt(agent.instructions, opts) || resolve_prompt(agent.system_prompt, opts)

    base
    |> maybe_inject_todos(agent, opts)
    |> maybe_append_output_schema_suffix(agent)
  end

  defp maybe_inject_todos(system_prompt, agent, opts) do
    if agent.enable_todos do
      PromptAssembly.inject_todos_into_prompt(system_prompt || "", Keyword.get(opts, :deps, %{}))
    else
      system_prompt
    end
  end

  defp maybe_append_output_schema_suffix(system_prompt, agent) do
    if agent.output_type == :string do
      system_prompt
    else
      mode = output_schema_mode(agent)

      case OutputSchema.system_prompt_suffix(agent.output_type, mode: mode) do
        nil -> system_prompt
        suffix -> (system_prompt || "") <> "\n\n" <> suffix
      end
    end
  end

  # A {:one_of, _} output is always resolved through the synthetic tool call;
  # every other output type honors the configured (or :auto) mode.
  defp output_schema_mode(agent) do
    case agent.output_type do
      {:one_of, _} -> :tool_call
      _ -> Keyword.get(agent.structured_output, :mode, :auto)
    end
  end

  # When continuing from an existing context (the %Context{} branch above),
  # honor the `:stream` opt as an override.
  defp maybe_update_stream(ctx, opts) do
    case Keyword.fetch(opts, :stream) do
      {:ok, value} when is_boolean(value) -> %{ctx | stream: value}
      _ -> ctx
    end
  end

  defp build_initial_messages(history, prompt, system_prompt) do
    system =
      if system_prompt && system_prompt != "", do: [Message.system(system_prompt)], else: []

    system ++ history ++ [Message.user(prompt)]
  end

  defp resolve_prompt(nil, _opts), do: nil
  defp resolve_prompt(prompt, _opts) when is_binary(prompt), do: prompt

  defp resolve_prompt(prompt_fn, opts) when is_function(prompt_fn, 1) do
    ctx = RunContext.new(Keyword.get(opts, :deps, %{}))
    prompt_fn.(ctx)
  end

  # Build the run's result after giving plugins a chance to amend the context.
  # A plugin that changed it gets the result rebuilt from the new one, so the
  # caller never hands back a result describing a stale context. Returns both,
  # because run/3's teardown still reports against the pre-plugin context.
  defp build_result_with_plugins(agent, ctx, output) do
    agent_result = build_result(agent, ctx, output)
    updated_ctx = Plugin.run_after_run(agent.plugins, agent, agent_result, ctx)

    if updated_ctx == ctx,
      do: {agent_result, updated_ctx},
      else: {build_result(agent, updated_ctx, output), updated_ctx}
  end

  defp build_result(_agent, ctx, output) do
    %{
      output: output,
      usage: ctx.usage,
      iterations: ctx.iteration,
      all_messages: ctx.messages,
      new_messages: get_new_messages(ctx),
      deps: ctx.deps,
      # Include context for continuation
      context: ctx
    }
  end

  defp get_new_messages(ctx) do
    # Get messages added during this run (after initial user message)
    # This is a simplification - could be more sophisticated
    ctx.messages
    |> Enum.drop_while(fn msg -> msg.role != :assistant end)
  end

  defp emit_error_telemetry(agent, duration, error) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.error("""
    Agent run failed: #{agent.name}
      Duration: #{duration_ms}ms
      Error: #{inspect(error)}
    """)

    :telemetry.execute(
      [:nous, :agent, :run, :exception],
      %{duration: duration},
      %{
        agent_name: agent.name,
        model_provider: agent.model.provider,
        kind: :error,
        reason: error,
        stacktrace: []
      }
    )
  end

  defp maybe_update_callbacks(ctx, opts) do
    case Keyword.get(opts, :callbacks) do
      nil -> ctx
      callbacks -> %{ctx | callbacks: Map.merge(ctx.callbacks, callbacks)}
    end
  end

  defp maybe_update_notify_pid(ctx, opts) do
    case Keyword.get(opts, :notify_pid) do
      nil -> ctx
      pid -> %{ctx | notify_pid: pid}
    end
  end

  # Validation retry loop
  defp maybe_retry_validation(_agent, _behaviour, _ctx, err, 0) do
    {:error, err}
  end

  defp maybe_retry_validation(agent, behaviour, ctx, err, retries_left) do
    Logger.info(
      "Structured output validation failed, retrying (#{retries_left} retries left): #{OutputSchema.format_errors(err)}"
    )

    # Find the raw response text from the last assistant message
    raw_response =
      ctx.messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :assistant} = msg -> Messages.extract_text(msg)
        _ -> nil
      end)

    # Build retry message
    error_text = OutputSchema.format_errors(err)

    retry_msg =
      Message.user("""
      The response did not pass validation. Your previous response was:

      #{raw_response}

      Please fix these errors and try again:
      #{error_text}

      Respond with valid JSON only.
      """)

    # Add retry message and re-enter loop
    ctx =
      ctx
      |> Context.add_message(retry_msg)
      |> Context.set_needs_response(true)

    case IterationLoop.execute_loop(agent, behaviour, ctx) do
      {:ok, retry_ctx} ->
        case behaviour.extract_output(agent, retry_ctx) do
          {:ok, output} ->
            {:ok, retry_ctx, output}

          {:error, %Errors.ValidationError{} = new_err} ->
            maybe_retry_validation(agent, behaviour, retry_ctx, new_err, retries_left - 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end
end

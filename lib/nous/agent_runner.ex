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
    Fallback,
    Hook,
    Message,
    Messages,
    ModelDispatcher,
    OutputSchema,
    Permissions,
    Plugin,
    RunContext,
    Tool,
    ToolExecutor,
    Errors
  }

  alias Nous.Agent.{Behaviour, Callbacks, Context}
  alias Nous.AgentRunner.{PromptAssembly, Streaming}

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
    start_time = System.monotonic_time()

    Logger.info(
      "Starting agent run: #{agent.name} with model #{agent.model.provider}:#{agent.model.model}"
    )

    Logger.debug("Agent has #{length(agent.tools)} tools available")

    # Emit start event
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

    # Build context from options
    ctx = build_context(agent, prompt, opts)

    # Execute callbacks
    Callbacks.execute(ctx, :on_agent_start, %{agent: agent})

    # Get behaviour module
    behaviour = Behaviour.get_module(agent)

    # Initialize context via behaviour (optional callback)
    ctx = Behaviour.call(behaviour, :init_context, [agent, ctx], ctx)

    # Initialize context via plugins
    ctx = Plugin.run_init(agent.plugins, agent, ctx)

    # Initialize hooks registry
    ctx =
      if agent.hooks != [] do
        %{ctx | hook_registry: Hook.Registry.from_hooks(agent.hooks)}
      else
        ctx
      end

    # Fire session_start hooks
    Hook.Runner.run(ctx.hook_registry, :session_start, %{agent_name: agent.name})

    # Patch dangling tool calls when continuing from existing context
    ctx = Context.patch_dangling_tool_calls(ctx)

    # Execute loop and emit stop/exception
    result = execute_loop(agent, behaviour, ctx)
    duration = System.monotonic_time() - start_time

    case result do
      {:ok, final_ctx} ->
        # Extract output via behaviour
        case behaviour.extract_output(agent, final_ctx) do
          {:ok, output} ->
            agent_result = build_result(agent, final_ctx, output)

            # Run after_run plugin hooks
            updated_ctx = Plugin.run_after_run(agent.plugins, agent, agent_result, final_ctx)

            # Fire session_end hooks
            Hook.Runner.run(updated_ctx.hook_registry, :session_end, %{
              agent_name: agent.name,
              output: output
            })

            agent_result =
              if updated_ctx != final_ctx,
                do: build_result(agent, updated_ctx, output),
                else: agent_result

            duration_ms = System.convert_time_unit(duration, :native, :millisecond)

            Logger.info("""
            Agent run completed: #{agent.name}
              Duration: #{duration_ms}ms
              Iterations: #{final_ctx.iteration}
              Tokens: #{final_ctx.usage.total_tokens} (in: #{final_ctx.usage.input_tokens}, out: #{final_ctx.usage.output_tokens})
              Tool calls: #{final_ctx.usage.tool_calls}
              Requests: #{final_ctx.usage.requests}
            """)

            active_model =
              get_in(final_ctx.deps, [:active_model]) || agent.model

            :telemetry.execute(
              [:nous, :agent, :run, :stop],
              %{
                duration: duration,
                total_tokens: final_ctx.usage.total_tokens,
                input_tokens: final_ctx.usage.input_tokens,
                output_tokens: final_ctx.usage.output_tokens,
                tool_calls: final_ctx.usage.tool_calls,
                requests: final_ctx.usage.requests,
                iterations: final_ctx.iteration
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

            # Execute completion callback
            Callbacks.execute(final_ctx, :on_agent_complete, agent_result)

            {:ok, agent_result}

          {:error, %Errors.ValidationError{} = err} ->
            max_retries = Keyword.get(agent.structured_output, :max_retries, 0)

            case maybe_retry_validation(agent, behaviour, final_ctx, err, max_retries) do
              {:ok, retry_ctx, output} ->
                agent_result = build_result(agent, retry_ctx, output)
                Callbacks.execute(retry_ctx, :on_agent_complete, agent_result)
                {:ok, agent_result}

              {:error, reason} ->
                emit_error_telemetry(agent, duration, reason)
                Callbacks.execute(final_ctx, :on_error, reason)
                {:error, reason}
            end

          {:error, reason} ->
            emit_error_telemetry(agent, duration, reason)
            Callbacks.execute(final_ctx, :on_error, reason)
            {:error, reason}
        end

      {:error, error} ->
        emit_error_telemetry(agent, duration, error)
        Callbacks.execute(ctx, :on_error, error)
        {:error, error}
    end
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

    case execute_loop(agent, behaviour, ctx) do
      {:ok, final_ctx} ->
        case behaviour.extract_output(agent, final_ctx) do
          {:ok, output} ->
            agent_result = build_result(agent, final_ctx, output)
            updated_ctx = Plugin.run_after_run(agent.plugins, agent, agent_result, final_ctx)

            agent_result =
              if updated_ctx != final_ctx,
                do: build_result(agent, updated_ctx, output),
                else: agent_result

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

      {:error, _} = err ->
        err
    end
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
    # Build context
    ctx = build_context(agent, prompt, opts)

    # Get behaviour
    behaviour = Behaviour.get_module(agent)

    # Run the plugin pipeline so input guards / memory / system-prompt plugins
    # apply to streaming too. Previously run_stream skipped this entirely, so an
    # InputGuard configured on the agent silently provided ZERO protection for
    # streamed requests — a security control that varied by transport.
    ctx = Plugin.run_init(agent.plugins, agent, ctx)

    tools = behaviour.get_tools(agent)
    plugin_tools = Plugin.collect_tools(agent.plugins, agent, ctx)
    all_tools = tools ++ plugin_tools

    ctx =
      if ctx.iteration == 0,
        do: PromptAssembly.apply_plugin_system_prompts(agent, ctx),
        else: ctx

    {ctx, all_tools} = Plugin.run_before_request(agent.plugins, agent, ctx, all_tools)
    all_tools = maybe_filter_by_policy(agent.permissions, all_tools)

    if ctx.needs_response do
      # Build messages via behaviour (reflects any plugin context changes)
      messages = behaviour.build_messages(agent, ctx)

      # Add tools to settings if any
      model_settings =
        if Enum.empty?(all_tools) do
          agent.model_settings
        else
          tool_schemas = convert_tools_for_provider(agent.model.provider, all_tools)
          Map.put(agent.model_settings, :tools, tool_schemas)
        end

      # Inject structured output settings for streaming
      model_settings =
        if agent.output_type != :string do
          PromptAssembly.inject_structured_output_settings(agent, model_settings, all_tools)
        else
          model_settings
        end

      # Request stream from model (with fallback chain if configured)
      case stream_with_fallback(agent, messages, model_settings, all_tools) do
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
    else
      # A plugin (e.g. InputGuard) halted the request before any LLM call.
      # Emit the guard's message as a terminal stream instead of streaming a
      # model response.
      {:ok, blocked_stream(ctx)}
    end
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

    events =
      if blocked_text == "",
        do: [{:finish, "stop"}],
        else: [{:text_delta, blocked_text}, {:finish, "stop"}]

    events
    |> Streaming.wrap_stream_with_callbacks(ctx)
    |> Streaming.wrap_stream_with_result()
  end

  # Private functions

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

  defp build_context(agent, prompt, opts) do
    # Check if continuing from existing context
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
        # Build fresh context
        message_history = Keyword.get(opts, :message_history, [])
        stream = Keyword.get(opts, :stream, false)

        # Build system prompt
        system_prompt =
          resolve_prompt(agent.instructions, opts) ||
            resolve_prompt(agent.system_prompt, opts)

        # Handle todo injection if enabled
        system_prompt =
          if agent.enable_todos do
            PromptAssembly.inject_todos_into_prompt(
              system_prompt || "",
              Keyword.get(opts, :deps, %{})
            )
          else
            system_prompt
          end

        # Inject structured output schema instructions
        system_prompt =
          if agent.output_type != :string do
            mode =
              case agent.output_type do
                {:one_of, _} -> :tool_call
                _ -> Keyword.get(agent.structured_output, :mode, :auto)
              end

            suffix = OutputSchema.system_prompt_suffix(agent.output_type, mode: mode)

            if suffix do
              (system_prompt || "") <> "\n\n" <> suffix
            else
              system_prompt
            end
          else
            system_prompt
          end

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

  defp execute_loop(agent, behaviour, ctx) do
    # Check for cancellation
    case check_cancellation(ctx) do
      {:error, _} = err ->
        err

      :ok ->
        do_iteration(agent, behaviour, ctx)
    end
  end

  defp check_cancellation(ctx) do
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

  defp do_iteration(_agent, _behaviour, %{needs_response: false} = ctx), do: {:ok, ctx}

  defp do_iteration(agent, behaviour, ctx) do
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

  defp do_iteration_body(agent, behaviour, ctx) do
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
    # separately at execution time (see enforce_policy_approval/2).
    all_tools = maybe_filter_by_policy(agent.permissions, all_tools)

    # Run pre_request hooks (can block the LLM call)
    pre_request_result =
      Hook.Runner.run(ctx.hook_registry, :pre_request, %{
        agent_name: agent.name,
        tool_count: length(all_tools),
        iteration: ctx.iteration
      })

    # If a plugin (e.g. InputGuard) halted execution or a hook denied, skip the LLM call
    if ctx.needs_response and pre_request_result != :deny do
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

      # Make model request (with fallback chain if configured).
      #
      # Sticky-fallback: if a previous iteration already promoted to a
      # fallback model (recorded in ctx.deps[:active_model]), call into
      # request_with_fallback with that model first to avoid retrying
      # a known-bad primary on every iteration.
      request_agent =
        case get_in(ctx.deps, [:active_model]) do
          nil -> agent
          am -> %{agent | model: am}
        end

      Logger.debug(
        "Agent iteration #{ctx.iteration + 1}/#{ctx.max_iterations}: requesting model response"
      )

      # Enforce a team RateLimiter when one is wired into deps: reserve before
      # the call, reconcile actual usage after (or release on error). A denied
      # acquire surfaces as a normal {:error, reason} request result.
      request_result =
        acquire_and_request(resolve_rate_limiter(ctx), request_agent, messages, fn ->
          if ctx.stream do
            stream_request_with_fallback(
              request_agent,
              messages,
              model_settings,
              all_tools,
              ctx
            )
          else
            request_with_fallback(request_agent, messages, model_settings, all_tools)
          end
        end)

      case request_result do
        {:ok, response, active_model} ->
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
              handle_tool_calls(agent, behaviour, ctx, response, all_tools)
            else
              ctx
            end

          # Continue loop
          execute_loop(agent, behaviour, ctx)

        {:error, reason} ->
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
    else
      {:ok, ctx}
    end
  end

  defp handle_tool_calls(agent, behaviour, ctx, response, tools) do
    # Extract tool calls
    tool_calls = Messages.extract_tool_calls([response])

    if Enum.empty?(tool_calls) do
      ctx
    else
      # Separate synthetic structured output calls from real tool calls
      {_synthetic_calls, real_calls} =
        Enum.split_with(tool_calls, fn call ->
          name = get_tool_field(call, :name)
          OutputSchema.synthetic_tool_name?(name || "")
        end)

      if Enum.empty?(real_calls) do
        # Only synthetic calls — structured output will be extracted by extract_output.
        # Don't execute them as tools; just stop the loop.
        Context.set_needs_response(ctx, false)
      else
        # Update usage to track tool calls
        ctx = Context.add_usage(ctx, %{tool_calls: length(real_calls)})

        tool_names = Enum.map_join(real_calls, ", ", &get_tool_field(&1, :name))
        Logger.debug("Detected #{length(real_calls)} tool call(s): #{tool_names}")

        # Build run context for tool execution
        run_ctx = Context.to_run_context(ctx)

        # Execute all real tool calls and collect results
        {tool_results, ctx} =
          if agent.parallel_tool_calls and length(real_calls) > 1 do
            run_tool_calls_parallel(real_calls, tools, run_ctx, behaviour, agent, ctx)
          else
            run_tool_calls_sequential(real_calls, tools, run_ctx, behaviour, agent, ctx)
          end

        # Add tool result messages
        ctx = Context.add_messages(ctx, tool_results)

        # Record tool calls
        Enum.reduce(real_calls, ctx, fn call, acc ->
          Context.add_tool_call(acc, call)
        end)
      end
    end
  end

  # Sequential tool-call execution (the default): each call runs its full
  # pre/execute/post pipeline before the next call starts, so call N+1's hooks
  # and approval checks observe call N's context effects.
  defp run_tool_calls_sequential(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    {results, ctx} =
      Enum.reduce(real_calls, {[], ctx}, fn call, {results, acc_ctx} ->
        call_name = get_tool_field(call, :name)
        call_id = get_tool_field(call, :id)
        call_arguments = get_tool_field(call, :arguments)

        # Execute callback before tool
        Callbacks.execute(acc_ctx, :on_tool_call, %{
          id: call_id,
          name: call_name,
          arguments: call_arguments
        })

        cleaned_name = clean_tool_name(call_name)

        # Short-circuit on tool_call whose arguments JSON failed to parse.
        # The provider marshalling tagged it with "_invalid_arguments" so
        # we surface a clean tool-error result and let the LLM retry —
        # rather than invoking the tool with bogus/empty args.
        invalid_args = invalid_arguments(call)

        if is_binary(invalid_args) do
          result_msg = invalid_arguments_result(call_id, cleaned_name, invalid_args)
          {[result_msg | results], acc_ctx}
        else
          run_tool_with_hooks(
            call,
            call_id,
            call_name,
            cleaned_name,
            call_arguments,
            tools,
            run_ctx,
            behaviour,
            agent,
            acc_ctx,
            results
          )
        end
      end)

    {Enum.reverse(results), ctx}
  end

  # Parallel tool-call execution (agent.parallel_tool_calls). Three stages keep
  # hook/approval/post-processing semantics sequential while only the approved
  # executions fan out:
  #   (a) pre-stage, in call order: on_tool_call callback, invalid-args
  #       short-circuit, pre_tool_use hook, approval check
  #   (b) approved calls execute concurrently under Nous.TaskSupervisor;
  #       async_stream preserves input order. timeout: :infinity because
  #       ToolExecutor already enforces per-tool timeouts internally — an
  #       outer timeout would double-kill.
  #   (c) post-stage, in original call order: post_tool_use hook,
  #       on_tool_response callback, behaviour :after_tool, merge_deps
  # Tools cannot observe each other's context updates within a turn in either
  # mode (run_ctx is snapshotted before the loop); what changes vs sequential
  # is only the interleaving of external side effects, and that pre-stage
  # hooks see the pre-turn ctx rather than earlier calls' post-stage effects.
  defp run_tool_calls_parallel(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    decisions = Enum.map(real_calls, &pre_stage_decision(&1, tools, agent, ctx))

    approved = for {:execute, call} <- decisions, do: call

    # Key executions by call id rather than relying on positional alignment
    # between `approved` and the async_stream output — robust to reordering and
    # to any future change in how the approved list is built. Provider tool_call
    # ids are unique within one response (they must be, to match tool results),
    # so a map keeps every result.
    executed_by_id =
      Nous.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        approved,
        fn call -> {get_tool_field(call, :id), execute_single_tool(tools, call, run_ctx)} end,
        timeout: :infinity,
        # Carry the input (call) on crash exits so failures keep their
        # attribution and surface as per-call tool errors.
        zip_input_on_exit: true
      )
      |> Map.new(fn
        {:ok, {call_id, {result_msg, context_updates}}} ->
          {call_id, {result_msg, context_updates}}

        {:exit, {call, reason}} ->
          {get_tool_field(call, :id), crashed_tool_result(call, reason)}
      end)

    {results, ctx} =
      Enum.reduce(decisions, {[], ctx}, fn
        {:done, result_msg}, {results, acc_ctx} ->
          {[result_msg | results], acc_ctx}

        {:execute, call}, {results, acc_ctx} ->
          {result_msg, context_updates} = Map.fetch!(executed_by_id, get_tool_field(call, :id))

          {result_msg, acc_ctx} =
            record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx)

          {[result_msg | results], acc_ctx}
      end)

    {Enum.reverse(results), ctx}
  end

  # Pre-execution stage for one call in parallel mode, mirroring the
  # run_tool_with_hooks branches up to (but not including) the execute step.
  # Returns {:done, result_msg} for short-circuits (invalid args, hook denial,
  # approval rejection) or {:execute, call} with final (possibly hook/approval
  # edited) arguments.
  defp pre_stage_decision(call, tools, agent, ctx) do
    call_name = get_tool_field(call, :name)
    call_id = get_tool_field(call, :id)
    call_arguments = get_tool_field(call, :arguments)
    cleaned_name = clean_tool_name(call_name)

    Callbacks.execute(ctx, :on_tool_call, %{
      id: call_id,
      name: call_name,
      arguments: call_arguments
    })

    invalid_args = invalid_arguments(call)

    if is_binary(invalid_args) do
      {:done, invalid_arguments_result(call_id, cleaned_name, invalid_args)}
    else
      hook_payload = %{
        tool_name: cleaned_name,
        tool_id: call_id,
        arguments: call_arguments
      }

      case Hook.Runner.run(ctx.hook_registry, :pre_tool_use, hook_payload) do
        :deny ->
          Logger.info("Tool '#{cleaned_name}' denied by hook")
          {:done, Message.tool(call_id, "Tool call was denied by hook.", name: cleaned_name)}

        {:deny, reason} ->
          Logger.info("Tool '#{cleaned_name}' denied by hook: #{reason}")

          {:done,
           Message.tool(call_id, "Tool call was denied by hook: #{reason}", name: cleaned_name)}

        {:modify, %{arguments: new_args}} ->
          modified_call = put_tool_field(call, :arguments, new_args)
          approval_decision(modified_call, call_id, cleaned_name, tools, agent, ctx)

        _ ->
          approval_decision(call, call_id, cleaned_name, tools, agent, ctx)
      end
    end
  end

  defp approval_decision(call, call_id, cleaned_name, tools, agent, ctx) do
    tool =
      tools
      |> Enum.find(fn t -> t.name == cleaned_name end)
      |> enforce_policy_approval(agent.permissions)

    case check_tool_approval(tool, call, ctx) do
      :reject ->
        Logger.info("Tool '#{cleaned_name}' rejected by approval handler")

        {:done,
         Message.tool(call_id, "Tool call was rejected by approval handler.", name: cleaned_name)}

      {:edit, new_args} ->
        Logger.debug("Tool '#{cleaned_name}' arguments edited by approval handler")
        {:execute, put_tool_field(call, :arguments, new_args)}

      :approve ->
        {:execute, call}
    end
  end

  # A task killed/crashed outside ToolExecutor's own error handling (which
  # already converts in-tool crashes to {:error, _}) becomes a per-call tool
  # error so one dead task never sinks the whole turn.
  defp crashed_tool_result(call, reason) do
    call_id = get_tool_field(call, :id)
    cleaned_name = clean_tool_name(get_tool_field(call, :name))

    Logger.error("Tool '#{cleaned_name}' task exited: #{inspect(reason)}")

    result_msg =
      Message.tool(
        call_id,
        "Tool execution failed: #{cleaned_name} - task exited: #{inspect(reason)}",
        name: cleaned_name
      )

    {result_msg, %{}}
  end

  defp invalid_arguments(call) do
    Map.get(call, "_invalid_arguments") || Map.get(call, :_invalid_arguments)
  end

  defp invalid_arguments_result(call_id, cleaned_name, invalid_args) do
    Logger.warning("Tool '#{cleaned_name}' called with malformed arguments JSON: #{invalid_args}")

    Message.tool(
      call_id,
      "Error: tool arguments were not valid JSON. Please retry with a JSON object.",
      name: cleaned_name
    )
  end

  # Run hooks + execute the tool call, returning the {results, acc_ctx} pair
  # that the outer Enum.reduce expects. Extracted to keep the main loop
  # legible after the invalid-args short-circuit was added.
  defp run_tool_with_hooks(
         call,
         call_id,
         _call_name,
         cleaned_name,
         call_arguments,
         tools,
         run_ctx,
         behaviour,
         agent,
         acc_ctx,
         results
       ) do
    hook_payload = %{
      tool_name: cleaned_name,
      tool_id: call_id,
      arguments: call_arguments
    }

    case Hook.Runner.run(acc_ctx.hook_registry, :pre_tool_use, hook_payload) do
      :deny ->
        Logger.info("Tool '#{cleaned_name}' denied by hook")

        result_msg =
          Message.tool(call_id, "Tool call was denied by hook.", name: cleaned_name)

        {[result_msg | results], acc_ctx}

      {:deny, reason} ->
        Logger.info("Tool '#{cleaned_name}' denied by hook: #{reason}")

        result_msg =
          Message.tool(call_id, "Tool call was denied by hook: #{reason}", name: cleaned_name)

        {[result_msg | results], acc_ctx}

      {:modify, %{arguments: new_args}} ->
        # Hook modified the arguments — continue with modified call.
        # Apply enforce_policy_approval here too (mirroring the :allow branch
        # below): otherwise a tool gated ONLY by the permission policy (strict
        # mode / approval_required / execute-category) would execute UNGATED
        # whenever a pre_tool_use hook modifies arguments, since the bare tool
        # struct's requires_approval flag may be false.
        modified_call = put_tool_field(call, :arguments, new_args)

        tool =
          tools
          |> Enum.find(fn t -> t.name == cleaned_name end)
          |> enforce_policy_approval(agent.permissions)

        case check_tool_approval(tool, modified_call, acc_ctx) do
          :reject ->
            result_msg =
              Message.tool(call_id, "Tool call was rejected by approval handler.",
                name: cleaned_name
              )

            {[result_msg | results], acc_ctx}

          {:edit, edited_args} ->
            edited_call = put_tool_field(modified_call, :arguments, edited_args)

            {result_msg, acc_ctx} =
              execute_and_record_tool(
                tools,
                edited_call,
                run_ctx,
                behaviour,
                agent,
                acc_ctx
              )

            {[result_msg | results], acc_ctx}

          :approve ->
            {result_msg, acc_ctx} =
              execute_and_record_tool(
                tools,
                modified_call,
                run_ctx,
                behaviour,
                agent,
                acc_ctx
              )

            {[result_msg | results], acc_ctx}
        end

      _ ->
        # :allow or other — proceed to approval check
        tool =
          tools
          |> Enum.find(fn t -> t.name == cleaned_name end)
          |> enforce_policy_approval(agent.permissions)

        case check_tool_approval(tool, call, acc_ctx) do
          :reject ->
            Logger.info("Tool '#{cleaned_name}' rejected by approval handler")

            result_msg =
              Message.tool(call_id, "Tool call was rejected by approval handler.",
                name: cleaned_name
              )

            {[result_msg | results], acc_ctx}

          {:edit, new_args} ->
            Logger.debug("Tool '#{cleaned_name}' arguments edited by approval handler")
            edited_call = put_tool_field(call, :arguments, new_args)

            {result_msg, acc_ctx} =
              execute_and_record_tool(
                tools,
                edited_call,
                run_ctx,
                behaviour,
                agent,
                acc_ctx
              )

            {[result_msg | results], acc_ctx}

          :approve ->
            {result_msg, acc_ctx} =
              execute_and_record_tool(tools, call, run_ctx, behaviour, agent, acc_ctx)

            {[result_msg | results], acc_ctx}
        end
    end
  end

  # Execute a tool call and record its result, returning the result message and updated context
  defp execute_and_record_tool(tools, call, run_ctx, behaviour, agent, acc_ctx) do
    {result_msg, context_updates} = execute_single_tool(tools, call, run_ctx)
    record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx)
  end

  # Post-execution stage for one tool call: post_tool_use hook (may modify the
  # result), on_tool_response callback, behaviour :after_tool, merge_deps.
  # Shared by the sequential path (via execute_and_record_tool) and the
  # parallel path, which applies it in original call order after the fan-out.
  defp record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx) do
    call_name = get_tool_field(call, :name)
    call_id = get_tool_field(call, :id)
    call_arguments = get_tool_field(call, :arguments)
    cleaned_name = clean_tool_name(call_name)

    # Run post_tool_use hooks (can modify result)
    result_msg =
      case Hook.Runner.run(acc_ctx.hook_registry, :post_tool_use, %{
             tool_name: cleaned_name,
             tool_id: call_id,
             arguments: call_arguments,
             result: result_msg.content
           }) do
        {:modify, %{result: new_result}} ->
          Message.tool(call_id, new_result, name: cleaned_name)

        _ ->
          result_msg
      end

    Callbacks.execute(acc_ctx, :on_tool_response, %{
      id: call_id,
      name: call_name,
      result: result_msg.content
    })

    acc_ctx =
      Behaviour.call(
        behaviour,
        :after_tool,
        [agent, call, result_msg.content, acc_ctx],
        acc_ctx
      )

    acc_ctx =
      if map_size(context_updates) > 0 do
        Logger.debug("Merging context updates: #{inspect(Map.keys(context_updates))}")
        Context.merge_deps(acc_ctx, context_updates)
      else
        acc_ctx
      end

    {result_msg, acc_ctx}
  end

  defp execute_single_tool(tools, call, run_ctx) do
    alias Nous.Tool.ContextUpdate

    # Clean up tool name - Claude sometimes adds XML-like syntax
    call_name = get_tool_field(call, :name)
    call_id = get_tool_field(call, :id)
    call_arguments = get_tool_field(call, :arguments)
    cleaned_name = clean_tool_name(call_name)

    tool = Enum.find(tools, fn t -> t.name == cleaned_name end)

    {result, context_updates} =
      if tool do
        case ToolExecutor.execute(tool, call_arguments, run_ctx) do
          # New: Handle ContextUpdate return
          {:ok, result, %ContextUpdate{} = update} ->
            Logger.debug("Tool '#{cleaned_name}' executed successfully with context updates")
            updates = context_update_to_map(update)

            if map_size(updates) > 0 do
              Logger.debug(
                "Tool '#{cleaned_name}' returned context updates via ContextUpdate: #{inspect(Map.keys(updates))}"
              )
            end

            {result, updates}

          {:ok, result} ->
            Logger.debug("Tool '#{cleaned_name}' executed successfully")

            # Extract context updates if present (only for map results)
            # This handles the legacy __update_context__ pattern
            {clean_result, updates} =
              if is_map(result) do
                updates = Map.get(result, :__update_context__, %{})

                if map_size(updates) > 0 do
                  Logger.debug(
                    "Tool '#{cleaned_name}' returned context updates: #{inspect(Map.keys(updates))}"
                  )
                end

                # Remove __update_context__ from result before returning to model
                clean_result = Map.delete(result, :__update_context__)

                {clean_result, updates}
              else
                # Non-map results (strings, numbers, etc.) have no context updates
                {result, %{}}
              end

            {clean_result, updates}

          {:error, error} ->
            # Preserve structured error information for better debugging and handling
            error_details = format_tool_error(error, cleaned_name)
            Logger.error("Tool '#{cleaned_name}' execution failed: #{error_details.summary}")
            {error_details.response, %{}}
        end
      else
        available_tools = Enum.map_join(tools, ", ", & &1.name)

        Logger.error("""
        Tool not found: #{call_name}
          Cleaned name: #{cleaned_name}
          Available tools: #{available_tools}
        """)

        error_msg = "Tool not found: #{call_name}"
        {error_msg, %{}}
      end

    {Message.tool(call_id, result, name: cleaned_name), context_updates}
  end

  # Convert ContextUpdate operations to a deps map for merging.
  #
  # `:append` previously did `existing ++ [item]`, which is O(n^2) over many
  # appends to the same key in one update. We prepend instead and reverse each
  # append-built key once at the end. `reversed` tracks keys whose stored list
  # is currently in reverse order; :set/:merge/:delete store forward-order
  # values and reset the flag — so a `:set [list]` then `:append` (the only
  # mixed case) still preserves exact insertion order. Result is byte-identical
  # to the old `++` reduce.
  defp context_update_to_map(%Nous.Tool.ContextUpdate{operations: ops}) do
    {acc, reversed} =
      Enum.reduce(ops, {%{}, MapSet.new()}, fn
        {:set, key, value}, {acc, reversed} ->
          {Map.put(acc, key, value), MapSet.delete(reversed, key)}

        {:merge, key, map}, {acc, reversed} ->
          existing = Map.get(acc, key, %{})
          {Map.put(acc, key, Map.merge(existing, map)), MapSet.delete(reversed, key)}

        {:append, key, item}, {acc, reversed} ->
          if MapSet.member?(reversed, key) do
            {Map.update!(acc, key, &[item | &1]), reversed}
          else
            existing = Map.get(acc, key, [])
            {Map.put(acc, key, [item | Enum.reverse(existing)]), MapSet.put(reversed, key)}
          end

        {:delete, key}, {acc, reversed} ->
          {Map.delete(acc, key), MapSet.delete(reversed, key)}
      end)

    Enum.reduce(reversed, acc, fn key, acc -> Map.update!(acc, key, &Enum.reverse/1) end)
  end

  # Mark a tool as approval-required when the permission policy says so, so the
  # per-tool flag and the policy compose (either one forces the approval gate).
  defp enforce_policy_approval(nil, _policy), do: nil
  defp enforce_policy_approval(%Tool{} = tool, nil), do: tool

  defp enforce_policy_approval(%Tool{requires_approval: true} = tool, _policy), do: tool

  defp enforce_policy_approval(%Tool{} = tool, %Permissions.Policy{} = policy) do
    # Pass the tool's category so an :execute tool keeps its approval gate even
    # under :permissive (unless the policy opts into allow_unattended_execute).
    if Permissions.requires_approval?(policy, tool.name, tool.category) do
      %{tool | requires_approval: true}
    else
      tool
    end
  end

  defp maybe_filter_by_policy(nil, tools), do: tools

  defp maybe_filter_by_policy(%Permissions.Policy{} = policy, tools) do
    Permissions.filter_tools(policy, tools)
  end

  # --- Rate limiting (team agents) ---------------------------------------------

  defp acquire_and_request(nil, _agent, _messages, request_fun), do: request_fun.()

  defp acquire_and_request(pid, agent, messages, request_fun) do
    tokens = estimate_request_tokens(messages)

    case safe_acquire(pid, agent.name, tokens) do
      {:ok, ref} ->
        result = request_fun.()
        record_or_release_rate_limit(pid, agent.name, ref, result)
        result

      {:error, :rate_limiter_unavailable} ->
        # The limiter died between resolution and acquire (or is overloaded and
        # timed out). Fail OPEN — skipping a rate check is far better than
        # crashing the whole agent run on a {:noproc, _}/timeout exit. Surface it
        # though: a silent fail-open would let a dead limiter allow unlimited
        # traffic with no signal until cost/token metrics spiked.
        Logger.warning(
          "RateLimiter unavailable for agent #{inspect(agent.name)}; failing open (request not rate-limited)"
        )

        :telemetry.execute([:nous, :rate_limiter, :unavailable], %{count: 1}, %{
          agent: agent.name
        })

        request_fun.()

      {:error, _reason} = err ->
        err
    end
  end

  # The resolved limiter pid can die before/while we call it (TOCTOU). Catch the
  # exit instead of leaking a {:noproc, _}/timeout into the agent loop.
  defp safe_acquire(pid, name, tokens) do
    Nous.Teams.RateLimiter.acquire(pid, name, tokens)
  catch
    :exit, _ -> {:error, :rate_limiter_unavailable}
  end

  defp record_or_release_rate_limit(pid, name, ref, {:ok, response, _model}) do
    usage = (response.metadata && response.metadata.usage) || %{}
    tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    Nous.Teams.RateLimiter.record_usage(pid, name, %{tokens: tokens, cost: 0.0, reservation: ref})
  end

  defp record_or_release_rate_limit(pid, _name, ref, _other) do
    Nous.Teams.RateLimiter.release(pid, ref)
  end

  defp resolve_rate_limiter(ctx) do
    resolve_alive_process(ctx.deps[:rate_limiter_pid])
  end

  # No Process.alive?/1 pre-check: it only narrows — never closes — the race
  # before acquire, and a stale `true` is indistinguishable from a live pid. The
  # authoritative guard is safe_acquire/3, which catches the exit if the pid is
  # already dead. Here we just resolve a name to its currently-registered pid.
  defp resolve_alive_process(pid) when is_pid(pid), do: pid

  defp resolve_alive_process(name) when is_atom(name) and not is_nil(name) do
    GenServer.whereis(name)
  end

  defp resolve_alive_process(_), do: nil

  # Rough input-token estimate (≈4 chars/token) for the pre-call reservation;
  # reconciled to actual usage by record_usage after the response.
  defp estimate_request_tokens(messages) do
    chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        # Only binary content contributes to the rough estimate; a message with
        # nil content (tool-call-only) or list content (multimodal) is skipped
        # rather than crashing Message.extract_text/1 (no nil clause).
        text = if is_binary(msg.content), do: msg.content, else: ""
        acc + byte_size(text)
      end)

    max(div(chars, 4), 1)
  end

  # Check if a tool call requires approval and invoke the handler.
  #
  # Default-deny: a tool with `requires_approval: true` but no
  # `ctx.approval_handler` is REJECTED, not approved. The previous behaviour
  # auto-approved in this case, which made the requires_approval flag a
  # silent no-op for the default Agent setup - one prompt-injected document
  # away from RCE on tools like Bash/FileWrite.
  defp check_tool_approval(nil, _call, _ctx), do: :approve

  defp check_tool_approval(%Tool{requires_approval: true} = tool, call, %Context{
         approval_handler: handler
       })
       when is_function(handler) do
    tool_call_info = %{
      name: get_tool_field(call, :name),
      id: get_tool_field(call, :id),
      arguments: get_tool_field(call, :arguments),
      tool: tool
    }

    case handler.(tool_call_info) do
      :approve -> :approve
      :reject -> :reject
      {:edit, new_args} when is_map(new_args) -> {:edit, new_args}
      _ -> :reject
    end
  end

  defp check_tool_approval(%Tool{requires_approval: true} = tool, call, _ctx) do
    Logger.warning(
      "Tool '#{tool.name}' has requires_approval: true but no :approval_handler is configured " <>
        "in ctx. Rejecting call (id=#{inspect(get_tool_field(call, :id))}). " <>
        "Wire an approval_handler to allow these tools."
    )

    :reject
  end

  defp check_tool_approval(_tool, _call, _ctx), do: :approve

  # Tool call fields arrive with atom OR string keys depending on the
  # provider; Nous.ToolCall resolves both without coalescing falsy values.
  defp get_tool_field(call, field), do: Nous.ToolCall.field(call, field)

  defp put_tool_field(call, field, value), do: Nous.ToolCall.put_field(call, field, value)

  # Clean tool names - Claude sometimes uses XML-like syntax.
  # L-9: tolerate nil/non-binary input - some providers emit malformed
  # function-call responses with no name; without these clauses
  # clean_tool_name/1 would crash the entire agent run with FunctionClauseError.
  defp clean_tool_name(nil), do: ""
  defp clean_tool_name(name) when not is_binary(name), do: ""

  defp clean_tool_name(name) when is_binary(name) do
    name
    |> String.split("\"")
    |> List.first()
    |> String.trim()
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
  defp converted_tool_schemas(ctx, provider, all_tools) do
    names = all_tools |> Enum.map(& &1.name) |> MapSet.new()
    key = {provider, names}

    case ctx.tool_schema_cache do
      {^key, schemas} ->
        {schemas, ctx}

      _ ->
        schemas = convert_tools_for_provider(provider, all_tools)
        {schemas, %{ctx | tool_schema_cache: {key, schemas}}}
    end
  end

  # Convert tools to provider-specific format
  defp convert_tools_for_provider(:anthropic, tools) do
    # Anthropic uses atom keys and different format
    Enum.map(tools, &Nous.ToolSchema.to_anthropic/1)
  end

  defp convert_tools_for_provider(_, tools) do
    # OpenAI-compatible providers use string keys
    Enum.map(tools, &Tool.to_openai_schema/1)
  end

  # Format tool errors to preserve structured information while providing LLM-friendly response
  @spec format_tool_error(term(), String.t()) :: %{summary: String.t(), response: String.t()}
  defp format_tool_error(error, tool_name) do
    case error do
      %Nous.Errors.ToolError{} = tool_error ->
        # Extract structured information from ToolError
        summary = Exception.message(tool_error)

        # Create detailed response for LLM that includes context
        response =
          """
          Tool execution failed: #{tool_name}
          Error: #{tool_error.message}
          Attempts: #{tool_error.attempt || 1}
          #{if tool_error.original_error, do: "Original cause: #{inspect(tool_error.original_error)}", else: ""}

          Please try a different approach or tool if available.
          """
          |> String.trim()

        %{summary: summary, response: response}

      error when is_exception(error) ->
        summary = Exception.message(error)
        response = "Tool execution failed: #{tool_name} - #{summary}"
        %{summary: summary, response: response}

      error ->
        summary = "Tool execution failed with: #{inspect(error)}"
        response = "Tool execution failed: #{tool_name} - #{summary}"
        %{summary: summary, response: response}
    end
  end

  # Request with fallback chain support.
  # When fallback models are configured, tries each model in order on eligible errors.
  # Returns {:ok, response, active_model} or {:error, reason}.
  defp request_with_fallback(agent, messages, model_settings, all_tools) do
    model_chain = Fallback.build_model_chain(agent.model, agent.fallback)

    Fallback.with_fallback(model_chain, fn model ->
      # Re-convert tool schemas if provider changed
      settings = rebuild_settings_for_model(model, model_settings, all_tools, agent)

      case get_dispatcher().request(model, messages, settings) do
        {:ok, response} -> {:ok, {response, model}}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, {response, active_model}} -> {:ok, response, active_model}
      {:error, _} = err -> err
    end
  end

  # Stream with fallback chain support.
  # Only retries stream initialization, not mid-stream failures.
  defp stream_with_fallback(agent, messages, model_settings, tools) do
    model_chain = Fallback.build_model_chain(agent.model, agent.fallback)

    Fallback.with_fallback(model_chain, fn model ->
      settings = rebuild_settings_for_model(model, model_settings, tools, agent)
      get_dispatcher().request_stream(model, messages, settings)
    end)
  end

  # Streaming counterpart to request_with_fallback/4. Initializes the stream
  # via stream_with_fallback/4 (so initialization errors trigger fallback),
  # then consumes the stream eagerly into a %Nous.Message{} structurally
  # identical to what request_with_fallback/4 returns. Per-chunk delta
  # callbacks fire from the consumer, and the assembled message flows back
  # into the same do_iteration code path that handles tool calls and the
  # next iteration.
  #
  # Returns {:ok, response, active_model} or {:error, reason}.
  @openai_compat_providers ~w(openai custom vllm sglang lmstudio llamacpp)a

  defp stream_request_with_fallback(agent, messages, model_settings, all_tools, ctx) do
    model_chain = Fallback.build_model_chain(agent.model, agent.fallback)

    Fallback.with_fallback(model_chain, fn model ->
      settings =
        model
        |> rebuild_settings_for_model(model_settings, all_tools, agent)
        |> maybe_inject_include_usage(model.provider)

      with {:ok, stream} <- get_dispatcher().request_stream(model, messages, settings),
           {:ok, message} <- Streaming.consume_stream_into_message(stream, ctx, model.provider) do
        {:ok, {message, model}}
      end
    end)
    |> case do
      {:ok, {response, active_model}} -> {:ok, response, active_model}
      {:error, _} = err -> err
    end
  end

  defp maybe_inject_include_usage(settings, provider)
       when provider in @openai_compat_providers do
    current = Map.get(settings, :stream_options) || %{}
    Map.put(settings, :stream_options, Map.put(current, :include_usage, true))
  end

  defp maybe_inject_include_usage(settings, _provider), do: settings

  # Rebuild model settings when falling back to a different provider.
  # Tool schemas must be re-converted for the target provider's format.
  defp rebuild_settings_for_model(model, model_settings, all_tools, agent) do
    if model.provider == agent.model.provider do
      model_settings
    else
      # Strip existing tool schemas and re-convert for the new provider
      base_settings =
        model_settings
        |> Map.delete(:tools)
        |> Map.delete(:tool_choice)
        |> Map.delete(:response_format)

      settings =
        if Enum.empty?(all_tools) do
          base_settings
        else
          tool_schemas = convert_tools_for_provider(model.provider, all_tools)
          Map.put(base_settings, :tools, tool_schemas)
        end

      # Re-inject structured output settings for the new provider if needed
      if agent.output_type != :string do
        # Use a temporary agent with the fallback model so provider-specific settings are correct
        PromptAssembly.inject_structured_output_settings(
          %{agent | model: model},
          settings,
          all_tools
        )
      else
        settings
      end
    end
  end

  # Get the model dispatcher, allowing dependency injection for testing
  defp get_dispatcher do
    Application.get_env(:nous, :model_dispatcher, ModelDispatcher)
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

    case execute_loop(agent, behaviour, ctx) do
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

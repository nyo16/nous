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
  alias Nous.AgentRunner.{PromptAssembly, RequestDispatch, Streaming, ToolExecution}

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
    all_tools = ToolExecution.maybe_filter_by_policy(agent.permissions, all_tools)

    if ctx.needs_response do
      # Build messages via behaviour (reflects any plugin context changes)
      messages = behaviour.build_messages(agent, ctx)

      # Add tools to settings if any
      model_settings =
        if Enum.empty?(all_tools) do
          agent.model_settings
        else
          tool_schemas =
            RequestDispatch.convert_tools_for_provider(agent.model.provider, all_tools)

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
    # separately at execution time (see ToolExecution.enforce_policy_approval/2).
    all_tools = ToolExecution.maybe_filter_by_policy(agent.permissions, all_tools)

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
              ToolExecution.handle_tool_calls(agent, behaviour, ctx, response, all_tools)
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
        schemas = RequestDispatch.convert_tools_for_provider(provider, all_tools)
        {schemas, %{ctx | tool_schema_cache: {key, schemas}}}
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

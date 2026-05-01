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
    Plugin,
    RunContext,
    Tool,
    ToolExecutor,
    Errors
  }

  alias Nous.Agent.{Behaviour, Callbacks, Context}

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

    # Get behaviour and tools
    behaviour = Behaviour.get_module(agent)
    tools = behaviour.get_tools(agent)

    # Build messages
    messages = behaviour.build_messages(agent, ctx)

    # Add tools to settings if any
    model_settings =
      if Enum.empty?(tools) do
        agent.model_settings
      else
        tool_schemas = convert_tools_for_provider(agent.model.provider, tools)
        Map.put(agent.model_settings, :tools, tool_schemas)
      end

    # Inject structured output settings for streaming
    model_settings =
      if agent.output_type != :string do
        inject_structured_output_settings(agent, model_settings, tools)
      else
        model_settings
      end

    # Request stream from model (with fallback chain if configured)
    case stream_with_fallback(agent, messages, model_settings, tools) do
      {:ok, stream} ->
        # Wrap stream to execute callbacks, then accumulate result
        wrapped_stream =
          stream
          |> wrap_stream_with_callbacks(ctx)
          |> wrap_stream_with_result()

        {:ok, wrapped_stream}

      error ->
        error
    end
  end

  # Private functions

  # Apply per-run overrides for output_type and structured_output
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
            inject_todos_into_prompt(system_prompt || "", Keyword.get(opts, :deps, %{}))
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
      # Get tools from behaviour + plugins
      tools = behaviour.get_tools(agent)
      plugin_tools = Plugin.collect_tools(agent.plugins, agent, ctx)
      all_tools = tools ++ plugin_tools

      # Apply plugin system prompt fragments only on first iteration
      ctx = if ctx.iteration == 0, do: apply_plugin_system_prompts(agent, ctx), else: ctx

      # Run plugin before_request hooks
      {ctx, all_tools} = Plugin.run_before_request(agent.plugins, agent, ctx, all_tools)

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

        # Add tools to model settings if any
        model_settings =
          if Enum.empty?(all_tools) do
            agent.model_settings
          else
            Logger.debug(
              "Converting #{length(all_tools)} tools for provider: #{agent.model.provider}"
            )

            tool_schemas = convert_tools_for_provider(agent.model.provider, all_tools)
            Map.put(agent.model_settings, :tools, tool_schemas)
          end

        # Inject structured output settings
        model_settings =
          if agent.output_type != :string do
            inject_structured_output_settings(agent, model_settings, all_tools)
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

        request_result =
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

            # Run pre_tool_use hooks first (can block or modify args)
            hook_payload = %{
              tool_name: cleaned_name,
              tool_id: call_id,
              arguments: call_arguments
            }

            case Hook.Runner.run(acc_ctx.hook_registry, :pre_tool_use, hook_payload) do
              :deny ->
                Logger.info("Tool '#{cleaned_name}' denied by hook")
                result_msg = Message.tool(call_id, "Tool call was denied by hook.")
                {[result_msg | results], acc_ctx}

              {:deny, reason} ->
                Logger.info("Tool '#{cleaned_name}' denied by hook: #{reason}")
                result_msg = Message.tool(call_id, "Tool call was denied by hook: #{reason}")
                {[result_msg | results], acc_ctx}

              {:modify, %{arguments: new_args}} ->
                # Hook modified the arguments — continue with modified call
                modified_call = put_tool_field(call, :arguments, new_args)
                tool = Enum.find(tools, fn t -> t.name == cleaned_name end)

                case check_tool_approval(tool, modified_call, acc_ctx) do
                  :reject ->
                    result_msg =
                      Message.tool(call_id, "Tool call was rejected by approval handler.")

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
                tool = Enum.find(tools, fn t -> t.name == cleaned_name end)

                case check_tool_approval(tool, call, acc_ctx) do
                  :reject ->
                    Logger.info("Tool '#{cleaned_name}' rejected by approval handler")

                    result_msg =
                      Message.tool(call_id, "Tool call was rejected by approval handler.")

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
          end)

        # Add tool result messages
        tool_results = Enum.reverse(tool_results)
        ctx = Context.add_messages(ctx, tool_results)

        # Record tool calls
        Enum.reduce(real_calls, ctx, fn call, acc ->
          Context.add_tool_call(acc, call)
        end)
      end
    end
  end

  # Execute a tool call and record its result, returning the result message and updated context
  defp execute_and_record_tool(tools, call, run_ctx, behaviour, agent, acc_ctx) do
    call_name = get_tool_field(call, :name)
    call_id = get_tool_field(call, :id)
    call_arguments = get_tool_field(call, :arguments)
    cleaned_name = clean_tool_name(call_name)
    {result_msg, context_updates} = execute_single_tool(tools, call, run_ctx)

    # Run post_tool_use hooks (can modify result)
    result_msg =
      case Hook.Runner.run(acc_ctx.hook_registry, :post_tool_use, %{
             tool_name: cleaned_name,
             tool_id: call_id,
             arguments: call_arguments,
             result: result_msg.content
           }) do
        {:modify, %{result: new_result}} ->
          Message.tool(call_id, new_result)

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

    {Message.tool(call_id, result), context_updates}
  end

  # Apply plugin system prompt fragments to context
  # Only applied once per iteration (on first iteration, or when system prompt needs updating)
  defp apply_plugin_system_prompts(agent, ctx) do
    case Plugin.collect_system_prompts(agent.plugins, agent, ctx) do
      nil ->
        ctx

      plugin_prompt ->
        # Update the system message if it exists, otherwise inject one
        updated_messages =
          case ctx.messages do
            [%Message{role: :system} = sys | rest] ->
              updated_content = sys.content <> "\n\n" <> plugin_prompt
              [%{sys | content: updated_content} | rest]

            messages ->
              [Message.system(plugin_prompt) | messages]
          end

        %{ctx | messages: updated_messages}
    end
  end

  # Convert ContextUpdate operations to a deps map for merging
  defp context_update_to_map(%Nous.Tool.ContextUpdate{operations: ops}) do
    Enum.reduce(ops, %{}, fn
      {:set, key, value}, acc ->
        Map.put(acc, key, value)

      {:merge, key, map}, acc ->
        existing = Map.get(acc, key, %{})
        Map.put(acc, key, Map.merge(existing, map))

      {:append, key, item}, acc ->
        existing = Map.get(acc, key, [])
        Map.put(acc, key, existing ++ [item])

      {:delete, key}, acc ->
        Map.delete(acc, key)
    end)
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

  # Get tool call field - handles both atom and string keys
  # OpenAI-compatible APIs return string keys, our internal format uses atoms
  defp get_tool_field(call, field) when is_atom(field) do
    Map.get(call, field) || Map.get(call, to_string(field))
  end

  # Set tool call field - handles both atom and string keys
  defp put_tool_field(call, field, value) when is_atom(field) do
    if Map.has_key?(call, field) do
      Map.put(call, field, value)
    else
      Map.put(call, to_string(field), value)
    end
  end

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

  defp wrap_stream_with_callbacks(stream, ctx) do
    Stream.map(stream, fn event ->
      case event do
        {:text_delta, text} ->
          Callbacks.execute(ctx, :on_llm_new_delta, text)

        {:thinking_delta, text} ->
          Callbacks.execute(ctx, :on_llm_new_delta, "[thinking] #{text}")

        {:tool_call_delta, calls} when is_list(calls) ->
          Enum.each(calls, fn call ->
            Callbacks.execute(ctx, :on_tool_call, call)
          end)

        # M-5: Anthropic streaming emits tool_use fragments tagged with
        # `_phase :start | :partial | :stop` and an `_index`. We don't
        # reassemble them here per-event because the on_tool_call callback
        # sees fragments by design (it's a streaming hook); the
        # post-stream complete-response path is what builds the final
        # tool_calls list, and Anthropic's convert_complete_response
        # handles that correctly.
        {:tool_call_delta, %{"_phase" => _} = _partial} ->
          :ok

        {:tool_call_delta, call} ->
          Callbacks.execute(ctx, :on_tool_call, call)

        _ ->
          :ok
      end

      event
    end)
  end

  # Wraps a stream to accumulate text/thinking content and emit a
  # {:complete, result} event after {:finish, reason}.
  # If the stream ends without {:finish}, emits {:complete} anyway.
  # This gives consumers a final aggregated result similar to run/3.
  #
  # Uses iodata accumulation (list of chunks) for O(n) performance,
  # converting to binary only once at the end.
  defp wrap_stream_with_result(stream) do
    # Use a unique ref as sentinel — cannot collide with provider events
    sentinel = make_ref()

    stream
    |> Stream.concat([sentinel])
    |> Stream.transform(
      %{text: [], thinking: [], completed: false, sentinel: sentinel},
      fn
        {:text_delta, text} = event, acc ->
          {[event], %{acc | text: [acc.text | text]}}

        {:thinking_delta, text} = event, acc ->
          {[event], %{acc | thinking: [acc.thinking | text]}}

        {:finish, reason} = event, acc ->
          result = build_stream_result(acc, reason)
          {[event, {:complete, result}], %{acc | text: [], thinking: [], completed: true}}

        event, %{completed: true, sentinel: sentinel} = acc when event == sentinel ->
          # Already emitted :complete via {:finish}, nothing to do
          {[], acc}

        event, %{sentinel: sentinel} = acc when event == sentinel ->
          # Stream ended without {:finish} — emit :complete with accumulated data
          result = build_stream_result(acc, "stop")

          if acc.text == [] and acc.thinking == [] do
            # Completely empty stream — likely a provider issue (e.g. minimax)
            Logger.warning(
              "Stream ended with no events — possible provider issue (empty response)"
            )

            {[{:error, :empty_stream}, {:complete, result}], %{acc | completed: true}}
          else
            {[{:complete, result}], %{acc | completed: true}}
          end

        event, acc ->
          {[event], acc}
      end
    )
  end

  defp build_stream_result(acc, reason) do
    result = %{
      output: IO.iodata_to_binary(acc.text),
      finish_reason: reason
    }

    thinking = IO.iodata_to_binary(acc.thinking)

    if thinking != "",
      do: Map.put(result, :thinking, thinking),
      else: result
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

  # Inject todos into system prompt
  defp inject_todos_into_prompt(instructions, deps) do
    todos = deps[:todos] || []

    if todos == [] do
      Logger.debug("No todos to inject into system prompt")
      instructions
    else
      in_progress = Enum.count(todos, &(&1.status == "in_progress"))
      pending = Enum.count(todos, &(&1.status == "pending"))
      completed = Enum.count(todos, &(&1.status == "completed"))

      Logger.debug(
        "Injecting #{length(todos)} todos into system prompt (in_progress: #{in_progress}, pending: #{pending}, completed: #{completed})"
      )

      todo_section = format_todos_for_prompt(todos)

      """
      #{instructions}

      ## Current Task Progress

      #{todo_section}

      You have access to todo management tools:
      - add_todo(text, status?, priority?) - Create new task
      - update_todo(id, text?, status?, priority?) - Update existing task
      - complete_todo(id) - Mark task as completed
      - list_todos(status?, priority?) - List all tasks

      Use these tools to track your progress and stay organized.
      """
    end
  end

  defp format_todos_for_prompt(todos) do
    grouped = Enum.group_by(todos, & &1.status)

    section_defs = [
      {"in_progress", "In Progress",
       fn todo ->
         "  #{priority_icon(todo.priority)} [#{todo.id}] #{todo.text}"
       end},
      {"pending", "Pending",
       fn todo ->
         "  #{priority_icon(todo.priority)} [#{todo.id}] #{todo.text}"
       end},
      {"completed", "Completed",
       fn todo ->
         "  * [#{todo.id}] #{todo.text}"
       end}
    ]

    sections =
      Enum.flat_map(section_defs, fn {status, label, formatter} ->
        case Map.get(grouped, status, []) do
          [] ->
            []

          items ->
            list = Enum.map_join(items, "\n", formatter)
            ["\n#{label} (#{length(items)}):\n#{list}"]
        end
      end)

    case sections do
      [] -> "No tasks yet. Use add_todo() to create tasks."
      _ -> Enum.join(sections, "\n")
    end
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

  defp priority_icon("high"), do: "[HIGH]"
  defp priority_icon("medium"), do: "[MED]"
  defp priority_icon("low"), do: "[LOW]"
  defp priority_icon(_), do: "-"

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
           {:ok, message} <- consume_stream_into_message(stream, ctx, model.provider) do
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

  # Consume a normalized stream into a single %Nous.Message{}, firing
  # per-chunk delta callbacks along the way. Halts cleanly with
  # ExecutionCancelled if `ctx.cancellation_check` raises {:cancelled, reason}
  # between chunks.
  defp consume_stream_into_message(stream, ctx, provider) do
    initial = %{
      text: [],
      reasoning: [],
      tool_acc: Nous.StreamNormalizer.ToolCallAccumulator.new(),
      usage: nil,
      finish_reason: "stop",
      error: nil,
      cancelled: nil
    }

    final =
      Enum.reduce_while(stream, initial, fn event, acc ->
        case check_cancellation_inline(ctx) do
          {:cancelled, reason} ->
            {:halt, %{acc | cancelled: reason}}

          :ok ->
            {:cont, handle_stream_event(event, acc, ctx)}
        end
      end)

    cond do
      final.cancelled ->
        {:error, Errors.ExecutionCancelled.exception(reason: final.cancelled)}

      final.error ->
        {:error, final.error}

      true ->
        {:ok, build_streamed_message(final, provider)}
    end
  end

  defp handle_stream_event({:text_delta, text}, acc, ctx) do
    Callbacks.execute(ctx, :on_llm_new_delta, text)
    %{acc | text: [acc.text, text]}
  end

  defp handle_stream_event({:thinking_delta, text}, acc, ctx) do
    Callbacks.execute(ctx, :on_llm_new_thinking_delta, text)
    %{acc | reasoning: [acc.reasoning, text]}
  end

  defp handle_stream_event({:tool_call_delta, fragment}, acc, _ctx) do
    %{acc | tool_acc: Nous.StreamNormalizer.ToolCallAccumulator.feed(acc.tool_acc, fragment)}
  end

  defp handle_stream_event({:usage, usage}, acc, _ctx) do
    %{acc | usage: usage}
  end

  defp handle_stream_event({:finish, reason}, acc, _ctx) do
    %{acc | finish_reason: reason}
  end

  defp handle_stream_event({:error, reason}, acc, _ctx) do
    %{acc | error: reason}
  end

  defp handle_stream_event(_other, acc, _ctx), do: acc

  defp build_streamed_message(acc, _provider) do
    text = IO.iodata_to_binary(acc.text)
    reasoning = IO.iodata_to_binary(acc.reasoning)
    tool_calls = Nous.StreamNormalizer.ToolCallAccumulator.finalize(acc.tool_acc)

    attrs = %{
      role: :assistant,
      metadata: %{
        usage: acc.usage || %Nous.Usage{},
        finish_reason: acc.finish_reason,
        timestamp: DateTime.utc_now()
      }
    }

    attrs = if text != "", do: Map.put(attrs, :content, text), else: attrs

    attrs =
      if reasoning != "",
        do: Map.put(attrs, :reasoning_content, reasoning),
        else: attrs

    attrs =
      if tool_calls != [],
        do: Map.put(attrs, :tool_calls, tool_calls),
        else: attrs

    Message.new!(attrs)
  end

  # Inline cancellation probe used between streamed chunks. Mirrors
  # check_cancellation/1 but returns a value instead of an {:error, _}
  # tuple so the reduce can decide between :halt and :cont.
  defp check_cancellation_inline(%{cancellation_check: nil}), do: :ok

  defp check_cancellation_inline(%{cancellation_check: check}) when is_function(check, 0) do
    try do
      check.()
      :ok
    catch
      {:cancelled, reason} -> {:cancelled, reason}
    end
  end

  defp check_cancellation_inline(_), do: :ok

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
        inject_structured_output_settings(%{agent | model: model}, settings, all_tools)
      else
        settings
      end
    end
  end

  # Get the model dispatcher, allowing dependency injection for testing
  defp get_dispatcher do
    Application.get_env(:nous, :model_dispatcher, ModelDispatcher)
  end

  # --- Structured Output Helpers ---

  # Inject structured output settings into model_settings
  defp inject_structured_output_settings(agent, model_settings, all_tools) do
    mode = Keyword.get(agent.structured_output, :mode, :auto)

    so_settings =
      OutputSchema.to_provider_settings(
        agent.output_type,
        agent.model.provider,
        mode: mode,
        has_other_tools: not Enum.empty?(all_tools)
      )

    merge_structured_output_settings(model_settings, so_settings, agent.model.provider)
  end

  # Merge structured output settings into model_settings
  defp merge_structured_output_settings(model_settings, so_settings, provider) do
    # Handle synthetic tool injection separately
    {tool_settings, other_settings} =
      Map.split(so_settings, [
        :__structured_output_tool__,
        :__structured_output_tools__,
        :__structured_output_tool_choice__
      ])

    # Merge non-tool settings
    merged = Map.merge(model_settings, other_settings)

    # Inject synthetic tool(s) into existing tools list
    case tool_settings do
      # Plural: multiple synthetic tools ({:one_of, schemas})
      %{__structured_output_tools__: tools_list} when is_list(tools_list) ->
        existing_tools = merged[:tools] || []

        formatted_tools =
          Enum.map(tools_list, fn tool ->
            case provider do
              :anthropic -> convert_synthetic_tool_anthropic(tool)
              _ -> tool
            end
          end)

        merged = Map.put(merged, :tools, existing_tools ++ formatted_tools)

        case tool_settings[:__structured_output_tool_choice__] do
          nil -> merged
          choice -> Map.put(merged, :tool_choice, choice)
        end

      # Singular: single synthetic tool (standard :tool_call mode)
      %{__structured_output_tool__: tool} ->
        existing_tools = merged[:tools] || []

        # Convert synthetic tool to provider format
        formatted_tool =
          case provider do
            :anthropic -> convert_synthetic_tool_anthropic(tool)
            _ -> tool
          end

        merged = Map.put(merged, :tools, existing_tools ++ [formatted_tool])

        case tool_settings[:__structured_output_tool_choice__] do
          nil -> merged
          choice -> Map.put(merged, :tool_choice, choice)
        end

      _ ->
        merged
    end
  end

  # Convert synthetic tool to Anthropic format (atom keys)
  defp convert_synthetic_tool_anthropic(tool) do
    func = tool["function"]
    # Use ToolSchema.to_anthropic with a minimal Tool struct
    %{
      name: func["name"],
      description: func["description"],
      input_schema: %{
        type: "object",
        properties: func["parameters"]["properties"] || %{},
        required: func["parameters"]["required"] || []
      }
    }
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

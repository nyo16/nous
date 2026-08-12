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

  ## Examples

  Most callers reach the runner through `Nous.run/3`, but calling it directly
  is the same thing minus the convenience wrapper. `run/3` drives the whole
  tool-calling loop and returns a plain map:

      agent =
        Nous.Agent.new("openai:gpt-4o-mini",
          tools: [&Nous.Tools.DateTimeTools.current_date/2]
        )

      {:ok, result} = Nous.AgentRunner.run(agent, "What day is it in Athens?")

      result.output          #=> "It's Tuesday, 12 August 2026 in Athens."
      result.iterations      #=> 2
      result.usage.total_tokens
      result.new_messages    #=> the assistant/tool messages this run appended

  To continue a conversation, hand the previous run's messages back in — or
  reuse `result.context` directly with `run_with_context/3`, which also
  preserves any `deps` a tool mutated:

      {:ok, first} = Nous.AgentRunner.run(agent, "My name is Ada.")
      {:ok, second} = Nous.AgentRunner.run(agent, "What is my name?",
        message_history: first.all_messages
      )

      {:ok, third} = Nous.AgentRunner.run_with_context(agent, second.context)

  Streaming is a flag on the same loop, not a separate code path. With
  `stream: true` the tool loop still runs; deltas arrive through callbacks:

      {:ok, result} =
        Nous.AgentRunner.run(agent, "Write a haiku about BEAM schedulers",
          stream: true,
          callbacks: %{on_llm_new_delta: fn _event, delta -> IO.write(delta) end}
        )

  `run_stream/3` instead returns an enumerable of `Nous.Types.stream_event()`
  tuples, for when you want to own the consumption:

      {:ok, stream} = Nous.AgentRunner.run_stream(agent, "Explain OTP in one line")

      Enum.each(stream, fn
        {:text_delta, text} -> IO.write(text)
        {:complete, _result} -> IO.puts("")
        _other -> :ok
      end)
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

  alias Nous.AgentRunner.{
    IterationLoop,
    PromptAssembly,
    RequestDispatch,
    Streaming,
    ToolExecution
  }

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
    result = IterationLoop.execute_loop(agent, behaviour, ctx)
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

    case IterationLoop.execute_loop(agent, behaviour, ctx) do
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

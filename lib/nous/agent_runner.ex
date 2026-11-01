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
      result.new_messages    #=> the messages this run appended: its user prompt,
                             #   then the assistant and tool messages

  To continue a conversation, hand the previous run's context back in
  (`:context`, or `run_with_context/3`) — the conversation, any `deps` a tool
  mutated and plugin state carry over — or keep the history yourself:
  `new_messages` is exactly what each run appended, so the running history is
  the concatenation of every run's `new_messages`:

      {:ok, first} = Nous.AgentRunner.run(agent, "My name is Ada.")
      {:ok, second} = Nous.AgentRunner.run(agent, "What is my name?", context: first.context)

      {:ok, again} = Nous.AgentRunner.run(agent, "What is my name?",
        message_history: first.new_messages
      )

  `new_messages_truncated?` is `true` when compaction (for example
  `Nous.Plugins.Summarization`) folded part of this run into a summary of
  earlier history; `new_messages` then holds only what survived.

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

  alias Nous.Session.Log

  require Logger

  @max_iterations 10

  @doc """
  Run agent to completion.

  ## Options
    * `:deps` - Dependencies for tools
    * `:message_history` - Previous messages
    * `:usage_limits` - Usage limits (not implemented yet)
    * `:model_settings` - Override model settings
    * `:max_iterations` - Maximum model requests for this run (default: the
      agent's `:max_iterations`, else 10). Counted per run: a continued
      `:context` starts again at zero.
    * `:cancellation_check` - Function to check if execution should be cancelled.
      Under `stream: true`, also invoked between every streamed chunk; on
      cancellation the consumer aborts cleanly without partial tool execution.
    * `:callbacks` - Map of callback functions
    * `:notify_pid` - PID to receive event messages
    * `:context` - Existing context to continue from
    * `:output_type` - Override the agent's `output_type` for this run
    * `:structured_output` - Override the agent's `structured_output` options for this run
    * `:sandbox` - Override the agent's `sandbox` policy for this run. Accepts
      the same shapes as `Nous.Agent.new/2`'s `:sandbox` option (a mode atom, a
      keyword list, or a `Nous.Sandbox.Policy`), e.g.
      `Nous.run(agent, prompt, sandbox: :read_only)`
    * `:router` - Override the agent's `router` for this run (see
      `Nous.Router`); `nil` disables routing
    * `:approval_handler` - Handler consulted before any tool with
      `requires_approval: true` runs (see `Nous.RunContext`). Without one such
      tools are rejected. `Nous.Plugins.HumanInTheLoop` can also install a
      handler via `deps[:hitl_config]`; when both are present the plugin's
      wrapped handler wins, on every run including a continued `:context`
      (the plugin installs it in `before_run/2`, after context build).
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

    # Build context from options. A continued context starts at the primary
    # model again: the sticky fallback and the routing decision are
    # runtime-only (see IterationLoop).
    ctx = agent |> build_context(prompt, opts) |> IterationLoop.clear_runtime_models()

    # build_context/3 appends the prompt last, so this run starts at its event.
    boundary = run_boundary(ctx, Log.count(ctx.log) - 1)

    # Execute callbacks
    Callbacks.execute(ctx, :on_agent_start, %{agent: agent})

    # Get behaviour module
    behaviour = Behaviour.get_module(agent)

    # Initialize context via behaviour (optional callback)
    ctx = Behaviour.call(behaviour, :init_context, [agent, ctx], ctx)

    # Plugin init (once per context) and before_run (every run)
    ctx = prepare_plugins(agent, ctx)

    ctx = build_hook_registry(agent, ctx)

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
            agent_result = build_result(agent, final_ctx, output, boundary)

            # Run after_run plugin hooks
            updated_ctx = Plugin.run_after_run(agent.plugins, agent, agent_result, final_ctx)

            # Fire session_end hooks
            Hook.Runner.run(updated_ctx.hook_registry, :session_end, %{
              agent_name: agent.name,
              output: output
            })

            agent_result =
              if updated_ctx != final_ctx,
                do: build_result(agent, updated_ctx, output, boundary),
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

            served_model = IterationLoop.served_model(final_ctx) || agent.model

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
                # When routing or fallback moved the run off the configured
                # model, surface BOTH so observability can split metrics by
                # configured and active (last used) model.
                active_model_provider: served_model.provider,
                active_model_name: served_model.model,
                fallback_used: IterationLoop.fallback_used?(final_ctx)
              }
            )

            # Execute completion callback
            Callbacks.execute(final_ctx, :on_agent_complete, agent_result)

            {:ok, agent_result}

          {:error, %Errors.ValidationError{} = err} ->
            max_retries = Keyword.get(agent.structured_output, :max_retries, 0)

            case maybe_retry_validation(agent, behaviour, final_ctx, err, max_retries) do
              {:ok, retry_ctx, output} ->
                agent_result = build_result(agent, retry_ctx, output, boundary)
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

  Plugin `init/2` runs only if the context has not been through it yet: a
  context built by hand (as `Nous.run(agent, messages: [...])` does) or
  restored from a serialized session is initialised once here, while a
  `result.context` from an earlier run is continued as it is, so plugin state
  such as an activated skill carries over. Plugin `before_run/2` runs on every
  call.

  There is no prompt to append, so the run's input is the user messages the
  context ends with (the ones a caller added with `Context.add_message/2`, or
  the trailing user messages of `Nous.run(agent, messages: [...])`):
  `result.new_messages` starts with them.
  """
  @spec run_with_context(Agent.t(), Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_with_context(%Agent{} = agent, %Context{} = ctx, opts \\ []) do
    agent = apply_runtime_overrides(agent, opts)
    boundary = run_boundary(ctx, pending_input_position(ctx))

    # Merge any additional options into context
    ctx =
      ctx
      |> maybe_update_callbacks(opts)
      |> maybe_update_notify_pid(opts)
      |> maybe_update_stream(opts)
      |> Context.set_needs_response(true)
      |> Context.patch_dangling_tool_calls()
      |> IterationLoop.clear_runtime_models()
      |> reset_iteration()

    # Plugin init only for a context that never went through it (built by
    # hand, or restored: the marker is runtime-only); before_run every run.
    ctx = prepare_plugins(agent, ctx)

    # A restored context carries no registry (it is runtime-only), so rebuild
    # it here exactly as run/3 does; otherwise an inbox run fires no hooks.
    ctx = build_hook_registry(agent, ctx)

    # Get behaviour module
    behaviour = Behaviour.get_module(agent)

    case IterationLoop.execute_loop(agent, behaviour, ctx) do
      {:ok, final_ctx} ->
        case behaviour.extract_output(agent, final_ctx) do
          {:ok, output} ->
            agent_result = build_result(agent, final_ctx, output, boundary)
            updated_ctx = Plugin.run_after_run(agent.plugins, agent, agent_result, final_ctx)

            agent_result =
              if updated_ctx != final_ctx,
                do: build_result(agent, updated_ctx, output, boundary),
                else: agent_result

            {:ok, agent_result}

          {:error, %Errors.ValidationError{} = err} ->
            max_retries = Keyword.get(agent.structured_output, :max_retries, 0)

            case maybe_retry_validation(agent, behaviour, final_ctx, err, max_retries) do
              {:ok, retry_ctx, output} ->
                {:ok, build_result(agent, retry_ctx, output, boundary)}

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

  Returns a stream that yields events as they occur. A stream is a single
  request on `agent.model` (and its fallback chain): the agent's `router` is
  **not** consulted here. Use `run/3` with `stream: true` for routed runs.

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
    ctx = prepare_plugins(agent, ctx)

    tools = behaviour.get_tools(agent)
    plugin_tools = Plugin.collect_tools(agent.plugins, agent, ctx)
    all_tools = tools ++ plugin_tools

    # build_context/3 starts every run at iteration 0, so this is always the
    # first request of the run.
    ctx = PromptAssembly.apply_plugin_system_prompts(agent, ctx)

    {ctx, all_tools} = Plugin.run_before_request(agent.plugins, agent, ctx, all_tools)
    all_tools = ToolExecution.visible_tools(agent, all_tools)

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

  # Apply per-run overrides for output_type, structured_output, model_settings,
  # the sandbox policy and the router
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
    |> then(fn a ->
      case Keyword.fetch(opts, :sandbox) do
        {:ok, nil} -> %{a | sandbox: nil}
        {:ok, sandbox} -> %{a | sandbox: Nous.Sandbox.Policy.new(sandbox)}
        :error -> a
      end
    end)
    |> then(fn a ->
      case Keyword.fetch(opts, :router) do
        {:ok, router} -> %{a | router: Nous.Router.new(router)}
        :error -> a
      end
    end)
  end

  # The one place plugins are set up for a run, on every entry point. `init/2`
  # runs once per context: the marker it sets is how a continued context (a
  # previous run's `result.context`) keeps its plugin state instead of being
  # reset. It is runtime-only, so a restored context is initialised again.
  # `before_run/2` runs on every run.
  defp prepare_plugins(agent, ctx) do
    ctx =
      if ctx.plugins_initialized,
        do: ctx,
        else: %{Plugin.run_init(agent.plugins, agent, ctx) | plugins_initialized: true}

    Plugin.run_before_run(agent.plugins, agent, ctx)
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
        |> maybe_update_cancellation_check(opts)
        |> maybe_update_approval_handler(opts)
        |> maybe_update_max_iterations(opts)
        |> reset_iteration()

      nil ->
        system_prompt = base_system_prompt(agent, opts)
        message_history = Keyword.get(opts, :message_history, [])
        messages = build_initial_messages(message_history, prompt, system_prompt)
        fresh_context(agent, messages, system_prompt, opts)
    end
  end

  @doc false
  # The context `Nous.Agent.run(agent, messages: [...])` runs: the same fresh
  # context `run/3` builds for a prompt, so the agent's instructions (or
  # system prompt), todo injection and structured-output suffix reach the model
  # on this entry point too. A caller whose list already starts with a
  # `:system` message keeps it and gets no second system prompt;
  # `ctx.system_prompt` is then nil, because the agent's prompt is not in use.
  @spec messages_context(Agent.t(), [Message.t()], keyword()) :: Context.t()
  def messages_context(%Agent{} = agent, messages, opts) when is_list(messages) do
    case messages do
      [%Message{role: :system} | _] ->
        fresh_context(agent, messages, nil, opts)

      _ ->
        # The run-level :output_type / :structured_output overrides decide the
        # suffix, exactly as on the prompt path.
        system_prompt = base_system_prompt(apply_runtime_overrides(agent, opts), opts)
        fresh_context(agent, system_message(system_prompt) ++ messages, system_prompt, opts)
    end
  end

  # The agent's system prompt for a fresh context: `instructions` (else
  # `system_prompt`), the todo list when enabled, and the structured-output
  # instructions for a non-string `output_type`.
  defp base_system_prompt(agent, opts) do
    system_prompt =
      resolve_prompt(agent.instructions, opts) ||
        resolve_prompt(agent.system_prompt, opts)

    system_prompt =
      if agent.enable_todos do
        PromptAssembly.inject_todos_into_prompt(
          system_prompt || "",
          Keyword.get(opts, :deps, %{})
        )
      else
        system_prompt
      end

    if agent.output_type != :string do
      mode =
        case agent.output_type do
          {:one_of, _} -> :tool_call
          _ -> Keyword.get(agent.structured_output, :mode, :auto)
        end

      case OutputSchema.system_prompt_suffix(agent.output_type, mode: mode) do
        nil -> system_prompt
        suffix -> (system_prompt || "") <> "\n\n" <> suffix
      end
    else
      system_prompt
    end
  end

  defp fresh_context(agent, messages, system_prompt, opts) do
    Context.new(
      messages: messages,
      system_prompt: system_prompt,
      deps: Keyword.get(opts, :deps, %{}),
      max_iterations: Keyword.get(opts, :max_iterations, agent.max_iterations || @max_iterations),
      callbacks: Keyword.get(opts, :callbacks, %{}),
      notify_pid: Keyword.get(opts, :notify_pid),
      agent_name: agent.name,
      cancellation_check: Keyword.get(opts, :cancellation_check),
      approval_handler: Keyword.get(opts, :approval_handler),
      pubsub: Keyword.get(opts, :pubsub),
      pubsub_topic: Keyword.get(opts, :pubsub_topic),
      stream: Keyword.get(opts, :stream, false)
    )
  end

  # `max_iterations` caps one run, so every run counts its model requests from
  # zero. This also makes the run's first request the "first iteration" the
  # plugin system-prompt gate in IterationLoop.prepare_tools/4 rebuilds on.
  defp reset_iteration(ctx), do: %{ctx | iteration: 0}

  # When continuing from an existing context (the %Context{} branch above),
  # honor the `:stream` opt as an override.
  defp maybe_update_stream(ctx, opts) do
    case Keyword.fetch(opts, :stream) do
      {:ok, value} when is_boolean(value) -> %{ctx | stream: value}
      _ -> ctx
    end
  end

  # Run-scoped options a caller passes alongside `:context` used to be silently
  # dropped, which (a) left continued runs without cooperative cancellation and
  # (b) made the documented `:approval_handler` opt a no-op for `:context`
  # callers. Fetch-guarded: absent opts leave the context untouched.
  defp maybe_update_cancellation_check(ctx, opts) do
    case Keyword.fetch(opts, :cancellation_check) do
      {:ok, check} when is_function(check, 0) or is_nil(check) ->
        %{ctx | cancellation_check: check}

      _ ->
        ctx
    end
  end

  defp maybe_update_approval_handler(ctx, opts) do
    case Keyword.fetch(opts, :approval_handler) do
      {:ok, handler} when is_function(handler, 1) or is_nil(handler) ->
        %{ctx | approval_handler: handler}

      _ ->
        ctx
    end
  end

  defp maybe_update_max_iterations(ctx, opts) do
    case Keyword.fetch(opts, :max_iterations) do
      {:ok, max} when is_integer(max) and max > 0 -> %{ctx | max_iterations: max}
      _ -> ctx
    end
  end

  defp build_initial_messages(history, prompt, system_prompt) do
    system_message(system_prompt) ++ history ++ [Message.user(prompt)]
  end

  defp system_message(system_prompt) when system_prompt in [nil, ""], do: []
  defp system_message(system_prompt), do: [Message.system(system_prompt)]

  defp resolve_prompt(nil, _opts), do: nil
  defp resolve_prompt(prompt, _opts) when is_binary(prompt), do: prompt

  defp resolve_prompt(prompt_fn, opts) when is_function(prompt_fn, 1) do
    ctx = RunContext.new(Keyword.get(opts, :deps, %{}))
    prompt_fn.(ctx)
  end

  # Rebuilt from the agent's hook sources — `agent.hooks` then every plugin's
  # `hooks/2`, after every plugin's `init/2` and `before_run/2` — on every run,
  # so it is idempotent across AgentServer turns (a registry carried in
  # `result.context` is replaced, never added to) and survives a session
  # restore (the registry is runtime-only and not serialized). With no hooks
  # from either source, a hand-set `ctx.hook_registry` is kept.
  defp build_hook_registry(%Agent{} = agent, ctx) do
    case agent.hooks ++ Plugin.collect_hooks(agent.plugins, agent, ctx) do
      [] -> ctx
      hooks -> %{ctx | hook_registry: Hook.Registry.from_hooks(hooks)}
    end
  end

  defp build_result(_agent, ctx, output, boundary) do
    ctx = IterationLoop.clear_runtime_models(ctx)

    # `ctx.messages` is not a list the runner appended to any more: it is the
    # fold of this session's event log, re-materialized by `Nous.Agent.Context`
    # after every append, plus the assembly-time system-prompt overlay that is
    # deliberately not history (see `Nous.AgentRunner.PromptAssembly`). Reading
    # it here IS reading the fold; folding `ctx.log` directly instead would drop
    # that overlay and hand back a transcript the model never saw.
    transcript = ctx.messages
    {new_messages, truncated?} = new_messages(ctx, boundary)

    %{
      output: output,
      usage: ctx.usage,
      iterations: ctx.iteration,
      all_messages: transcript,
      new_messages: new_messages,
      new_messages_truncated?: truncated?,
      deps: ctx.deps,
      # Include context for continuation
      context: ctx
    }
  end

  # Where this run starts in the session log — a surface position, see
  # `Nous.Session.Log.messages_since/2` — and the log's newest event at that
  # moment. The log is append-only, so the position survives compaction, which
  # a remembered list length does not. The head is kept to notice the one thing
  # that is not an append: a `%{ctx | messages: ...}` write re-seeds the log on
  # the next append and renumbers every seq.
  defp run_boundary(%Context{log: log}, position) do
    head = log |> Log.since(max(Log.count(log) - 1, 0)) |> List.first()
    {max(position, 0), head}
  end

  # run_with_context/3 appends no prompt: its input is the user messages the
  # transcript ends with, if any. A user message that replaced another (a
  # guard's placeholder) sits at the original's position, not its own seq.
  defp pending_input_position(%Context{log: log}) do
    log
    |> Log.surface()
    |> Enum.reverse()
    |> Enum.take_while(&(&1.type == :user_message))
    |> Enum.map(&Log.position/1)
    |> Enum.min(fn -> Log.count(log) end)
  end

  # Exactly what this run appended — its user prompt included — or, when
  # compaction folded part of it into a summary of earlier history, what
  # survived, flagged as truncated.
  defp new_messages(%Context{log: log}, {position, head}) do
    if log_intact?(log, head) do
      Log.messages_since(log, position)
    else
      {last_user_turn(Log.derive_messages(log)), true}
    end
  end

  defp log_intact?(_log, nil), do: true

  defp log_intact?(log, %{seq: seq} = head) do
    case Log.since(log, seq) do
      [%{seq: ^seq} = event | _] -> event == head
      # A snapshot drops shadowed events but never renumbers; a re-seeded log
      # is numbered from zero without gaps, so it would still hold this seq.
      [_later | _] -> true
      [] -> false
    end
  end

  # The log was re-seeded under the run, so its seqs say nothing about where
  # the run began; the last user turn on is the closest honest answer.
  defp last_user_turn(messages) do
    case messages |> Enum.reverse() |> Enum.split_while(&(&1.role != :user)) do
      {tail, [user | _]} -> [user | Enum.reverse(tail)]
      {_tail, []} -> messages
    end
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

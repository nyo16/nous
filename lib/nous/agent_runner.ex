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
    Message,
    Messages,
    ModelDispatcher,
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
    * `:cancellation_check` - Function to check if execution should be cancelled
    * `:callbacks` - Map of callback functions
    * `:notify_pid` - PID to receive event messages
    * `:context` - Existing context to continue from

  """
  @spec run(Agent.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Agent{} = agent, prompt, opts \\ []) do
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
            duration_ms = System.convert_time_unit(duration, :native, :millisecond)

            Logger.info("""
            Agent run completed: #{agent.name}
              Duration: #{duration_ms}ms
              Iterations: #{final_ctx.iteration}
              Tokens: #{final_ctx.usage.total_tokens} (in: #{final_ctx.usage.input_tokens}, out: #{final_ctx.usage.output_tokens})
              Tool calls: #{final_ctx.usage.tool_calls}
              Requests: #{final_ctx.usage.requests}
            """)

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
                model_name: agent.model.model
              }
            )

            # Execute completion callback
            Callbacks.execute(final_ctx, :on_agent_complete, agent_result)

            {:ok, agent_result}

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
    # Merge any additional options into context
    ctx =
      ctx
      |> maybe_update_callbacks(opts)
      |> maybe_update_notify_pid(opts)
      |> Context.set_needs_response(true)
      |> Context.patch_dangling_tool_calls()

    # Get behaviour module
    behaviour = Behaviour.get_module(agent)

    case execute_loop(agent, behaviour, ctx) do
      {:ok, final_ctx} ->
        case behaviour.extract_output(agent, final_ctx) do
          {:ok, output} ->
            {:ok, build_result(agent, final_ctx, output)}

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

    # Request stream from model
    case get_dispatcher().request_stream(agent.model, messages, model_settings) do
      {:ok, stream} ->
        # Wrap stream to execute callbacks
        wrapped_stream = wrap_stream_with_callbacks(stream, ctx)
        {:ok, wrapped_stream}

      error ->
        error
    end
  end

  # Private functions

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

      nil ->
        # Build fresh context
        message_history = Keyword.get(opts, :message_history, [])

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
          cancellation_check: Keyword.get(opts, :cancellation_check)
        )
    end
  end

  defp build_initial_messages(history, prompt, system_prompt) do
    messages = []

    # Add system prompt if present
    messages =
      if system_prompt && system_prompt != "" do
        [Message.system(system_prompt) | messages]
      else
        messages
      end

    # Add history
    messages = messages ++ history

    # Add user prompt
    messages ++ [Message.user(prompt)]
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

  defp do_iteration(agent, behaviour, ctx) do
    # Check needs_response - if false, we're done
    if not ctx.needs_response do
      {:ok, ctx}
      # Check max iterations
    else
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

        # Apply plugin system prompt fragments
        ctx = apply_plugin_system_prompts(agent, ctx)

        # Run plugin before_request hooks
        {ctx, all_tools} = Plugin.run_before_request(agent.plugins, agent, ctx, all_tools)

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

        # Apply before_request callback if implemented
        model_settings =
          Behaviour.call(
            behaviour,
            :before_request,
            [agent, ctx, Keyword.new(model_settings)],
            Keyword.new(model_settings)
          )
          |> Map.new()

        # Make model request
        Logger.debug(
          "Agent iteration #{ctx.iteration + 1}/#{ctx.max_iterations}: requesting model response"
        )

        case get_dispatcher().request(agent.model, messages, model_settings) do
          {:ok, response} ->
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
      end
    end
  end

  defp handle_tool_calls(agent, behaviour, ctx, response, tools) do
    # Extract tool calls
    tool_calls = Messages.extract_tool_calls([response])

    if Enum.empty?(tool_calls) do
      ctx
    else
      # Update usage to track tool calls
      ctx = Context.add_usage(ctx, %{tool_calls: length(tool_calls)})

      tool_names = Enum.map_join(tool_calls, ", ", &get_tool_field(&1, :name))
      Logger.debug("Detected #{length(tool_calls)} tool call(s): #{tool_names}")

      # Build run context for tool execution
      run_ctx = Context.to_run_context(ctx)

      # Execute all tool calls and collect results
      {tool_results, ctx} =
        Enum.reduce(tool_calls, {[], ctx}, fn call, {results, acc_ctx} ->
          call_name = get_tool_field(call, :name)
          call_id = get_tool_field(call, :id)
          call_arguments = get_tool_field(call, :arguments)

          # Execute callback before tool
          Callbacks.execute(acc_ctx, :on_tool_call, %{
            id: call_id,
            name: call_name,
            arguments: call_arguments
          })

          # Check approval for tools that require it
          cleaned_name = clean_tool_name(call_name)
          tool = Enum.find(tools, fn t -> t.name == cleaned_name end)

          case check_tool_approval(tool, call, acc_ctx) do
            :reject ->
              Logger.info("Tool '#{cleaned_name}' rejected by approval handler")
              result_msg = Message.tool(call_id, "Tool call was rejected by approval handler.")
              {[result_msg | results], acc_ctx}

            {:edit, new_args} ->
              Logger.debug("Tool '#{cleaned_name}' arguments edited by approval handler")
              edited_call = put_tool_field(call, :arguments, new_args)
              {result_msg, context_updates} = execute_single_tool(tools, edited_call, run_ctx)

              Callbacks.execute(acc_ctx, :on_tool_response, %{
                id: call_id,
                name: call_name,
                result: result_msg.content
              })

              acc_ctx =
                Behaviour.call(
                  behaviour,
                  :after_tool,
                  [agent, edited_call, result_msg.content, acc_ctx],
                  acc_ctx
                )

              acc_ctx =
                if map_size(context_updates) > 0 do
                  Logger.debug("Merging context updates: #{inspect(Map.keys(context_updates))}")
                  Context.merge_deps(acc_ctx, context_updates)
                else
                  acc_ctx
                end

              {[result_msg | results], acc_ctx}

            :approve ->
              {result_msg, context_updates} = execute_single_tool(tools, call, run_ctx)

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

              {[result_msg | results], acc_ctx}
          end
        end)

      # Add tool result messages
      tool_results = Enum.reverse(tool_results)
      ctx = Context.add_messages(ctx, tool_results)

      # Record tool calls
      Enum.reduce(tool_calls, ctx, fn call, acc ->
        Context.add_tool_call(acc, call)
      end)
    end
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

  # Check if a tool call requires approval and invoke the handler
  defp check_tool_approval(nil, _call, _ctx), do: :approve

  defp check_tool_approval(%Tool{requires_approval: true}, call, %Context{
         approval_handler: handler
       })
       when is_function(handler) do
    tool_call_info = %{
      name: get_tool_field(call, :name),
      id: get_tool_field(call, :id),
      arguments: get_tool_field(call, :arguments)
    }

    case handler.(tool_call_info) do
      :approve -> :approve
      :reject -> :reject
      {:edit, new_args} when is_map(new_args) -> {:edit, new_args}
      _ -> :approve
    end
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

  # Clean tool names - Claude sometimes uses XML-like syntax
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
    Stream.transform(stream, nil, fn event, acc ->
      case event do
        {:text_delta, text} ->
          Callbacks.execute(ctx, :on_llm_new_delta, text)
          {[event], acc}

        {:thinking_delta, text} ->
          Callbacks.execute(ctx, :on_llm_new_delta, "[thinking] #{text}")
          {[event], acc}

        {:tool_call_delta, calls} ->
          Enum.each(calls, fn call ->
            Callbacks.execute(ctx, :on_tool_call, call)
          end)

          {[event], acc}

        {:finish, _reason} = finish ->
          {[finish], acc}

        other ->
          {[other], acc}
      end
    end)
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
    in_progress = Enum.filter(todos, &(&1.status == "in_progress"))
    pending = Enum.filter(todos, &(&1.status == "pending"))
    completed = Enum.filter(todos, &(&1.status == "completed"))

    sections = []

    # In Progress section
    sections =
      if length(in_progress) > 0 do
        in_progress_list =
          Enum.map_join(in_progress, "\n", fn todo ->
            priority_icon = priority_icon(todo.priority)
            "  #{priority_icon} [#{todo.id}] #{todo.text}"
          end)

        ["\nIn Progress (#{length(in_progress)}):\n#{in_progress_list}" | sections]
      else
        sections
      end

    # Pending section
    sections =
      if length(pending) > 0 do
        pending_list =
          Enum.map_join(pending, "\n", fn todo ->
            priority_icon = priority_icon(todo.priority)
            "  #{priority_icon} [#{todo.id}] #{todo.text}"
          end)

        ["\nPending (#{length(pending)}):\n#{pending_list}" | sections]
      else
        sections
      end

    # Completed section
    sections =
      if length(completed) > 0 do
        completed_list =
          Enum.map_join(completed, "\n", fn todo ->
            "  * [#{todo.id}] #{todo.text}"
          end)

        ["\nCompleted (#{length(completed)}):\n#{completed_list}" | sections]
      else
        sections
      end

    if sections == [] do
      "No tasks yet. Use add_todo() to create tasks."
    else
      sections
      |> Enum.reverse()
      |> Enum.join("\n")
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

  # Get the model dispatcher, allowing dependency injection for testing
  defp get_dispatcher do
    Application.get_env(:nous, :model_dispatcher, ModelDispatcher)
  end
end

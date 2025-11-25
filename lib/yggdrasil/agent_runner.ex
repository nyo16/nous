defmodule Yggdrasil.AgentRunner do
  @moduledoc """
  Executes agent runs with tool calling loop.

  The AgentRunner is responsible for:
  - Building messages with system prompts and instructions
  - Calling the model via the OpenAICompatible adapter
  - Detecting and executing tool calls
  - Looping until the model provides a final response
  - Extracting and validating output
  """

  alias Yggdrasil.{
    Agent,
    Messages,
    ModelDispatcher,
    RunContext,
    Tool,
    ToolExecutor,
    Usage,
    Errors
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
    * `:cancellation_check` - Function to check if execution should be cancelled

  """
  @spec run(Agent.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Agent{} = agent, prompt, opts \\ []) do
    start_time = System.monotonic_time()

    Logger.info("Starting agent run: #{agent.name} with model #{agent.model.provider}:#{agent.model.model}")
    Logger.debug("Agent has #{length(agent.tools)} tools available")

    # Emit start event
    :telemetry.execute(
      [:yggdrasil, :agent, :run, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        agent_name: agent.name,
        model_provider: agent.model.provider,
        model_name: agent.model.model,
        tool_count: length(agent.tools),
        has_tools: length(agent.tools) > 0
      }
    )

    # Initialize state
    state = %{
      agent: agent,
      deps: Keyword.get(opts, :deps),
      message_history: Keyword.get(opts, :message_history, []),
      usage: Usage.new(),
      iteration: 0,
      start_time: start_time,
      max_iterations: Keyword.get(opts, :max_iterations, @max_iterations),
      cancellation_check: Keyword.get(opts, :cancellation_check)
    }

    # Build initial messages
    messages = build_initial_messages(state, prompt)

    # Execute loop and emit stop/exception
    result = execute_loop(state, messages)
    duration = System.monotonic_time() - start_time

    case result do
      {:ok, agent_result} ->
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.info("""
        Agent run completed: #{agent.name}
          Duration: #{duration_ms}ms
          Iterations: #{state.iteration}
          Tokens: #{agent_result.usage.total_tokens} (in: #{agent_result.usage.input_tokens}, out: #{agent_result.usage.output_tokens})
          Tool calls: #{agent_result.usage.tool_calls}
          Requests: #{agent_result.usage.requests}
        """)

        :telemetry.execute(
          [:yggdrasil, :agent, :run, :stop],
          %{
            duration: duration,
            total_tokens: agent_result.usage.total_tokens,
            input_tokens: agent_result.usage.input_tokens,
            output_tokens: agent_result.usage.output_tokens,
            tool_calls: agent_result.usage.tool_calls,
            requests: agent_result.usage.requests,
            iterations: state.iteration
          },
          %{
            agent_name: agent.name,
            model_provider: agent.model.provider,
            model_name: agent.model.model
          }
        )

        result

      {:error, error} ->
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.error("""
        Agent run failed: #{agent.name}
          Duration: #{duration_ms}ms
          Error: #{inspect(error)}
        """)

        :telemetry.execute(
          [:yggdrasil, :agent, :run, :exception],
          %{duration: duration},
          %{
            agent_name: agent.name,
            model_provider: agent.model.provider,
            kind: :error,
            reason: error,
            stacktrace: []
          }
        )

        result
    end
  end

  @doc """
  Run agent with streaming (simplified version).

  Full streaming implementation would handle tool calls in stream.
  For now, this just passes through to the model's streaming.
  """
  @spec run_stream(Agent.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_stream(%Agent{} = agent, prompt, opts \\ []) do
    # Build messages
    state = %{
      agent: agent,
      deps: Keyword.get(opts, :deps),
      message_history: Keyword.get(opts, :message_history, [])
    }

    messages = build_initial_messages(state, prompt)

    # Add tools to settings if any
    model_settings =
      if Enum.empty?(agent.tools) do
        agent.model_settings
      else
        tool_schemas = convert_tools_for_provider(agent.model.provider, agent.tools)
        Map.put(agent.model_settings, :tools, tool_schemas)
      end

    # Request stream from model
    case ModelDispatcher.request_stream(agent.model, messages, model_settings) do
      {:ok, stream} -> {:ok, stream}
      error -> error
    end
  end

  # Private functions

  defp execute_loop(state, messages) do
    # Check for cancellation before each iteration
    case check_cancellation(state) do
      {:error, _} = err ->
        err

      :ok ->
        do_iteration(state, messages)
    end
  end

  defp check_cancellation(state) do
    if state.cancellation_check do
      try do
        state.cancellation_check.()
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

  defp do_iteration(state, messages) do
    if state.iteration >= state.max_iterations do
      Logger.error("""
      Max iterations exceeded
        Agent: #{state.agent.name}
        Max iterations: #{state.max_iterations}
        Total tokens used: #{state.usage.total_tokens}
      """)

      error = Errors.MaxIterationsExceeded.exception(max_iterations: state.max_iterations)
      {:error, error}
    else
      # Add tools to model settings if any
      model_settings =
        if Enum.empty?(state.agent.tools) do
          state.agent.model_settings
        else
          # Convert tools to appropriate format based on provider
          Logger.debug("Converting #{length(state.agent.tools)} tools for provider: #{state.agent.model.provider}")
          tool_schemas = convert_tools_for_provider(state.agent.model.provider, state.agent.tools)
          Map.put(state.agent.model_settings, :tools, tool_schemas)
        end

      # Make model request
      Logger.debug("Agent iteration #{state.iteration + 1}/#{state.max_iterations}: requesting model response")

      case ModelDispatcher.request(state.agent.model, messages, model_settings) do
        {:ok, response} ->
          # Update usage
          new_usage = Usage.add(state.usage, response.usage)
          new_state = %{state | usage: new_usage, iteration: state.iteration + 1}

          Logger.debug("Model response received (tokens: +#{response.usage.total_tokens}, total: #{new_usage.total_tokens})")

          # Check for tool calls
          tool_calls = Messages.extract_tool_calls(response.parts)

          if Enum.empty?(tool_calls) do
            # No tool calls, extract final output
            Logger.debug("No tool calls detected, extracting final output")
            output = extract_output(response, state.agent.output_type)

            {:ok,
             %{
               output: output,
               usage: new_usage,
               all_messages: messages ++ [response],
               new_messages: [response],
               deps: state.deps  # Return updated deps so todos are accessible
             }}
          else
            # Execute tools and continue
            tool_names = Enum.map_join(tool_calls, ", ", & &1.name)
            Logger.debug("Detected #{length(tool_calls)} tool call(s): #{tool_names}")
            handle_tool_calls(new_state, messages, response, tool_calls)
          end

        {:error, reason} ->
          Logger.error("""
          Model request failed in iteration #{state.iteration + 1}
            Agent: #{state.agent.name}
            Model: #{state.agent.model.provider}:#{state.agent.model.model}
            Reason: #{inspect(reason)}
          """)
          {:error, reason}
      end
    end
  end

  defp handle_tool_calls(state, messages, response, tool_calls) do
    # Update usage to track tool calls
    new_usage = Usage.inc_tool_calls(state.usage, length(tool_calls))
    state = %{state | usage: new_usage}

    # Build run context
    ctx = RunContext.new(state.deps, usage: state.usage)

    # Execute all tool calls and collect context updates
    {tool_results, context_updates} =
      Enum.reduce(tool_calls, {[], %{}}, fn call, {results, updates} ->
        {result, new_updates} = execute_single_tool(state.agent.tools, call, ctx)
        {[result | results], Map.merge(updates, new_updates)}
      end)

    tool_results = Enum.reverse(tool_results)

    # Merge context updates into state.deps
    updated_deps = if map_size(context_updates) > 0 do
      Logger.debug("Merging context updates: #{inspect(Map.keys(context_updates))}")
      Map.merge(state.deps || %{}, context_updates)
    else
      state.deps
    end

    # Update state with new deps for next iteration
    state = %{state | deps: updated_deps}

    # Add response and tool results to messages
    new_messages = messages ++ [response] ++ tool_results

    Logger.info("Completed #{length(tool_calls)} tool call(s), continuing to next iteration")

    # Continue loop with updated state
    execute_loop(state, new_messages)
  end

  defp execute_single_tool(tools, call, ctx) do
    # Clean up tool name - Claude sometimes adds XML-like syntax
    cleaned_name = clean_tool_name(call.name)

    tool = Enum.find(tools, fn t -> t.name == cleaned_name end)

    {result, context_updates} =
      if tool do
        case ToolExecutor.execute(tool, call.arguments, ctx) do
          {:ok, result} ->
            Logger.debug("Tool '#{cleaned_name}' executed successfully")

            # Extract context updates if present (only for map results)
            {clean_result, updates} = if is_map(result) do
              updates = Map.get(result, :__update_context__, %{})

              if map_size(updates) > 0 do
                Logger.debug("Tool '#{cleaned_name}' returned context updates: #{inspect(Map.keys(updates))}")
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
            error_msg = Exception.message(error)
            Logger.error("Tool '#{cleaned_name}' execution failed: #{error_msg}")
            {error_msg, %{}}
        end
      else
        available_tools = Enum.map_join(tools, ", ", & &1.name)
        Logger.error("""
        Tool not found: #{call.name}
          Cleaned name: #{cleaned_name}
          Available tools: #{available_tools}
        """)
        error_msg = "Tool not found: #{call.name}"
        {error_msg, %{}}
      end

    {Messages.tool_return(call.id, result), context_updates}
  end

  # Clean tool names - Claude sometimes uses XML-like syntax
  defp clean_tool_name(name) when is_binary(name) do
    name
    |> String.split("\"")
    |> List.first()
    |> String.trim()
  end

  defp build_initial_messages(state, prompt) do
    messages = []

    # Add instructions if present (with todo injection if enabled)
    messages =
      if state.agent.instructions do
        instructions =
          if is_function(state.agent.instructions) do
            # Dynamic instructions
            ctx = RunContext.new(state.deps)
            state.agent.instructions.(ctx)
          else
            # Static instructions
            state.agent.instructions
          end

        # Inject todos into instructions if enabled
        instructions_with_todos = if state.agent.enable_todos do
          inject_todos_into_prompt(instructions, state.deps)
        else
          instructions
        end

        [Messages.system_prompt(instructions_with_todos) | messages]
      else
        messages
      end

    # Add system prompt if present (in addition to instructions)
    messages =
      if state.agent.system_prompt do
        system_prompt =
          if is_function(state.agent.system_prompt) do
            ctx = RunContext.new(state.deps)
            state.agent.system_prompt.(ctx)
          else
            state.agent.system_prompt
          end

        [Messages.system_prompt(system_prompt) | messages]
      else
        messages
      end

    # Add message history
    messages = messages ++ state.message_history

    # Add user prompt
    messages = messages ++ [Messages.user_prompt(prompt)]

    Enum.reverse(messages)
  end

  defp extract_output(response, :string) do
    Messages.extract_text(response.parts)
  end

  defp extract_output(response, output_module) when is_atom(output_module) do
    # For structured outputs, look for tool call with schema
    # This is simplified - full implementation would use the output module
    # to validate and structure the data
    Messages.extract_text(response.parts)
  end

  # Convert tools to provider-specific format
  defp convert_tools_for_provider(:anthropic, tools) do
    # Anthropic uses atom keys and different format
    Enum.map(tools, &Yggdrasil.ToolSchema.to_anthropic/1)
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

      Logger.debug("Injecting #{length(todos)} todos into system prompt (in_progress: #{in_progress}, pending: #{pending}, completed: #{completed})")

      todo_section = format_todos_for_prompt(todos)

      """
      #{instructions}

      ## 📋 Current Task Progress

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
    sections = if length(in_progress) > 0 do
      in_progress_list = Enum.map_join(in_progress, "\n", fn todo ->
        priority_icon = priority_icon(todo.priority)
        "  #{priority_icon} [#{todo.id}] #{todo.text}"
      end)

      ["\n⏳ **In Progress** (#{length(in_progress)}):\n#{in_progress_list}" | sections]
    else
      sections
    end

    # Pending section
    sections = if length(pending) > 0 do
      pending_list = Enum.map_join(pending, "\n", fn todo ->
        priority_icon = priority_icon(todo.priority)
        "  #{priority_icon} [#{todo.id}] #{todo.text}"
      end)

      ["\n📝 **Pending** (#{length(pending)}):\n#{pending_list}" | sections]
    else
      sections
    end

    # Completed section
    sections = if length(completed) > 0 do
      completed_list = Enum.map_join(completed, "\n", fn todo ->
        "  ✓ [#{todo.id}] #{todo.text}"
      end)

      ["\n✅ **Completed** (#{length(completed)}):\n#{completed_list}" | sections]
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

  defp priority_icon("high"), do: "🔴"
  defp priority_icon("medium"), do: "🟡"
  defp priority_icon("low"), do: "🟢"
  defp priority_icon(_), do: "•"
end

defmodule Nous.AgentRunner.ToolExecution do
  @moduledoc false
  # Tool-call execution for Nous.AgentRunner: sequential and parallel
  # execution pipelines, pre/post hooks, approval and permission-policy
  # enforcement, and tool result recording. Internal to the runner.

  alias Nous.{CodeMode, Message, Messages, OutputSchema, Permissions, Spill, Tool, ToolExecutor}
  alias Nous.Agent.{Behaviour, Callbacks, Context}
  alias Nous.Hook

  require Logger

  # Outer ceiling (ms) for one parallel tool call whose tool declares no
  # timeout of its own. `Nous.Tool.t/0` permits `timeout: nil` and ToolExecutor
  # only arms its internal timer when `tool.timeout` is a positive number, so
  # nothing bounds such a call from the inside: a tool that hangs holds its
  # async_stream slot forever and wedges the entire agent run, with no
  # supervision escape. Five minutes is longer than any sane tool call yet
  # finite. Override with `config :nous, :parallel_tool_call_timeout_ms`.
  @default_call_timeout_ms :timer.minutes(5)

  # Slack (ms) added on top of a tool's own declared budget so the outer
  # ceiling never races ToolExecutor's timer. ToolExecutor re-raises
  # `ToolTimeout` into its retry path, so the inner timer must win and produce
  # a proper per-tool timeout result rather than an opaque outer task kill.
  @timeout_headroom_ms :timer.seconds(5)

  # Tools whose entire job is to hand back file bytes verbatim, and which must
  # therefore never have their results spilled. Spilling one builds a
  # read→spill→read loop: the model reads a file, gets a locator whose retrieval
  # hint says "read it with file_read", reads *that*, gets another locator over
  # the cap, forever. Search tools are deliberately absent — `file_grep` and
  # `file_glob` produce exactly the multi-megabyte digests spilling exists for,
  # and their output is a summary across many files, not one file to re-read.
  @never_spill_tools ~w(file_read)

  def handle_tool_calls(agent, behaviour, ctx, response, tools) do
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

        # Build run context for tool execution. This is the single construction
        # site for both the sequential and parallel paths below, so the session
        # sandbox policy only has to be attached here.
        run_ctx = Context.to_run_context(ctx, sandbox: agent.sandbox)

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
  def run_tool_calls_sequential(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    code_mode = CodeMode.resolve(agent)

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

        # Short-circuit on a tool_call whose arguments JSON failed to parse.
        # The provider marshalling tagged it with "_invalid_arguments" so we
        # surface a clean tool-error result and let the LLM retry — rather than
        # invoking the tool with bogus/empty args.
        invalid_args = invalid_arguments(call)

        cond do
          is_binary(invalid_args) ->
            result_msg = invalid_arguments_result(call_id, cleaned_name, invalid_args)
            {[result_msg | results], acc_ctx}

          CodeMode.collapsed?(code_mode, cleaned_name, call) ->
            {[code_mode_denial(call_id, cleaned_name) | results], acc_ctx}

          true ->
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
  #       async_stream preserves input order. The stream carries a finite
  #       per-call ceiling (batch_call_timeout/2) plus on_timeout: :kill_task.
  #       ToolExecutor's per-tool timeout is *not* always armed — tool.timeout
  #       is nil-able and only enforced when positive — so this outer bound is
  #       all that stops one hung tool from blocking the run forever.
  #   (c) post-stage, in original call order: post_tool_use hook,
  #       on_tool_response callback, behaviour :after_tool, merge_deps
  # Tools cannot observe each other's context updates within a turn in either
  # mode (run_ctx is snapshotted before the loop); what changes vs sequential
  # is only the interleaving of external side effects, and that pre-stage
  # hooks see the pre-turn ctx rather than earlier calls' post-stage effects.
  def run_tool_calls_parallel(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    decisions = Enum.map(real_calls, &pre_stage_decision(&1, tools, agent, ctx))

    approved = for {:execute, call} <- decisions, do: call

    call_timeout = batch_call_timeout(approved, tools)

    # Key executions by call id rather than relying on positional alignment
    # between `approved` and the async_stream output — robust to reordering and
    # to any future change in how the approved list is built. Provider tool_call
    # ids are unique within one response (they must be, to match tool results),
    # so a map keeps every result.
    executed_by_id =
      Nous.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        approved,
        fn call ->
          {get_tool_field(call, :id), execute_single_tool(tools, call, run_ctx, agent)}
        end,
        timeout: call_timeout,
        # Kill a task that blows the ceiling instead of blocking on it, so the
        # rest of the batch still drains.
        on_timeout: :kill_task,
        # Carry the input (call) on crash and timeout exits so failures keep
        # their attribution and surface as per-call tool errors.
        zip_input_on_exit: true
      )
      |> Map.new(fn
        {:ok, {call_id, {result_msg, context_updates}}} ->
          {call_id, {result_msg, context_updates}}

        {:exit, {call, :timeout}} ->
          {get_tool_field(call, :id), timed_out_tool_result(call, call_timeout)}

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

  # Per-call ceiling for the batch. async_stream applies one timeout to every
  # element, so take the largest budget in the batch: a shorter-lived tool is
  # still bounded from the inside by its own ToolExecutor timer.
  def batch_call_timeout(calls, tools) do
    calls
    |> Enum.map(&call_timeout_budget(&1, tools))
    |> Enum.max(fn -> default_call_timeout_ms() end)
  end

  def call_timeout_budget(call, tools) do
    name = clean_tool_name(get_tool_field(call, :name))

    case Enum.find(tools, fn t -> t.name == name end) do
      %Tool{timeout: timeout, retries: retries} when is_integer(timeout) and timeout > 0 ->
        # A timeout raised inside ToolExecutor goes through its retry path, so
        # the call may legitimately spend `timeout` ms on each of its
        # `retries + 1` attempts before it finally gives up.
        timeout * (retries + 1) + @timeout_headroom_ms

      _ ->
        # Unknown tool, or one declaring no timeout: nothing bounds it from the
        # inside, so the module default is the only budget it gets.
        default_call_timeout_ms()
    end
  end

  def default_call_timeout_ms do
    Application.get_env(:nous, :parallel_tool_call_timeout_ms, @default_call_timeout_ms)
  end

  # The outer ceiling fired and the task was killed mid-flight, so ToolExecutor
  # never got to raise its own ToolTimeout. Surface a readable per-call timeout
  # the model can route around, keeping this call's attribution intact.
  def timed_out_tool_result(call, timeout_ms) do
    call_id = get_tool_field(call, :id)
    cleaned_name = clean_tool_name(get_tool_field(call, :name))

    Logger.error("Tool '#{cleaned_name}' exceeded the #{timeout_ms}ms parallel execution ceiling")

    result_msg =
      Message.tool(
        call_id,
        "Tool execution timed out: #{cleaned_name} did not respond within #{timeout_ms}ms.",
        name: cleaned_name
      )

    {result_msg, %{}}
  end

  # Pre-execution stage for one call in parallel mode, mirroring the
  # run_tool_with_hooks branches up to (but not including) the execute step.
  # Returns {:done, result_msg} for short-circuits (invalid args, hook denial,
  # approval rejection) or {:execute, call} with final (possibly hook/approval
  # edited) arguments.
  def pre_stage_decision(call, tools, agent, ctx) do
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

    cond do
      is_binary(invalid_args) ->
        {:done, invalid_arguments_result(call_id, cleaned_name, invalid_args)}

      CodeMode.collapsed?(CodeMode.resolve(agent), cleaned_name, call) ->
        {:done, code_mode_denial(call_id, cleaned_name)}

      true ->
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

  def approval_decision(call, call_id, cleaned_name, tools, agent, ctx) do
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
  def crashed_tool_result(call, reason) do
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

  def invalid_arguments(call) do
    Map.get(call, "_invalid_arguments") || Map.get(call, :_invalid_arguments)
  end

  def invalid_arguments_result(call_id, cleaned_name, invalid_args) do
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
  def run_tool_with_hooks(
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
  def execute_and_record_tool(tools, call, run_ctx, behaviour, agent, acc_ctx) do
    {result_msg, context_updates} = execute_single_tool(tools, call, run_ctx, agent)
    record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx)
  end

  # Post-execution stage for one tool call: post_tool_use hook (may modify the
  # result), on_tool_response callback, behaviour :after_tool, merge_deps.
  # Shared by the sequential path (via execute_and_record_tool) and the
  # parallel path, which applies it in original call order after the fan-out.
  def record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx) do
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

  def execute_single_tool(tools, call, run_ctx, agent) do
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

    # Spill before the result becomes message content: this is the single point
    # where a completed tool result turns into a message, so the sequential and
    # the parallel path are both covered by one call.
    result = maybe_spill_result(result, cleaned_name, run_ctx, agent)

    {Message.tool(call_id, result, name: cleaned_name), context_updates}
  end

  # Hand an oversized text result to the spill store and keep a preview plus a
  # locator inline. Opt-in and best effort by construction:
  # `Nous.Spill.maybe_spill/2` answers `:inline` when no `deps[:spill_config]`
  # (or `config :nous, :spill`) is configured, when the result already fits,
  # when it is not valid UTF-8, and when the backend failed — so nothing here
  # can turn a successful tool call into an error.
  defp maybe_spill_result(result, tool_name, run_ctx, agent) when is_binary(result) do
    if tool_name in @never_spill_tools do
      result
    else
      opts = [
        ctx: run_ctx,
        source: tool_name,
        # Owner scopes stored content. `deps[:session_id]` is the key
        # `Nous.Sandbox.Policy.resolve/2` already reads for session identity, so
        # spilled files line up with the rest of a session's footprint; the
        # agent name is the coarser fallback for a run that carries no session
        # id, and `Nous.Spill` falls back to "unscoped" for an unnamed agent.
        owner: spill_owner(run_ctx) || agent.name,
        suggested_name: "#{tool_name}-result.txt"
      ]

      case Spill.maybe_spill(result, opts) do
        {:spilled, replacement, _locator} -> replacement
        :inline -> result
      end
    end
  end

  # Structured results (maps, lists, structs) are left alone: the provider
  # marshalling owns their encoding, and stringifying a term just to spill it
  # would change what the model sees.
  defp maybe_spill_result(result, _tool_name, _run_ctx, _agent), do: result

  # Binary-only, so a non-string session id can never reach the backend and
  # crash a tool call that otherwise succeeded.
  defp spill_owner(%{deps: %{session_id: session_id}}) when is_binary(session_id), do: session_id
  defp spill_owner(_run_ctx), do: nil

  # Format tool errors to preserve structured information while providing LLM-friendly response
  @spec format_tool_error(term(), String.t()) :: %{summary: String.t(), response: String.t()}
  def format_tool_error(error, tool_name) do
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

  # Convert ContextUpdate operations to a deps map for merging.
  #
  # `:append` previously did `existing ++ [item]`, which is O(n^2) over many
  # appends to the same key in one update. We prepend instead and reverse each
  # append-built key once at the end. `reversed` tracks keys whose stored list
  # is currently in reverse order; :set/:merge/:delete store forward-order
  # values and reset the flag — so a `:set [list]` then `:append` (the only
  # mixed case) still preserves exact insertion order. Result is byte-identical
  # to the old `++` reduce.
  def context_update_to_map(%Nous.Tool.ContextUpdate{operations: ops}) do
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
  def enforce_policy_approval(nil, _policy), do: nil
  def enforce_policy_approval(%Tool{} = tool, nil), do: tool

  def enforce_policy_approval(%Tool{requires_approval: true} = tool, _policy), do: tool

  def enforce_policy_approval(%Tool{} = tool, %Permissions.Policy{} = policy) do
    # Pass the tool's category so an :execute tool keeps its approval gate even
    # under :permissive (unless the policy opts into allow_unattended_execute).
    if Permissions.requires_approval?(policy, tool.name, tool.category) do
      %{tool | requires_approval: true}
    else
      tool
    end
  end

  # The tool set one model request may see, in two layers and deliberately in
  # this order:
  #
  #   1. the permission policy removes blocked tools, so the model never sees
  #      (and therefore cannot call) something it is not allowed to run;
  #   2. Code Mode injects `run_code` AFTER that filter.
  #
  # Injecting second is the point: `run_code` is Code Mode's only entry point,
  # and a restriction that deleted it would not restrict the agent, it would
  # mute it — a deny-all policy would leave a `mode: :code` agent with no tools
  # at all and no way to say so. It is not a hole either: `run_code` still
  # dispatches through the whole pipeline (hooks, approval, permission
  # plugins), so a guard can inspect the program text before it runs, and every
  # tool the program itself calls is filtered by the same policy through
  # `Nous.CodeMode.bindings/4`.
  def visible_tools(agent, tools) do
    granted = maybe_filter_by_policy(agent.permissions, tools)

    CodeMode.visible_tools(CodeMode.resolve(agent), tools, granted, policy: agent.permissions)
  end

  def maybe_filter_by_policy(nil, tools), do: tools

  def maybe_filter_by_policy(%Permissions.Policy{} = policy, tools) do
    Permissions.filter_tools(policy, tools)
  end

  # Under `mode: :code` the model was shown exactly one tool, so a call to any
  # other one can only fail. Refusing it here — before the pre_tool_use hook —
  # keeps guards from being asked to approve a call that cannot execute.
  defp code_mode_denial(call_id, cleaned_name) do
    Logger.info("Tool '#{cleaned_name}' is not callable directly under code mode")

    Message.tool(call_id, CodeMode.collapse_message(cleaned_name), name: cleaned_name)
  end

  # Check if a tool call requires approval and invoke the handler.
  #
  # Default-deny: a tool with `requires_approval: true` but no
  # `ctx.approval_handler` is REJECTED, not approved. The previous behaviour
  # auto-approved in this case, which made the requires_approval flag a
  # silent no-op for the default Agent setup - one prompt-injected document
  # away from RCE on tools like Bash/FileWrite.
  def check_tool_approval(nil, _call, _ctx), do: :approve

  def check_tool_approval(%Tool{requires_approval: true} = tool, call, %Context{
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

  def check_tool_approval(%Tool{requires_approval: true} = tool, call, _ctx) do
    Logger.warning(
      "Tool '#{tool.name}' has requires_approval: true but no :approval_handler is configured " <>
        "in ctx. Rejecting call (id=#{inspect(get_tool_field(call, :id))}). " <>
        "Wire an approval_handler to allow these tools."
    )

    :reject
  end

  def check_tool_approval(_tool, _call, _ctx), do: :approve

  # Tool call fields arrive with atom OR string keys depending on the
  # provider; Nous.ToolCall resolves both without coalescing falsy values.
  def get_tool_field(call, field), do: Nous.ToolCall.field(call, field)

  def put_tool_field(call, field, value), do: Nous.ToolCall.put_field(call, field, value)

  # Clean tool names - Claude sometimes uses XML-like syntax.
  # L-9: tolerate nil/non-binary input - some providers emit malformed
  # function-call responses with no name; without these clauses
  # clean_tool_name/1 would crash the entire agent run with FunctionClauseError.
  def clean_tool_name(nil), do: ""
  def clean_tool_name(name) when not is_binary(name), do: ""

  def clean_tool_name(name) when is_binary(name) do
    name
    |> String.split("\"")
    |> List.first()
    |> String.trim()
  end
end

defmodule Nous.AgentRunner.ToolExecution do
  @moduledoc false
  # Tool-call execution for Nous.AgentRunner: the pipeline one turn's tool
  # calls go through — pre-stage (callback, invalid-args short-circuit, Code
  # Mode collapse, pre_tool_use hook, approval), execution in call order or
  # fanned out, and the post stage (post_tool_use hook, callbacks, behaviour,
  # context update). Running one call and shaping its result is
  # `Nous.AgentRunner.ToolInvocation`. Internal to the runner.

  alias Nous.{CodeMode, Message, Messages, OutputSchema, Permissions, Tool, ToolCall}
  alias Nous.Agent.{Behaviour, Callbacks, Context}
  alias Nous.AgentRunner.ToolInvocation
  alias Nous.Hook
  alias Nous.Tool.ContextUpdate

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

  def handle_tool_calls(agent, behaviour, ctx, response, tools) do
    # Extract tool calls
    tool_calls = Messages.extract_tool_calls([response])

    if Enum.empty?(tool_calls) do
      ctx
    else
      # Separate synthetic structured output calls from real tool calls
      {_synthetic_calls, real_calls} =
        Enum.split_with(tool_calls, fn call ->
          name = ToolCall.field(call, :name)
          OutputSchema.synthetic_tool_name?(name || "")
        end)

      if Enum.empty?(real_calls) do
        # Only synthetic calls — structured output will be extracted by extract_output.
        # Don't execute them as tools; just stop the loop.
        Context.set_needs_response(ctx, false)
      else
        # Update usage to track tool calls
        ctx = Context.add_usage(ctx, %{tool_calls: length(real_calls)})

        tool_names = Enum.map_join(real_calls, ", ", &ToolCall.field(&1, :name))
        Logger.debug("Detected #{length(real_calls)} tool call(s): #{tool_names}")

        # Build run context for tool execution. This is the single construction
        # site for both the sequential and parallel paths below, so the session
        # sandbox and permission policies only have to be attached here.
        run_ctx =
          Context.to_run_context(ctx, sandbox: agent.sandbox, permissions: agent.permissions)

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
  # and approval checks observe call N's context effects — the pre-stage runs
  # against the accumulating context, not the pre-turn snapshot.
  def run_tool_calls_sequential(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    code_mode = CodeMode.resolve(agent)

    {results, ctx} =
      Enum.reduce(real_calls, {[], ctx}, fn call, {results, acc_ctx} ->
        {result_msg, acc_ctx} =
          case pre_stage_decision(call, tools, code_mode, agent, acc_ctx) do
            {:done, result_msg} ->
              {result_msg, acc_ctx}

            {:execute, call} ->
              {result_msg, context_updates} = ToolInvocation.invoke(tools, call, run_ctx, agent)
              record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx)
          end

        {[result_msg | results], acc_ctx}
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
    code_mode = CodeMode.resolve(agent)
    decisions = Enum.map(real_calls, &pre_stage_decision(&1, tools, code_mode, agent, ctx))

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
          {ToolCall.field(call, :id), ToolInvocation.invoke(tools, call, run_ctx, agent)}
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
          {ToolCall.field(call, :id), ToolInvocation.timed_out(call, call_timeout)}

        {:exit, {call, reason}} ->
          {ToolCall.field(call, :id), ToolInvocation.crashed(call, reason)}
      end)

    {results, ctx} =
      Enum.reduce(decisions, {[], ctx}, fn
        {:done, result_msg}, {results, acc_ctx} ->
          {[result_msg | results], acc_ctx}

        {:execute, call}, {results, acc_ctx} ->
          {result_msg, context_updates} = Map.fetch!(executed_by_id, ToolCall.field(call, :id))

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
    name = ToolCall.clean_name(ToolCall.field(call, :name))

    case Enum.find(tools, fn t -> t.name == name end) do
      %Tool{timeout: timeout, retries: retries} when is_integer(timeout) and timeout > 0 ->
        # A timeout is terminal in ToolExecutor, but an ordinary failure still
        # retries and can arrive a millisecond under the deadline, so the call
        # may legitimately spend `timeout` ms on each of its `retries + 1`
        # attempts before it finally gives up.
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

  # Pre-execution stage for one call, shared by both modes: on_tool_call
  # callback, invalid-args short-circuit, Code Mode collapse, pre_tool_use
  # hook, approval. Returns {:done, result_msg} for a short-circuit (invalid
  # args, collapse, hook denial, approval rejection) or {:execute, call} with
  # the final — possibly hook- or approval-edited — arguments. `ctx` is the
  # context whose hook registry and approval handler the call is judged
  # against: the accumulating one in sequential mode, the pre-turn snapshot in
  # parallel mode.
  def pre_stage_decision(call, tools, code_mode, agent, ctx) do
    call_name = ToolCall.field(call, :name)
    call_id = ToolCall.field(call, :id)
    call_arguments = ToolCall.field(call, :arguments)
    cleaned_name = ToolCall.clean_name(call_name)

    Callbacks.execute(ctx, :on_tool_call, %{
      id: call_id,
      name: call_name,
      arguments: call_arguments
    })

    # A call whose arguments JSON failed to parse was tagged by the provider
    # marshalling; it never reaches a tool.
    invalid_args = ToolCall.field(call, :_invalid_arguments)

    cond do
      is_binary(invalid_args) ->
        {:done, ToolInvocation.invalid_arguments(call_id, cleaned_name, invalid_args)}

      CodeMode.collapsed?(code_mode, cleaned_name, call) ->
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
            # The approval gate runs on the modified call exactly as on an
            # untouched one: a tool gated ONLY by the permission policy (strict
            # mode / approval_required / execute-category) must not execute
            # ungated because a hook rewrote its arguments.
            modified_call = ToolCall.put_field(call, :arguments, new_args)
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
      |> Permissions.enforce_approval(agent.permissions)

    case check_tool_approval(tool, call, ctx) do
      :reject ->
        Logger.info("Tool '#{cleaned_name}' rejected by approval handler")

        {:done,
         Message.tool(call_id, "Tool call was rejected by approval handler.", name: cleaned_name)}

      {:edit, new_args} ->
        Logger.debug("Tool '#{cleaned_name}' arguments edited by approval handler")
        {:execute, ToolCall.put_field(call, :arguments, new_args)}

      :approve ->
        {:execute, call}
    end
  end

  # Post-execution stage for one tool call: post_tool_use hook (may modify the
  # result), on_tool_response callback, behaviour :after_tool, and the tool's
  # context update. Shared by both modes; the parallel path applies it in
  # original call order after the fan-out.
  #
  # This is also the only stage on the tool path that holds a
  # `%Nous.Agent.Context{}`, and therefore the only place a `:log_event`
  # operation can reach a session log.
  def record_tool_result(call, result_msg, context_update, behaviour, agent, acc_ctx) do
    call_name = ToolCall.field(call, :name)
    call_id = ToolCall.field(call, :id)
    call_arguments = ToolCall.field(call, :arguments)
    cleaned_name = ToolCall.clean_name(call_name)

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

    acc_ctx = apply_tool_context_update(acc_ctx, context_update)

    {result_msg, acc_ctx}
  end

  # Apply a tool's context update to the accumulating agent context.
  #
  # Two shapes arrive here: a `%ContextUpdate{}` from a structured tool return,
  # and a plain deps map from the legacy `__update_context__` path (or `%{}`
  # from a tool, timeout or crash that updated nothing).
  #
  # The struct clause MUST stay first. A struct is a map, so an `is_map/1`
  # clause above it would swallow every `%ContextUpdate{}` and silently drop
  # its events — the exact failure mode this change exists to remove.
  defp apply_tool_context_update(acc_ctx, %ContextUpdate{} = update) do
    # One reducer for the operation list — `ContextUpdate.to_deps/1` — so this
    # cannot drift from `ContextUpdate.apply/2` the way a second fold here did.
    acc_ctx
    |> merge_tool_deps(ContextUpdate.to_deps(update))
    |> log_tool_events(ContextUpdate.log_events(update))
  end

  defp apply_tool_context_update(acc_ctx, deps) when is_map(deps) do
    merge_tool_deps(acc_ctx, deps)
  end

  # Deps merge exactly as before: the update is folded from an EMPTY map and
  # the result merged over the context. Folding from `acc_ctx.deps` instead
  # (what `ContextUpdate.apply/2` does) would quietly redefine `:append` and
  # `:delete` for every tool already shipping, so that stays a separate
  # decision from this one.
  defp merge_tool_deps(acc_ctx, deps) when map_size(deps) == 0, do: acc_ctx

  defp merge_tool_deps(acc_ctx, deps) do
    Logger.debug("Merging context updates: #{inspect(Map.keys(deps))}")
    Context.merge_deps(acc_ctx, deps)
  end

  # Bookkeeping events, in the order the tool added them. `Context.log_event/3`
  # projects them to no message, so an auditable side effect is recorded
  # without entering the model's history — and it refuses surface types, so a
  # tool cannot use this to write into the transcript.
  defp log_tool_events(acc_ctx, events) do
    Enum.reduce(events, acc_ctx, fn {type, data}, ctx ->
      Context.log_event(ctx, type, data)
    end)
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
    granted = Permissions.filter_tools(agent.permissions, tools)

    CodeMode.visible_tools(CodeMode.resolve(agent), tools, granted, policy: agent.permissions)
  end

  # The policy filter itself lives in Nous.Permissions (nil-tolerant); what
  # stays here is only the composition with Code Mode's injection above.

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
  # away from RCE on tools like Bash/FileWrite. The handler's answer is
  # interpreted by `Nous.Permissions.consult_handler/2`, the same place
  # `Nous.ToolExecutor` uses, so the two gates cannot drift.
  def check_tool_approval(nil, _call, _ctx), do: :approve

  def check_tool_approval(%Tool{requires_approval: true} = tool, call, %Context{
        approval_handler: handler
      })
      when is_function(handler, 1) do
    Permissions.consult_handler(handler, %{
      name: ToolCall.field(call, :name),
      id: ToolCall.field(call, :id),
      arguments: ToolCall.field(call, :arguments),
      tool: tool
    })
  end

  def check_tool_approval(%Tool{requires_approval: true} = tool, call, _ctx) do
    Logger.warning(
      "Tool '#{tool.name}' has requires_approval: true but no :approval_handler is configured " <>
        "in ctx. Rejecting call (id=#{inspect(ToolCall.field(call, :id))}). " <>
        "Wire an approval_handler to allow these tools."
    )

    :reject
  end

  def check_tool_approval(_tool, _call, _ctx), do: :approve
end

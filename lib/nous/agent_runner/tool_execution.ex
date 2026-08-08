defmodule Nous.AgentRunner.ToolExecution do
  @moduledoc false
  # Tool-call execution for Nous.AgentRunner: sequential and parallel
  # execution pipelines, pre/post hooks, approval and permission-policy
  # enforcement, and tool result recording. Internal to the runner, with one
  # exception: `execute_single_tool/3` is the library's only tool executor and
  # `Nous.LLM`'s lighter loop calls it directly. Keep its contract
  # (`{result_message, context_updates}`, no %Context{} needed) stable.

  alias Nous.{Message, Messages, OutputSchema, Permissions, RunContext, Tool, ToolExecutor}
  alias Nous.Agent
  alias Nous.Agent.{Behaviour, Callbacks, Context}
  alias Nous.Hook
  alias Nous.Tool.ContextUpdate

  require Logger

  # A provider tool_call. Keys arrive as atoms or strings depending on the
  # provider, so get_tool_field/2 is the only safe accessor.
  @type tool_call :: map()

  # What one executed tool hands back: the tool-result message bound for the
  # model, plus the deps updates to merge into the context. `Nous.LLM` matches
  # on this shape too — see the moduledoc.
  @type tool_outcome :: {Message.t(), map()}

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

  # Fan-out width for the parallel tool-call batch. async_stream defaults to
  # System.schedulers_online(), which answers the wrong question here: a tool
  # call is a network or disk wait, not CPU work, so the scheduler count
  # throttles concurrency by a resource nothing in the batch is contending
  # for. On a 2-vCPU container two HTTP tools serialize for no reason; on a
  # 64-core box the same default would let a batch fan out 64-wide.
  #
  # 16 covers every realistic batch — a provider emits a handful of tool calls
  # per response, and the tools themselves are bounded downstream (Finch pools
  # per host, ToolExecutor's per-tool timeout) — while keeping the fan-out a
  # fixed, machine-independent number. It should stay well under
  # :task_supervisor_max_children: a batch that cannot claim a slot is refused,
  # not queued, and fan_out/5 turns that refusal into tool errors for the
  # whole batch.
  #
  # Override with `config :nous, :parallel_tool_call_max_concurrency`.
  @default_max_concurrency 16

  @spec handle_tool_calls(Agent.t(), module(), Context.t(), Message.t(), [Tool.t()]) ::
          Context.t()
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
        execute_real_tool_calls(agent, behaviour, ctx, real_calls, tools)
      end
    end
  end

  # Run the turn's real tool calls — fanned out or sequential — then append
  # their result messages and record the calls on the context. Split out of
  # handle_tool_calls/5 so neither body nests past the flattening threshold.
  defp execute_real_tool_calls(agent, behaviour, ctx, real_calls, tools) do
    # Update usage to track tool calls
    ctx = Context.add_usage(ctx, %{tool_calls: length(real_calls)})

    tool_names = Enum.map_join(real_calls, ", ", &get_tool_field(&1, :name))
    Logger.debug("Detected #{length(real_calls)} tool call(s): #{tool_names}")

    # Build run context for tool execution. `approval_gated?: true` is the
    # runner asserting that check_tool_approval/3 below runs the full
    # approval + permission-policy pipeline for every call, so ToolExecutor
    # must not prompt the operator a second time. No other caller may assert
    # it; to_run_context/1 defaults to ungated.
    run_ctx = Context.to_run_context(ctx, approval_gated?: true)

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

  # Sequential tool-call execution (the default): each call runs its full
  # pre/execute/post pipeline before the next call starts, so call N+1's hooks
  # and approval checks observe call N's context effects.
  #
  # The pre-stage is pre_stage_decision/4, shared with the parallel path.
  # The sequential copy that used to live here — an 11-parameter
  # run_tool_with_hooks/11 — had already drifted: it logged neither the
  # rejection nor the argument edit when a `{:modify, _}` hook preceded the
  # approval check. Threading `acc_ctx` into the shared pre-stage keeps the
  # sequential guarantee intact: hooks and the approval handler still observe
  # every earlier call's context effects.
  @spec run_tool_calls_sequential(
          [tool_call()],
          [Tool.t()],
          RunContext.t(),
          module(),
          Agent.t(),
          Context.t()
        ) :: {[Message.t()], Context.t()}
  def run_tool_calls_sequential(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    {results, ctx} =
      Enum.reduce(real_calls, {[], ctx}, fn call, {results, acc_ctx} ->
        case pre_stage_decision(call, tools, agent, acc_ctx) do
          {:done, result_msg} ->
            {[result_msg | results], acc_ctx}

          {:execute, approved_call} ->
            {result_msg, acc_ctx} =
              execute_and_record_tool(tools, approved_call, run_ctx, behaviour, agent, acc_ctx)

            {[result_msg | results], acc_ctx}
        end
      end)

    {Enum.reverse(results), ctx}
  end

  # Parallel tool-call execution (agent.parallel_tool_calls). Three stages keep
  # hook/approval/post-processing semantics sequential while only the approved
  # executions fan out:
  #   (a) pre-stage, in call order: on_tool_call callback, invalid-args
  #       short-circuit, pre_tool_use hook, approval check
  #   (b) approved calls execute concurrently under Nous.TaskSupervisor, at
  #       most max_concurrency/0 at a time; async_stream preserves input
  #       order. The stream carries a finite per-call ceiling
  #       (batch_call_timeout/2) plus on_timeout: :kill_task.
  #       ToolExecutor's per-tool timeout is *not* always armed — tool.timeout
  #       is nil-able and only enforced when positive — so this outer bound is
  #       all that stops one hung tool from blocking the run forever.
  #   (c) post-stage, in original call order: post_tool_use hook,
  #       on_tool_response callback, behaviour :after_tool, merge_deps
  # Tools cannot observe each other's context updates within a turn in either
  # mode (run_ctx is snapshotted before the loop); what changes vs sequential
  # is only the interleaving of external side effects, and that pre-stage
  # hooks see the pre-turn ctx rather than earlier calls' post-stage effects.
  @spec run_tool_calls_parallel(
          [tool_call()],
          [Tool.t()],
          RunContext.t(),
          module(),
          Agent.t(),
          Context.t()
        ) :: {[Message.t()], Context.t()}
  def run_tool_calls_parallel(real_calls, tools, run_ctx, behaviour, agent, ctx) do
    decisions = Enum.map(real_calls, &pre_stage_decision(&1, tools, agent, ctx))

    approved = for {:execute, call} <- decisions, do: call

    call_timeout = batch_call_timeout(approved, tools)

    # async_stream_nolink does not link the fan-out tasks to this process — a
    # crashing tool must not take the run down — which also means they outlive
    # it. Without the reaper in fan_out/5, cancelling a run (or the outer
    # ceiling killing this process) left one task per in-flight call still
    # executing its tool, and each of those in turn held an unreaped
    # ToolExecutor process.
    runner = self()

    executed_by_id =
      case fan_out(approved, tools, run_ctx, runner, call_timeout) do
        {:ok, executed} -> executed
        {:error, :saturated} -> saturated_results(approved)
      end

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

  # Runs the approved calls concurrently, or reports that the node had no room
  # for them.
  #
  # Deliberately NOT Nous.Tasks.stream/3, which degrades a refused fan-out to
  # sequential execution: that path has no task to kill, so it cannot enforce
  # `call_timeout`, and an unbounded tool call is precisely what that ceiling
  # exists to contain — one hung tool would wedge the whole agent run. Answering
  # per call is the better degradation here anyway, because the model can read a
  # tool error and route around it, which is how the rest of the library answers
  # exhaustion (Nous.Tools.WebFetch returns "Too many concurrent web fetches"
  # when every pinned pool slot is taken).
  #
  # The batch, not the individual call, is the unit that degrades: Elixir shuts
  # the whole stream down before raising, so every RESULT already produced is
  # gone by the time we see it. Note that this is true of results only — a call
  # that had already reached its tool keeps whatever effect it caused, which is
  # why saturated_tool_result/1 must not promise the model that nothing ran.
  defp fan_out(approved, tools, run_ctx, runner, call_timeout) do
    with {:ok, results} <-
           Nous.Tasks.async_stream_nolink(
             approved,
             fn call ->
               ToolExecutor.reap_on_caller_exit(runner)
               {get_tool_field(call, :id), execute_single_tool(tools, call, run_ctx)}
             end,
             # Explicit because the default is System.schedulers_online() — see
             # @default_max_concurrency.
             max_concurrency: max_concurrency(),
             timeout: call_timeout,
             # Kill a task that blows the ceiling instead of blocking on it, so
             # the rest of the batch still drains.
             on_timeout: :kill_task,
             # Carry the input (call) on crash and timeout exits so failures keep
             # their attribution and surface as per-call tool errors.
             zip_input_on_exit: true
           ) do
      # Key executions by call id rather than relying on positional alignment
      # between `approved` and the async_stream output — robust to reordering and
      # to any future change in how the approved list is built. Provider
      # tool_call ids are unique within one response (they must be, to match tool
      # results), so a map keeps every result.
      {:ok,
       Map.new(results, fn
         {:ok, {call_id, {result_msg, context_updates}}} ->
           {call_id, {result_msg, context_updates}}

         {:exit, {call, :timeout}} ->
           {get_tool_field(call, :id), timed_out_tool_result(call, call_timeout)}

         {:exit, {call, reason}} ->
           {get_tool_field(call, :id), crashed_tool_result(call, reason)}
       end)}
    end
  end

  defp saturated_results(approved) do
    Nous.Tasks.warn_saturated("#{length(approved)} tool call(s)")

    Map.new(approved, fn call ->
      {get_tool_field(call, :id), saturated_tool_result(call)}
    end)
  end

  # Mirrors timed_out_tool_result/2: a readable, per-call result the model can
  # route around, keeping this call's attribution intact.
  @spec saturated_tool_result(tool_call()) :: tool_outcome()
  def saturated_tool_result(call) do
    call_id = get_tool_field(call, :id)
    cleaned_name = clean_tool_name(get_tool_field(call, :name))

    result_msg =
      Message.tool(
        call_id,
        "Tool execution unavailable: the node is at its concurrent-task ceiling. " <>
          "Retry #{cleaned_name} shortly.",
        name: cleaned_name
      )

    {result_msg, %{}}
  end

  # Per-call ceiling for the batch. async_stream applies one timeout to every
  # element, so take the largest budget in the batch: a shorter-lived tool is
  # still bounded from the inside by its own ToolExecutor timer.
  @spec batch_call_timeout([tool_call()], [Tool.t()]) :: timeout()
  def batch_call_timeout(calls, tools) do
    calls
    |> Enum.map(&call_timeout_budget(&1, tools))
    |> Enum.max(fn -> default_call_timeout_ms() end)
  end

  @spec call_timeout_budget(tool_call(), [Tool.t()]) :: timeout()
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

  @spec default_call_timeout_ms() :: timeout()
  def default_call_timeout_ms do
    Application.get_env(:nous, :parallel_tool_call_timeout_ms, @default_call_timeout_ms)
  end

  @spec max_concurrency() :: pos_integer()
  def max_concurrency do
    Application.get_env(:nous, :parallel_tool_call_max_concurrency, @default_max_concurrency)
  end

  # The outer ceiling fired and the task was killed mid-flight, so ToolExecutor
  # never got to raise its own ToolTimeout. Surface a readable per-call timeout
  # the model can route around, keeping this call's attribution intact.
  @spec timed_out_tool_result(tool_call(), timeout()) :: tool_outcome()
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

  # Pre-execution stage for one call, shared by the sequential and the parallel
  # path: on_tool_call callback, invalid-args short-circuit, pre_tool_use hook,
  # approval check. Returns {:done, result_msg} for short-circuits (invalid
  # args, hook denial, approval rejection) or {:execute, call} with final
  # (possibly hook/approval edited) arguments. `ctx` is whichever context the
  # caller wants the hooks to see: the sequential path threads the accumulated
  # one, the parallel path snapshots the pre-turn one.
  @spec pre_stage_decision(tool_call(), [Tool.t()], Agent.t(), Context.t()) ::
          {:done, Message.t()} | {:execute, tool_call()}
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

  @spec approval_decision(
          tool_call(),
          term(),
          String.t(),
          [Tool.t()],
          Agent.t(),
          Context.t()
        ) :: {:done, Message.t()} | {:execute, tool_call()}
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
  @spec crashed_tool_result(tool_call(), term()) :: tool_outcome()
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

  # The raw `_invalid_arguments` tag, straight off an unvalidated provider map:
  # callers MUST guard with is_binary/1 rather than trust the shape.
  @spec invalid_arguments(tool_call()) :: term()
  def invalid_arguments(call) do
    Map.get(call, "_invalid_arguments") || Map.get(call, :_invalid_arguments)
  end

  @spec invalid_arguments_result(term(), String.t(), String.t()) :: Message.t()
  def invalid_arguments_result(call_id, cleaned_name, invalid_args) do
    Logger.warning("Tool '#{cleaned_name}' called with malformed arguments JSON: #{invalid_args}")

    Message.tool(
      call_id,
      "Error: tool arguments were not valid JSON. Please retry with a JSON object.",
      name: cleaned_name
    )
  end

  # Execute a tool call and record its result, returning the result message and updated context
  @spec execute_and_record_tool(
          [Tool.t()],
          tool_call(),
          RunContext.t(),
          module(),
          Agent.t(),
          Context.t()
        ) :: {Message.t(), Context.t()}
  def execute_and_record_tool(tools, call, run_ctx, behaviour, agent, acc_ctx) do
    {result_msg, context_updates} = execute_single_tool(tools, call, run_ctx)
    record_tool_result(call, result_msg, context_updates, behaviour, agent, acc_ctx)
  end

  # Post-execution stage for one tool call: post_tool_use hook (may modify the
  # result), on_tool_response callback, behaviour :after_tool, merge_deps.
  # Shared by the sequential path (via execute_and_record_tool) and the
  # parallel path, which applies it in original call order after the fan-out.
  @spec record_tool_result(
          tool_call(),
          Message.t(),
          map(),
          module(),
          Agent.t(),
          Context.t()
        ) :: {Message.t(), Context.t()}
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
        # merge_tool_deps/2, not merge_deps/2: `context_updates` is tool output
        # (including the untyped legacy `__update_context__` map), so it must not
        # be able to rewrite security-bearing deps keys.
        Context.merge_tool_deps(acc_ctx, context_updates)
      else
        acc_ctx
      end

    {result_msg, acc_ctx}
  end

  @spec execute_single_tool([Tool.t()], tool_call(), RunContext.t()) :: tool_outcome()
  def execute_single_tool(tools, call, run_ctx) do
    # Clean up tool name - Claude sometimes adds XML-like syntax
    call_name = get_tool_field(call, :name)
    call_id = get_tool_field(call, :id)
    call_arguments = get_tool_field(call, :arguments)
    cleaned_name = clean_tool_name(call_name)

    {result, context_updates} =
      case Enum.find(tools, fn t -> t.name == cleaned_name end) do
        nil -> tool_not_found_result(tools, call_name, cleaned_name)
        tool -> run_tool(tool, call_arguments, run_ctx, cleaned_name)
      end

    {Message.tool(call_id, result, name: cleaned_name), context_updates}
  end

  # Run the resolved tool and reduce its outcome to `{result, context_updates}`.
  # Extracted from execute_single_tool/3 only to keep the branches flat — the
  # `{result_message, context_updates}` contract Nous.LLM depends on is still
  # assembled by the caller, unchanged.
  defp run_tool(tool, call_arguments, run_ctx, cleaned_name) do
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

        # Extract context updates if present (only for map results).
        # This handles the legacy __update_context__ pattern.
        split_legacy_context_updates(result, cleaned_name)

      {:error, error} ->
        # Preserve structured error information for better debugging and handling
        error_details = format_tool_error(error, cleaned_name)
        Logger.error("Tool '#{cleaned_name}' execution failed: #{error_details.summary}")
        {error_details.response, %{}}
    end
  end

  # Legacy `__update_context__` pattern: a map result may carry context updates
  # under that key, and it must be stripped before the result goes back to the
  # model. Non-map results (strings, numbers, etc.) have no context updates.
  defp split_legacy_context_updates(result, cleaned_name) when is_map(result) do
    updates = Map.get(result, :__update_context__, %{})

    if map_size(updates) > 0 do
      Logger.debug(
        "Tool '#{cleaned_name}' returned context updates: #{inspect(Map.keys(updates))}"
      )
    end

    {Map.delete(result, :__update_context__), updates}
  end

  defp split_legacy_context_updates(result, _cleaned_name), do: {result, %{}}

  # Nothing in `tools` answers to the name the model asked for. Log what WAS
  # available and hand the model back the raw name it used, not the cleaned one.
  defp tool_not_found_result(tools, call_name, cleaned_name) do
    available_tools = Enum.map_join(tools, ", ", & &1.name)

    Logger.error("""
    Tool not found: #{call_name}
      Cleaned name: #{cleaned_name}
      Available tools: #{available_tools}
    """)

    {"Tool not found: #{call_name}", %{}}
  end

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
  @spec context_update_to_map(ContextUpdate.t()) :: map()
  def context_update_to_map(%ContextUpdate{operations: ops}) do
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
  @spec enforce_policy_approval(Tool.t() | nil, Permissions.Policy.t() | nil) :: Tool.t() | nil
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

  @spec maybe_filter_by_policy(Permissions.Policy.t() | nil, [Tool.t()]) :: [Tool.t()]
  def maybe_filter_by_policy(nil, tools), do: tools

  def maybe_filter_by_policy(%Permissions.Policy{} = policy, tools) do
    Permissions.filter_tools(policy, tools)
  end

  # Check if a tool call requires approval and invoke the handler.
  #
  # Default-deny: a tool with `requires_approval: true` but no
  # `ctx.approval_handler` is REJECTED, not approved. The previous behaviour
  # auto-approved in this case, which made the requires_approval flag a
  # silent no-op for the default Agent setup - one prompt-injected document
  # away from RCE on tools like Bash/FileWrite.
  @spec check_tool_approval(Tool.t() | nil, tool_call(), Context.t()) ::
          RunContext.approval_decision()
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
  @spec get_tool_field(tool_call(), atom()) :: term()
  def get_tool_field(call, field), do: Nous.ToolCall.field(call, field)

  @spec put_tool_field(tool_call(), atom(), term()) :: tool_call()
  def put_tool_field(call, field, value), do: Nous.ToolCall.put_field(call, field, value)

  # Clean tool names - Claude sometimes uses XML-like syntax.
  # L-9: tolerate nil/non-binary input - some providers emit malformed
  # function-call responses with no name; without these clauses
  # clean_tool_name/1 would crash the entire agent run with FunctionClauseError.
  @spec clean_tool_name(term()) :: String.t()
  def clean_tool_name(nil), do: ""
  def clean_tool_name(name) when not is_binary(name), do: ""

  def clean_tool_name(name) when is_binary(name) do
    name
    |> String.split("\"")
    |> List.first()
    |> String.trim()
  end
end

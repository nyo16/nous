defmodule Nous.AgentRunner.ToolInvocation do
  @moduledoc false
  # One tool call in, one tool result message out. Owns the step between
  # `Nous.AgentRunner.ToolExecution`'s pipeline (hooks, approval, ordering,
  # fan-out) and `Nous.ToolExecutor`: dispatch, result normalisation, error
  # formatting, spilling, and the failure shapes a parallel batch can produce
  # outside the executor (an outer timeout, a task exit). Internal to the
  # runner.
  #
  # Every function here returns `{Message.t(), context_update}`: the message
  # the model sees and whatever the tool asked to change, untouched, for the
  # post stage that holds a `%Nous.Agent.Context{}` to apply.

  alias Nous.{Errors, Message, Spill, ToolCall, ToolExecutor}
  alias Nous.Tool.ContextUpdate

  require Logger

  # Tools whose entire job is to hand back file bytes verbatim, and which must
  # therefore never have their results spilled. Spilling one builds a
  # read→spill→read loop: the model reads a file, gets a locator whose retrieval
  # hint says "read it with file_read", reads *that*, gets another locator over
  # the cap, forever. Search tools are deliberately absent — `file_grep` and
  # `file_glob` produce exactly the multi-megabyte digests spilling exists for,
  # and their output is a summary across many files, not one file to re-read.
  @never_spill_tools ~w(file_read)

  @type outcome :: {Message.t(), ContextUpdate.t() | map()}

  @doc false
  @spec invoke([Nous.Tool.t()], map(), Nous.RunContext.t(), Nous.Agent.t()) :: outcome()
  def invoke(tools, call, run_ctx, agent) do
    call_name = ToolCall.field(call, :name)
    call_id = ToolCall.field(call, :id)
    call_arguments = ToolCall.field(call, :arguments)
    cleaned_name = ToolCall.clean_name(call_name)

    {result, context_updates} =
      case Enum.find(tools, fn t -> t.name == cleaned_name end) do
        nil -> not_found(tools, call_name, cleaned_name)
        tool -> execute(tool, call_arguments, run_ctx, cleaned_name)
      end

    # Spill before the result becomes message content: this is the single point
    # where a completed tool result turns into a message, so the sequential and
    # the parallel path are both covered by one call.
    result = maybe_spill_result(result, cleaned_name, run_ctx, agent)

    {Message.tool(call_id, result, name: cleaned_name), context_updates}
  end

  defp execute(tool, arguments, run_ctx, cleaned_name) do
    case ToolExecutor.execute(tool, arguments, run_ctx) do
      # Hand the whole update to the post stage instead of folding it to a
      # deps map here: a `:log_event` operation needs the
      # `%Nous.Agent.Context{}` only `ToolExecution.record_tool_result/6`
      # holds, and folding early is precisely what used to throw those events
      # away.
      {:ok, result, %ContextUpdate{} = update} ->
        Logger.debug(
          "Tool '#{cleaned_name}' executed successfully with " <>
            "#{length(ContextUpdate.operations(update))} context operation(s)"
        )

        {result, update}

      {:ok, result} ->
        Logger.debug("Tool '#{cleaned_name}' executed successfully")
        split_legacy_update(result, cleaned_name)

      {:error, error} ->
        # Preserve structured error information for better debugging and handling
        error_details = Errors.ToolError.format_for_model(error, cleaned_name)
        Logger.error("Tool '#{cleaned_name}' execution failed: #{error_details.summary}")
        {error_details.response, %{}}
    end
  end

  # The legacy `__update_context__` pattern: a map result may carry its context
  # updates inline. They are stripped before the result reaches the model.
  # Non-map results (strings, numbers, etc.) have no context updates.
  defp split_legacy_update(result, cleaned_name) when is_map(result) do
    updates = Map.get(result, :__update_context__, %{})

    if map_size(updates) > 0 do
      Logger.debug(
        "Tool '#{cleaned_name}' returned context updates: #{inspect(Map.keys(updates))}"
      )
    end

    {Map.delete(result, :__update_context__), updates}
  end

  defp split_legacy_update(result, _cleaned_name), do: {result, %{}}

  defp not_found(tools, call_name, cleaned_name) do
    available_tools = Enum.map_join(tools, ", ", & &1.name)

    Logger.error("""
    Tool not found: #{call_name}
      Cleaned name: #{cleaned_name}
      Available tools: #{available_tools}
    """)

    {"Tool not found: #{call_name}", %{}}
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

  # The outer ceiling fired and the task was killed mid-flight, so ToolExecutor
  # never got to raise its own ToolTimeout. Surface a readable per-call timeout
  # the model can route around, keeping this call's attribution intact.
  @doc false
  @spec timed_out(map(), pos_integer()) :: outcome()
  def timed_out(call, timeout_ms) do
    call_id = ToolCall.field(call, :id)
    cleaned_name = ToolCall.clean_name(ToolCall.field(call, :name))

    Logger.error("Tool '#{cleaned_name}' exceeded the #{timeout_ms}ms parallel execution ceiling")

    result_msg =
      Message.tool(
        call_id,
        "Tool execution timed out: #{cleaned_name} did not respond within #{timeout_ms}ms.",
        name: cleaned_name
      )

    {result_msg, %{}}
  end

  # A task killed/crashed outside ToolExecutor's own error handling (which
  # already converts in-tool crashes to {:error, _}) becomes a per-call tool
  # error so one dead task never sinks the whole turn.
  @doc false
  @spec crashed(map(), term()) :: outcome()
  def crashed(call, reason) do
    call_id = ToolCall.field(call, :id)
    cleaned_name = ToolCall.clean_name(ToolCall.field(call, :name))

    Logger.error("Tool '#{cleaned_name}' task exited: #{inspect(reason)}")

    result_msg =
      Message.tool(
        call_id,
        "Tool execution failed: #{cleaned_name} - task exited: #{inspect(reason)}",
        name: cleaned_name
      )

    {result_msg, %{}}
  end

  # The provider marshalling tagged a call whose arguments JSON failed to
  # parse with `_invalid_arguments`; the model gets a clean error and a retry
  # rather than the tool getting bogus/empty args.
  @doc false
  @spec invalid_arguments(String.t() | nil, String.t(), String.t()) :: Message.t()
  def invalid_arguments(call_id, cleaned_name, raw) do
    Logger.warning("Tool '#{cleaned_name}' called with malformed arguments JSON: #{raw}")

    Message.tool(
      call_id,
      "Error: tool arguments were not valid JSON. Please retry with a JSON object.",
      name: cleaned_name
    )
  end
end

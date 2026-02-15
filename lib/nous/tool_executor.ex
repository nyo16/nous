defmodule Nous.ToolExecutor do
  @moduledoc """
  Executes tool functions with retry logic, timeout handling, and error handling.

  The ToolExecutor is responsible for:
  - Calling tool functions with the correct arguments
  - Managing the RunContext
  - Implementing retry logic on failures
  - Handling timeouts
  - Processing ContextUpdate returns
  - Logging execution
  """

  alias Nous.{Tool, RunContext, Errors}
  alias Nous.Tool.ContextUpdate

  require Logger

  @type execute_result ::
          {:ok, any()}
          | {:ok, any(), ContextUpdate.t()}
          | {:error, term()}

  @doc """
  Execute a tool with the given arguments.

  Automatically handles:
  - Passing RunContext to tools that need it
  - Retrying on failure (up to tool.retries times)
  - Timeout enforcement (if tool.timeout is set)
  - ContextUpdate extraction from tool results
  - Error wrapping and logging

  ## Return Values

  - `{:ok, result}` - Tool executed successfully
  - `{:ok, result, context_update}` - Tool executed and wants to update context
  - `{:error, reason}` - Tool failed after all retries

  ## Examples

      ctx = RunContext.new(%{database: MyApp.DB})
      arguments = %{"query" => "elixir"}

      case ToolExecutor.execute(tool, arguments, ctx) do
        {:ok, result} ->
          # Tool executed successfully
          result

        {:ok, result, context_update} ->
          # Tool executed and wants to update context
          new_ctx = ContextUpdate.apply_to_run_context(context_update, ctx)
          {result, new_ctx}

        {:error, reason} ->
          # Tool failed after all retries
          handle_error(reason)
      end

  """
  @spec execute(Tool.t(), map(), RunContext.t()) :: execute_result()
  def execute(%Tool{} = tool, arguments, %RunContext{} = ctx) do
    Logger.debug(
      "Executing tool '#{tool.name}' (retries: #{tool.retries}, takes_ctx: #{tool.takes_ctx}, timeout: #{tool.timeout}ms)"
    )

    do_execute(tool, arguments, ctx, 0)
  end

  # Private recursive function that implements retry logic
  defp do_execute(tool, arguments, ctx, attempt) do
    start_time = System.monotonic_time()

    # Emit start event
    :telemetry.execute(
      [:nous, :tool, :execute, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        tool_name: tool.name,
        tool_module: tool.module,
        attempt: attempt + 1,
        max_retries: tool.retries + 1,
        has_timeout: not is_nil(tool.timeout)
      }
    )

    try do
      # Execute the tool function with optional timeout
      result = execute_with_timeout(tool, arguments, ctx)

      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      if attempt > 0 do
        Logger.info(
          "Tool '#{tool.name}' succeeded on retry attempt #{attempt + 1} (#{duration_ms}ms)"
        )
      else
        Logger.debug("Tool '#{tool.name}' completed in #{duration_ms}ms")
      end

      # Emit success event
      :telemetry.execute(
        [:nous, :tool, :execute, :stop],
        %{duration: duration},
        %{
          tool_name: tool.name,
          attempt: attempt + 1,
          success: true
        }
      )

      # Normalize result to handle ContextUpdate
      normalize_result(result)
    rescue
      error ->
        handle_execution_error(tool, arguments, ctx, attempt, start_time, error, __STACKTRACE__)
    catch
      :exit, {:timeout, _} ->
        handle_timeout(tool, attempt, start_time)
    end
  end

  # Execute with optional timeout
  defp execute_with_timeout(tool, arguments, ctx) do
    if tool.timeout && tool.timeout > 0 do
      # Use spawn + monitor instead of Task.async to avoid linking
      # This prevents exceptions from propagating to the caller
      caller = self()
      ref = make_ref()

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          try do
            result = apply_tool_function(tool, arguments, ctx)
            send(caller, {ref, {:ok, result}})
          rescue
            e ->
              send(caller, {ref, {:exception, e, __STACKTRACE__}})
          catch
            kind, reason ->
              send(caller, {ref, {:caught, kind, reason, __STACKTRACE__}})
          end
        end)

      receive do
        {^ref, {:ok, result}} ->
          Process.demonitor(monitor_ref, [:flush])
          result

        {^ref, {:exception, exception, stacktrace}} ->
          Process.demonitor(monitor_ref, [:flush])
          reraise exception, stacktrace

        {^ref, {:caught, kind, reason, stacktrace}} ->
          Process.demonitor(monitor_ref, [:flush])
          :erlang.raise(kind, reason, stacktrace)

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          # Process died unexpectedly
          raise "Tool execution process died: #{inspect(reason)}"
      after
        tool.timeout ->
          # Timeout - kill the process
          Process.demonitor(monitor_ref, [:flush])
          Process.exit(pid, :kill)

          # Emit timeout event
          :telemetry.execute(
            [:nous, :tool, :timeout],
            %{timeout: tool.timeout},
            %{tool_name: tool.name}
          )

          raise Errors.ToolTimeout.exception(
                  tool_name: tool.name,
                  timeout: tool.timeout
                )
      end
    else
      # No timeout, execute directly
      apply_tool_function(tool, arguments, ctx)
    end
  end

  # Handle timeout specifically
  defp handle_timeout(tool, attempt, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:nous, :tool, :execute, :exception],
      %{duration: duration},
      %{
        tool_name: tool.name,
        attempt: attempt + 1,
        will_retry: false,
        kind: :timeout,
        reason: :timeout
      }
    )

    {:error,
     Errors.ToolTimeout.exception(
       tool_name: tool.name,
       timeout: tool.timeout
     )}
  end

  # Handle execution errors with retry logic
  defp handle_execution_error(tool, arguments, ctx, attempt, start_time, error, stacktrace) do
    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    # Emit exception event with stacktrace for better debugging
    :telemetry.execute(
      [:nous, :tool, :execute, :exception],
      %{duration: duration},
      %{
        tool_name: tool.name,
        attempt: attempt + 1,
        will_retry: attempt < tool.retries,
        kind: error.__struct__,
        reason: error,
        stacktrace: stacktrace
      }
    )

    if attempt < tool.retries do
      # Will retry
      Logger.warning("""
      Tool '#{tool.name}' failed (attempt #{attempt + 1}/#{tool.retries + 1}), will retry
        Error: #{Exception.message(error)}
        Duration: #{duration_ms}ms
      """)

      # Retry with updated context (increment retry count)
      new_ctx = %{ctx | retry: attempt + 1}
      do_execute(tool, arguments, new_ctx, attempt + 1)
    else
      # All retries exhausted
      Logger.error("""
      Tool '#{tool.name}' failed after all #{tool.retries + 1} attempt(s)
        Error: #{Exception.message(error)}
        Error type: #{inspect(error.__struct__)}
        Total duration: #{duration_ms}ms
      """)

      wrapped_error =
        Errors.ToolError.exception(
          tool_name: tool.name,
          attempt: attempt + 1,
          original_error: error,
          message: "Tool execution failed: #{Exception.message(error)}"
        )

      {:error, wrapped_error}
    end
  end

  # Normalize tool results to handle ContextUpdate
  defp normalize_result({:ok, result, %ContextUpdate{} = update}) do
    {:ok, result, update}
  end

  defp normalize_result({:ok, result}) do
    {:ok, result}
  end

  defp normalize_result({:error, _} = error) do
    error
  end

  # Handle raw results (not wrapped in :ok/:error)
  defp normalize_result(result) do
    {:ok, result}
  end

  # Apply the tool function with correct arguments based on whether it takes context
  defp apply_tool_function(tool, arguments, ctx) do
    if tool.takes_ctx do
      # Tool expects (ctx, arguments)
      apply_with_context(tool.function, ctx, arguments)
    else
      # Tool expects just arguments
      apply_without_context(tool.function, arguments)
    end
  end

  defp apply_with_context(fun, ctx, args) when is_map(args) do
    # Always pass the full args map to the function
    # Let the function handle pattern matching
    fun.(ctx, args)
  end

  defp apply_without_context(fun, args) when is_map(args) do
    # Always pass the full args map
    fun.(args)
  end
end

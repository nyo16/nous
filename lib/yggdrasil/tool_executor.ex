defmodule Yggdrasil.ToolExecutor do
  @moduledoc """
  Executes tool functions with retry logic and error handling.

  The ToolExecutor is responsible for:
  - Calling tool functions with the correct arguments
  - Managing the RunContext
  - Implementing retry logic on failures
  - Logging execution
  """

  alias Yggdrasil.{Tool, RunContext, Errors}

  require Logger

  @doc """
  Execute a tool with the given arguments.

  Automatically handles:
  - Passing RunContext to tools that need it
  - Retrying on failure (up to tool.retries times)
  - Error wrapping and logging

  ## Examples

      ctx = RunContext.new(%{database: MyApp.DB})
      arguments = %{"query" => "elixir"}

      case ToolExecutor.execute(tool, arguments, ctx) do
        {:ok, result} ->
          # Tool executed successfully
          result
        {:error, reason} ->
          # Tool failed after all retries
          handle_error(reason)
      end

  """
  @spec execute(Tool.t(), map(), RunContext.t()) :: {:ok, any()} | {:error, term()}
  def execute(%Tool{} = tool, arguments, %RunContext{} = ctx) do
    Logger.debug("Executing tool '#{tool.name}' (retries: #{tool.retries}, takes_ctx: #{tool.takes_ctx})")
    do_execute(tool, arguments, ctx, 0)
  end

  # Private recursive function that implements retry logic
  defp do_execute(tool, arguments, ctx, attempt) do
    start_time = System.monotonic_time()

    # Emit start event
    :telemetry.execute(
      [:yggdrasil, :tool, :execute, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        tool_name: tool.name,
        attempt: attempt + 1,
        max_retries: tool.retries + 1
      }
    )

    try do
      # Execute the tool function
      result = apply_tool_function(tool, arguments, ctx)

      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      if attempt > 0 do
        Logger.info("Tool '#{tool.name}' succeeded on retry attempt #{attempt + 1} (#{duration_ms}ms)")
      else
        Logger.debug("Tool '#{tool.name}' completed in #{duration_ms}ms")
      end

      # Emit success event
      :telemetry.execute(
        [:yggdrasil, :tool, :execute, :stop],
        %{duration: duration},
        %{
          tool_name: tool.name,
          attempt: attempt + 1,
          success: true
        }
      )

      {:ok, result}
    rescue
      error ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        # Emit exception event
        :telemetry.execute(
          [:yggdrasil, :tool, :execute, :exception],
          %{duration: duration},
          %{
            tool_name: tool.name,
            attempt: attempt + 1,
            will_retry: attempt < tool.retries,
            kind: error.__struct__,
            reason: error
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

          wrapped_error = Errors.ToolError.exception(
            tool_name: tool.name,
            attempt: attempt + 1,
            original_error: error,
            message: "Tool execution failed: #{Exception.message(error)}"
          )

          {:error, wrapped_error}
        end
    end
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

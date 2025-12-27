defmodule Nous.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Nous.{Tool, ToolExecutor, RunContext, Errors}

  import ExUnit.CaptureLog

  # Test helper modules with various tool behaviors
  defmodule TestTools do
    @moduledoc false

    # Tool that takes context and succeeds
    def context_tool(ctx, %{"input" => input}) do
      %{
        success: true,
        received: input,
        has_context: true,
        retry_count: ctx.retry,
        deps_available: Map.keys(ctx.deps)
      }
    end

    # Tool that doesn't take context
    def simple_tool(%{"value" => value}) do
      %{
        success: true,
        doubled: value * 2,
        has_context: false
      }
    end

    # Tool that fails on first attempt but succeeds on retry
    def flaky_tool(ctx, %{"should_fail" => should_fail}) do
      if should_fail and ctx.retry == 0 do
        raise "Temporary failure on first attempt"
      else
        %{
          success: true,
          attempt: ctx.retry + 1,
          message: "Succeeded on attempt #{ctx.retry + 1}"
        }
      end
    end

    # Tool that always fails
    def failing_tool(_ctx, _args) do
      raise "This tool always fails"
    end

    # Tool that fails with custom error
    def custom_error_tool(_ctx, %{"error_type" => error_type}) do
      case error_type do
        "runtime" -> raise RuntimeError, "Custom runtime error"
        "argument" -> raise ArgumentError, "Invalid arguments"
        "timeout" -> raise "Operation timeout"
        _ -> %{success: true}
      end
    end

    # Tool with complex validation
    def validation_tool(ctx, args) do
      with {:ok, name} <- Map.fetch(args, "name"),
           {:ok, age} <- Map.fetch(args, "age"),
           true <- is_binary(name),
           true <- is_integer(age) and age > 0 do
        %{
          success: true,
          validated: %{name: name, age: age},
          context_deps: Map.keys(ctx.deps)
        }
      else
        :error -> raise "Missing required parameters"
        false -> raise "Invalid parameter types"
      end
    end

    # Tool that updates context (simulates stateful tool)
    def stateful_tool(ctx, %{"action" => action}) do
      current_state = Map.get(ctx.deps, :state, 0)

      new_state = case action do
        "increment" -> current_state + 1
        "decrement" -> current_state - 1
        "reset" -> 0
        _ -> current_state
      end

      %{
        success: true,
        previous_state: current_state,
        new_state: new_state,
        __update_context__: %{state: new_state}
      }
    end
  end

  # Helper for capturing telemetry events
  defmodule TelemetryCapture do
    use GenServer

    def start_link(_) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def init([]) do
      events = [
        [:nous, :tool, :execute, :start],
        [:nous, :tool, :execute, :stop],
        [:nous, :tool, :execute, :exception]
      ]

      for event <- events do
        :telemetry.attach("test-#{inspect(event)}", event, &__MODULE__.handle_event/4, nil)
      end

      {:ok, []}
    end

    def handle_event(event, measurements, metadata, _config) do
      GenServer.cast(__MODULE__, {:event, event, measurements, metadata})
    end

    def get_events do
      GenServer.call(__MODULE__, :get_events)
    end

    def clear_events do
      GenServer.call(__MODULE__, :clear_events)
    end

    def handle_call(:get_events, _from, events) do
      {:reply, Enum.reverse(events), events}
    end

    def handle_call(:clear_events, _from, _events) do
      {:reply, :ok, []}
    end

    def handle_cast({:event, event, measurements, metadata}, events) do
      {:noreply, [{event, measurements, metadata} | events]}
    end
  end

  setup do
    # Start telemetry capture
    start_supervised!(TelemetryCapture)
    TelemetryCapture.clear_events()

    # Create test context with dependencies
    deps = %{
      database: :test_db,
      api_key: "test-key",
      state: 42
    }
    ctx = RunContext.new(deps)

    %{ctx: ctx}
  end

  describe "execute/3 with context tools" do
    test "executes tool that takes context successfully", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.context_tool/2,
        name: "context_tool",
        description: "A tool that uses context"
      )

      assert {:ok, result} = ToolExecutor.execute(tool, %{"input" => "test"}, ctx)

      assert result.success == true
      assert result.received == "test"
      assert result.has_context == true
      assert result.retry_count == 0
      assert :database in result.deps_available
    end

    test "passes correct context information", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.validation_tool/2,
        name: "validation_tool",
        description: "Tool that validates input"
      )

      args = %{"name" => "Alice", "age" => 30}
      assert {:ok, result} = ToolExecutor.execute(tool, args, ctx)

      assert result.success == true
      assert result.validated.name == "Alice"
      assert result.validated.age == 30
      assert :database in result.context_deps
    end

    test "handles tool validation failures", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.validation_tool/2,
        name: "validation_tool",
        retries: 0
      )

      logs = capture_log(fn ->
        assert {:error, error} = ToolExecutor.execute(tool, %{"invalid" => true}, ctx)
        assert %Errors.ToolError{} = error
        assert error.tool_name == "validation_tool"
        assert error.attempt == 1
      end)

      assert logs =~ "Tool 'validation_tool' failed after all"
    end
  end

  describe "execute/3 with simple tools" do
    test "executes tool without context successfully", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.simple_tool/1,
        name: "simple_tool",
        description: "A simple tool"
      )

      assert {:ok, result} = ToolExecutor.execute(tool, %{"value" => 21}, ctx)

      assert result.success == true
      assert result.doubled == 42
      assert result.has_context == false
    end

    test "detects arity correctly for simple tools", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.simple_tool/1)

      # Verify the tool was created with correct takes_ctx setting
      assert tool.takes_ctx == false
      assert tool.function

      assert {:ok, _result} = ToolExecutor.execute(tool, %{"value" => 10}, ctx)
    end
  end

  describe "execute/3 retry logic" do
    test "retries failing tool and succeeds on retry", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.flaky_tool/2,
        name: "flaky_tool",
        retries: 2
      )

      logs = capture_log(fn ->
        assert {:ok, result} = ToolExecutor.execute(tool, %{"should_fail" => true}, ctx)

        assert result.success == true
        assert result.attempt == 2  # Succeeded on second attempt (retry count 1)
        assert result.message =~ "Succeeded on attempt 2"
      end)

      assert logs =~ "Tool 'flaky_tool' failed (attempt 1/3), will retry"
      assert logs =~ "Tool 'flaky_tool' succeeded on retry attempt 2"
    end

    test "exhausts all retries for always-failing tool", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.failing_tool/2,
        name: "failing_tool",
        retries: 2
      )

      logs = capture_log(fn ->
        assert {:error, error} = ToolExecutor.execute(tool, %{}, ctx)

        assert %Errors.ToolError{} = error
        assert error.tool_name == "failing_tool"
        assert error.attempt == 3  # Failed after 3 attempts
        assert error.original_error
        assert Exception.message(error.original_error) == "This tool always fails"
      end)

      assert logs =~ "Tool 'failing_tool' failed (attempt 1/3), will retry"
      assert logs =~ "Tool 'failing_tool' failed (attempt 2/3), will retry"
      assert logs =~ "Tool 'failing_tool' failed after all 3 attempt(s)"
    end

    test "updates context retry count on retries", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.flaky_tool/2,
        name: "retry_counter",
        retries: 3
      )

      # This will fail once, then succeed, so we can verify retry count was passed
      assert {:ok, result} = ToolExecutor.execute(tool, %{"should_fail" => true}, ctx)
      assert result.attempt == 2  # First attempt failed (retry=0), second succeeded (retry=1)
    end

    test "respects tool retry configuration", %{ctx: ctx} do
      # Tool with 0 retries should fail immediately
      tool_no_retry = Tool.from_function(&TestTools.failing_tool/2,
        name: "no_retry",
        retries: 0
      )

      logs = capture_log(fn ->
        assert {:error, error} = ToolExecutor.execute(tool_no_retry, %{}, ctx)
        assert error.attempt == 1
      end)

      assert logs =~ "Tool 'no_retry' failed after all 1 attempt(s)"
      refute logs =~ "will retry"
    end
  end

  describe "execute/3 error handling" do
    test "wraps different error types correctly", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.custom_error_tool/2,
        name: "error_tool",
        retries: 0
      )

      # Test RuntimeError
      assert {:error, error1} = ToolExecutor.execute(tool, %{"error_type" => "runtime"}, ctx)
      assert %Errors.ToolError{} = error1
      assert %RuntimeError{} = error1.original_error

      # Test ArgumentError
      assert {:error, error2} = ToolExecutor.execute(tool, %{"error_type" => "argument"}, ctx)
      assert %ArgumentError{} = error2.original_error

      # Test generic error
      assert {:error, error3} = ToolExecutor.execute(tool, %{"error_type" => "timeout"}, ctx)
      assert error3.original_error
    end

    test "logs detailed error information", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.custom_error_tool/2,
        name: "detailed_errors",
        retries: 1
      )

      logs = capture_log(fn ->
        ToolExecutor.execute(tool, %{"error_type" => "runtime"}, ctx)
      end)

      assert logs =~ "Tool 'detailed_errors' failed after all 2 attempt(s)"
      assert logs =~ "Error: Custom runtime error"
      assert logs =~ "Error type: RuntimeError"
    end
  end

  describe "execute/3 telemetry events" do
    test "emits start and stop events for successful execution", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.simple_tool/1, name: "telemetry_test")

      assert {:ok, _result} = ToolExecutor.execute(tool, %{"value" => 5}, ctx)

      events = TelemetryCapture.get_events()
      assert length(events) == 2

      # Check start event
      {start_event, start_measurements, start_metadata} = Enum.at(events, 0)
      assert start_event == [:nous, :tool, :execute, :start]
      assert start_measurements.system_time
      assert start_measurements.monotonic_time
      assert start_metadata.tool_name == "telemetry_test"
      assert start_metadata.attempt == 1
      assert start_metadata.max_retries == 2  # default retries + 1

      # Check stop event
      {stop_event, stop_measurements, stop_metadata} = Enum.at(events, 1)
      assert stop_event == [:nous, :tool, :execute, :stop]
      assert stop_measurements.duration > 0
      assert stop_metadata.tool_name == "telemetry_test"
      assert stop_metadata.attempt == 1
      assert stop_metadata.success == true
    end

    test "emits exception events for failures", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.failing_tool/2,
        name: "telemetry_fail",
        retries: 1
      )

      capture_log(fn ->
        ToolExecutor.execute(tool, %{}, ctx)
      end)

      events = TelemetryCapture.get_events()

      # Should have: start -> exception -> start -> exception (2 attempts)
      assert length(events) == 4

      exception_events = Enum.filter(events, fn {event, _, _} ->
        event == [:nous, :tool, :execute, :exception]
      end)

      assert length(exception_events) == 2

      # Check first exception event (will retry)
      {_event1, measurements1, metadata1} = Enum.at(exception_events, 0)
      assert measurements1.duration > 0
      assert metadata1.tool_name == "telemetry_fail"
      assert metadata1.attempt == 1
      assert metadata1.will_retry == true
      assert metadata1.kind == RuntimeError

      # Check second exception event (won't retry)
      {_event2, _measurements2, metadata2} = Enum.at(exception_events, 1)
      assert metadata2.attempt == 2
      assert metadata2.will_retry == false
    end

    test "includes stacktrace in exception events", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.custom_error_tool/2,
        name: "stacktrace_test",
        retries: 0
      )

      capture_log(fn ->
        ToolExecutor.execute(tool, %{"error_type" => "runtime"}, ctx)
      end)

      events = TelemetryCapture.get_events()
      exception_events = Enum.filter(events, fn {event, _, _} ->
        event == [:nous, :tool, :execute, :exception]
      end)

      assert length(exception_events) == 1
      {_event, _measurements, metadata} = hd(exception_events)
      assert metadata.stacktrace
      assert is_list(metadata.stacktrace)
    end
  end

  describe "execute/3 context updates" do
    test "handles stateful tool context updates", %{ctx: ctx} do
      tool = Tool.from_function(&TestTools.stateful_tool/2,
        name: "stateful_tool"
      )

      assert {:ok, result} = ToolExecutor.execute(tool, %{"action" => "increment"}, ctx)

      assert result.success == true
      assert result.previous_state == 42  # Original state from setup
      assert result.new_state == 43
      assert result.__update_context__.state == 43
    end

    test "preserves context state across retry attempts" do
      # Custom context with retry tracking
      deps = %{counter: 0}
      ctx = RunContext.new(deps)

      # Tool that fails first time but tracks context changes
      counter_tool = fn ctx, %{"increment" => should_increment} ->
        if should_increment and ctx.retry == 0 do
          raise "First attempt fails"
        else
          current = Map.get(ctx.deps, :counter, 0)
          new_count = current + ctx.retry + 1
          %{
            success: true,
            final_count: new_count,
            retry_attempt: ctx.retry,
            __update_context__: %{counter: new_count}
          }
        end
      end

      tool = Tool.from_function(counter_tool,
        name: "counter_tool",
        retries: 2
      )

      capture_log(fn ->
        assert {:ok, result} = ToolExecutor.execute(tool, %{"increment" => true}, ctx)

        # Should succeed on retry attempt (retry=1), so final count = 0 + 1 + 1 = 2
        assert result.retry_attempt == 1
        assert result.final_count == 2
      end)
    end
  end

  describe "execute/3 complex scenarios" do
    test "handles tool with both success and failure paths", %{ctx: ctx} do
      conditional_tool = fn _ctx, %{"should_succeed" => should_succeed} ->
        if should_succeed do
          %{success: true, message: "Tool succeeded"}
        else
          raise "Tool failed as requested"
        end
      end

      tool = Tool.from_function(conditional_tool,
        name: "conditional",
        retries: 0
      )

      # Test success path
      assert {:ok, result} = ToolExecutor.execute(tool, %{"should_succeed" => true}, ctx)
      assert result.success == true

      # Test failure path
      capture_log(fn ->
        assert {:error, error} = ToolExecutor.execute(tool, %{"should_succeed" => false}, ctx)
        assert %Errors.ToolError{} = error
      end)
    end

    test "handles tools with complex return structures", %{ctx: ctx} do
      complex_tool = fn ctx, args ->
        %{
          success: true,
          input_analysis: %{
            arg_count: map_size(args),
            arg_keys: Map.keys(args)
          },
          context_info: %{
            has_deps: map_size(ctx.deps) > 0,
            retry_count: ctx.retry,
            usage_tokens: ctx.usage.total_tokens
          },
          nested: %{
            deeper: %{
              value: "deep_value",
              timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        }
      end

      tool = Tool.from_function(complex_tool, name: "complex_tool")

      args = %{"param1" => "value1", "param2" => 42, "param3" => [1, 2, 3]}
      assert {:ok, result} = ToolExecutor.execute(tool, args, ctx)

      assert result.success == true
      assert result.input_analysis.arg_count == 3
      assert "param1" in result.input_analysis.arg_keys
      assert result.context_info.has_deps == true
      assert result.nested.deeper.value == "deep_value"
    end

    test "measures execution duration correctly", %{ctx: ctx} do
      # Tool that takes a measurable amount of time
      slow_tool = fn _ctx, %{"sleep_ms" => sleep_ms} ->
        Process.sleep(sleep_ms)
        %{success: true, slept: sleep_ms}
      end

      tool = Tool.from_function(slow_tool, name: "slow_tool")

      assert {:ok, result} = ToolExecutor.execute(tool, %{"sleep_ms" => 10}, ctx)
      assert result.success == true

      # Check telemetry recorded duration
      events = TelemetryCapture.get_events()
      stop_events = Enum.filter(events, fn {event, _, _} ->
        event == [:nous, :tool, :execute, :stop]
      end)

      assert length(stop_events) == 1
      {_event, measurements, _metadata} = hd(stop_events)
      assert measurements.duration >= 10_000  # At least 10ms in native time units
    end
  end

  describe "execute/3 edge cases" do
    test "handles tool that returns non-map result", %{ctx: ctx} do
      simple_return_tool = fn _ctx, _args ->
        "simple string result"
      end

      tool = Tool.from_function(simple_return_tool, name: "simple_return")

      assert {:ok, result} = ToolExecutor.execute(tool, %{}, ctx)
      assert result == "simple string result"
    end

    test "handles tool with empty arguments", %{ctx: ctx} do
      no_args_tool = fn _ctx, args ->
        %{
          success: true,
          received_args: args,
          arg_count: map_size(args)
        }
      end

      tool = Tool.from_function(no_args_tool, name: "no_args")

      assert {:ok, result} = ToolExecutor.execute(tool, %{}, ctx)
      assert result.success == true
      assert result.arg_count == 0
    end

    test "handles context with empty deps", %{ctx: _ctx} do
      empty_ctx = RunContext.new(%{})

      tool = Tool.from_function(&TestTools.context_tool/2, name: "empty_deps")

      assert {:ok, result} = ToolExecutor.execute(tool, %{"input" => "test"}, empty_ctx)
      assert result.success == true
      assert result.deps_available == []
    end

    test "handles tool with high retry count", %{ctx: ctx} do
      eventually_succeeding_tool = fn ctx, _args ->
        if ctx.retry < 5 do
          raise "Not ready yet, attempt #{ctx.retry + 1}"
        else
          %{success: true, succeeded_on_attempt: ctx.retry + 1}
        end
      end

      tool = Tool.from_function(eventually_succeeding_tool,
        name: "persistent_tool",
        retries: 10
      )

      capture_log(fn ->
        assert {:ok, result} = ToolExecutor.execute(tool, %{}, ctx)
        assert result.success == true
        assert result.succeeded_on_attempt == 6  # Succeeded on 6th attempt (retry 5)
      end)
    end
  end
end
defmodule Nous.AgentRunnerParallelToolsTest do
  # async: false — swaps the global :model_dispatcher app env.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, Hook, Tool, Usage}

  @moduletag :capture_log

  # Dispatcher: first request returns the tool_calls staged in :persistent_term,
  # second request returns a plain text response so the loop terminates.
  defmodule Dispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      calls = :persistent_term.get({__MODULE__, :calls}, 0)
      :persistent_term.put({__MODULE__, :calls}, calls + 1)

      response =
        if calls == 0 do
          Nous.Message.assistant("", tool_calls: :persistent_term.get({__MODULE__, :tool_calls}))
        else
          Nous.Message.assistant("all done")
        end

      usage = %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1}
      {:ok, %{response | metadata: %{usage: usage}}}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  defmodule ParallelTools do
    @moduledoc false

    # The two slow tools maintain an :atomics in-flight counter with a running
    # maximum. Wall-clock windows are the wrong instrument for proving
    # concurrency on shared CI hardware — a GC pause inside a 300ms margin
    # fails a correct implementation — so the tests assert the observed maximum
    # *exactly*: 2 on the parallel path, 1 on the sequential one. A one-sided
    # `<= 2` is worthless here; it also holds for a serial runner.
    @slow_ms 150

    def slow_ms, do: @slow_ms

    def slow_alpha(_ctx, _args) do
      inflight = enter()
      Process.sleep(@slow_ms)
      leave(inflight)
      "alpha done"
    end

    def slow_beta(_ctx, _args) do
      inflight = enter()
      Process.sleep(@slow_ms)
      leave(inflight)
      "beta done"
    end

    defp enter do
      inflight = :persistent_term.get({__MODULE__, :inflight})
      record_max(inflight, :atomics.add_get(inflight, 1, 1))
      inflight
    end

    defp leave(inflight), do: :atomics.sub(inflight, 1, 1)

    defp record_max(inflight, current) do
      observed = :atomics.get(inflight, 2)

      if current > observed do
        case :atomics.compare_exchange(inflight, 2, observed, current) do
          :ok -> :ok
          _raced -> record_max(inflight, current)
        end
      end
    end

    def echo(_ctx, args), do: "echo:" <> Map.get(args, "msg", "")

    def boom(_ctx, _args), do: raise("boom")

    def marker_slow(_ctx, _args) do
      Process.sleep(100)
      %{result: "slow", __update_context__: %{marker: "slow"}}
    end

    def marker_fast(_ctx, _args) do
      %{result: "fast", __update_context__: %{marker: "fast"}}
    end

    # Sleeps far past any ceiling a test would set. Paired with `timeout: nil`
    # this is the case ToolExecutor does *not* bound: it only arms its internal
    # timer when tool.timeout is a positive number.
    def hang(_ctx, _args) do
      Process.sleep(5_000)
      "hang finished"
    end
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, Dispatcher)

    # Fresh per test: index 1 is the live in-flight count, index 2 the running
    # maximum the slow tools observed.
    :persistent_term.put({ParallelTools, :inflight}, :atomics.new(2, signed: true))

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)

      for key <- [:calls, :tool_calls] do
        try do
          :persistent_term.erase({Dispatcher, key})
        rescue
          _ -> :ok
        end
      end

      :persistent_term.erase({ParallelTools, :inflight})
    end)

    :ok
  end

  defp stage_tool_calls(calls) do
    :persistent_term.put({Dispatcher, :calls}, 0)
    :persistent_term.put({Dispatcher, :tool_calls}, calls)
  end

  defp call(id, name, args \\ %{}) do
    %{"id" => id, "name" => name, "arguments" => args}
  end

  defp tool_messages(result) do
    Enum.filter(result.all_messages, &(&1.role == :tool))
  end

  # Highest number of slow tools that were inside their sleep at the same instant.
  defp observed_max_concurrency do
    :atomics.get(:persistent_term.get({ParallelTools, :inflight}), 2)
  end

  describe "parallel_tool_calls: true" do
    test "tool result messages keep the original call order" do
      # slow first, fast second — completion order is the reverse of call order
      stage_tool_calls([call("call_1", "slow_alpha"), call("call_2", "echo", %{"msg" => "hi"})])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.slow_alpha/2, &ParallelTools.echo/2],
          parallel_tool_calls: true
        )

      {:ok, result} = AgentRunner.run(agent, "go")

      assert [%{tool_call_id: "call_1", content: "alpha done"}, %{tool_call_id: "call_2"} = echo] =
               tool_messages(result)

      assert echo.content =~ "echo:hi"
    end

    test "both tool calls in the batch are in flight at the same instant" do
      stage_tool_calls([call("call_1", "slow_alpha"), call("call_2", "slow_beta")])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.slow_alpha/2, &ParallelTools.slow_beta/2],
          parallel_tool_calls: true
        )

      started = System.monotonic_time(:millisecond)
      {:ok, result} = AgentRunner.run(agent, "go")
      elapsed = System.monotonic_time(:millisecond) - started

      assert [%{content: "alpha done"}, %{content: "beta done"}] = tool_messages(result)

      # Structural proof of concurrency, not a stopwatch. Exact: `<= 2` would
      # also pass for a runner that fell back to sequential execution.
      assert observed_max_concurrency() == 2

      # Lower bound only — it proves the sleeps actually ran. An upper bound
      # here is just a scheduler stall waiting to redden a correct runner.
      assert elapsed >= ParallelTools.slow_ms(),
             "expected the #{ParallelTools.slow_ms()}ms tools to actually run, got #{elapsed}ms"
    end

    test "merge_deps applies in call order, not completion order" do
      # Both tools write deps.marker; the second call (fast) completes first,
      # but the post-stage runs in call order, so its value must win.
      stage_tool_calls([call("call_1", "marker_slow"), call("call_2", "marker_fast")])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.marker_slow/2, &ParallelTools.marker_fast/2],
          parallel_tool_calls: true
        )

      {:ok, result} = AgentRunner.run(agent, "go")

      assert result.deps.marker == "fast"
    end

    test "pre/post hooks fire per call; denied and approved calls mix" do
      test_pid = self()

      hooks = [
        Hook.new(:pre_tool_use,
          handler: fn _event, payload ->
            if payload.tool_name == "boom", do: {:deny, "not allowed"}, else: :allow
          end
        ),
        Hook.new(:post_tool_use,
          handler: fn _event, payload ->
            send(test_pid, {:post_tool, payload.tool_name})
            :allow
          end
        )
      ]

      stage_tool_calls([call("call_1", "boom"), call("call_2", "echo", %{"msg" => "ok"})])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.boom/2, &ParallelTools.echo/2],
          parallel_tool_calls: true,
          hooks: hooks
        )

      {:ok, result} = AgentRunner.run(agent, "go")

      assert [denied, allowed] = tool_messages(result)
      assert denied.tool_call_id == "call_1"
      assert denied.content =~ "denied by hook: not allowed"
      assert allowed.content =~ "echo:ok"

      # post_tool_use runs only for executed calls (same as sequential mode)
      assert_received {:post_tool, "echo"}
      refute_received {:post_tool, "boom"}
    end

    test "one tool raising does not sink the turn" do
      stage_tool_calls([call("call_1", "boom"), call("call_2", "echo", %{"msg" => "alive"})])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.boom/2, &ParallelTools.echo/2],
          parallel_tool_calls: true
        )

      {:ok, result} = AgentRunner.run(agent, "go")

      assert [failed, ok] = tool_messages(result)
      assert failed.tool_call_id == "call_1"
      assert failed.content =~ "Tool execution failed"
      assert ok.content =~ "echo:alive"
    end

    test "a hung tool with timeout: nil is killed at the ceiling and does not block siblings" do
      # Both tools declare timeout: nil, so the batch ceiling is the module
      # default — overridden here so the test does not wait five minutes.
      Application.put_env(:nous, :parallel_tool_call_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:nous, :parallel_tool_call_timeout_ms) end)

      tools = [
        Tool.from_function(&ParallelTools.hang/2, timeout: nil, retries: 0),
        Tool.from_function(&ParallelTools.echo/2, timeout: nil, retries: 0)
      ]

      stage_tool_calls([call("call_1", "hang"), call("call_2", "echo", %{"msg" => "alive"})])

      agent = Agent.new("openai:test-model", tools: tools, parallel_tool_calls: true)

      started = System.monotonic_time(:millisecond)
      {:ok, result} = AgentRunner.run(agent, "go")
      elapsed = System.monotonic_time(:millisecond) - started

      # The run returns on the ceiling, not on the tool's 5s sleep.
      assert elapsed < 3_000

      assert [timed_out, ok] = tool_messages(result)
      assert timed_out.tool_call_id == "call_1"
      assert timed_out.content =~ "Tool execution timed out: hang"
      assert timed_out.content =~ "200ms"

      # The sibling call in the same batch keeps its real result.
      assert ok.tool_call_id == "call_2"
      assert ok.content =~ "echo:alive"
    end
  end

  describe "parallel_tool_calls: false (default)" do
    test "multiple tool calls run sequentially with identical result shape" do
      stage_tool_calls([call("call_1", "slow_alpha"), call("call_2", "echo", %{"msg" => "hi"})])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.slow_alpha/2, &ParallelTools.echo/2]
        )

      refute agent.parallel_tool_calls

      {:ok, result} = AgentRunner.run(agent, "go")

      assert [%{tool_call_id: "call_1", content: "alpha done"}, %{tool_call_id: "call_2"}] =
               tool_messages(result)
    end

    test "the two tool calls never overlap" do
      stage_tool_calls([call("call_1", "slow_alpha"), call("call_2", "slow_beta")])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.slow_alpha/2, &ParallelTools.slow_beta/2]
        )

      started = System.monotonic_time(:millisecond)
      {:ok, _result} = AgentRunner.run(agent, "go")
      elapsed = System.monotonic_time(:millisecond) - started

      # Mirror of the parallel case: never more than one tool in flight, so a
      # runner that quietly started parallelising the default path fails here.
      assert observed_max_concurrency() == 1
      assert elapsed >= 2 * ParallelTools.slow_ms()
    end
  end
end

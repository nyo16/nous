defmodule Nous.AgentRunnerParallelToolsTest do
  # async: false — swaps the global :model_dispatcher app env.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, Hook, Usage}

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

    def slow_alpha(_ctx, _args) do
      Process.sleep(400)
      "alpha done"
    end

    def slow_beta(_ctx, _args) do
      Process.sleep(400)
      "beta done"
    end

    def echo(_ctx, args), do: "echo:" <> Map.get(args, "msg", "")

    def boom(_ctx, _args), do: raise("boom")

    def marker_slow(_ctx, _args) do
      Process.sleep(250)
      %{result: "slow", __update_context__: %{marker: "slow"}}
    end

    def marker_fast(_ctx, _args) do
      %{result: "fast", __update_context__: %{marker: "fast"}}
    end
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, Dispatcher)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)

      for key <- [:calls, :tool_calls] do
        try do
          :persistent_term.erase({Dispatcher, key})
        rescue
          _ -> :ok
        end
      end
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

    test "wall clock is ~max of tool durations, not the sum" do
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
      # Two 400ms tools run concurrently: wall clock is ~max (400ms), not sum
      # (800ms). Two-sided so a regression in EITHER direction fails — the lower
      # bound catches "sleeps bypassed / tools not actually run", the upper
      # bound catches "fell back to sequential". Generous margins for CI.
      assert elapsed >= 400, "expected the 400ms tools to actually run, got #{elapsed}ms"
      assert elapsed < 700, "expected ~400ms (max), got #{elapsed}ms (sum would be >= 800ms)"
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

    test "two slow tools take the sum of their durations" do
      stage_tool_calls([call("call_1", "slow_alpha"), call("call_2", "slow_beta")])

      agent =
        Agent.new("openai:test-model",
          tools: [&ParallelTools.slow_alpha/2, &ParallelTools.slow_beta/2]
        )

      started = System.monotonic_time(:millisecond)
      {:ok, _result} = AgentRunner.run(agent, "go")
      elapsed = System.monotonic_time(:millisecond) - started

      # Two 400ms tools run one after the other: sum (>= 800ms). Upper bound
      # catches a pathological regression (e.g. a tool running more than once)
      # short of ExUnit's 60s timeout.
      assert elapsed >= 800
      assert elapsed < 2000, "expected ~800ms (sum), got #{elapsed}ms"
    end
  end
end

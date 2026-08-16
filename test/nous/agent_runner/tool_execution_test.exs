defmodule Nous.AgentRunner.ToolExecutionTest do
  # async: false — swaps the global :model_dispatcher app env, the same way
  # Nous.AgentRunnerParallelToolsTest does.
  use ExUnit.Case, async: false

  @moduledoc """
  The live tool path for `Nous.Tool.ContextUpdate` operations.

  `ContextUpdate.log_event/3` exists so a tool can record something auditable
  that must **not** enter the model's history. That claim is only true if two
  things hold at once: the event reaches the session log, and `ctx.messages` is
  unchanged. Every test here asserts the pair — either half alone is satisfied
  by a broken implementation (drop the events and messages are untouched; write
  them as messages and they are certainly recorded).

  These drive the whole runner rather than `record_tool_result/6` directly,
  because the defect being fixed was structural: `execute_single_tool/4` folded
  the update to a deps map before anything holding a session log could see it.
  """

  alias Nous.{Agent, AgentRunner, Tool, Usage}
  alias Nous.AgentRunner.ToolExecution
  alias Nous.Session.Log
  alias Nous.Tool.ContextUpdate

  @moduletag :capture_log

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

  defmodule AuditedTools do
    @moduledoc false

    # The events are staged out of band, never in the tool arguments: arguments
    # travel in the assistant message, so toggling them there would change
    # `messages` and destroy the byte-identity comparison the tests rest on.
    def audited(_ctx, _args) do
      update =
        Enum.reduce(
          staged_events(),
          ContextUpdate.set(ContextUpdate.new(), :audited_ran, true),
          fn data, update -> ContextUpdate.log_event(update, :tool_call, data) end
        )

      {:ok, "audited done", update}
    end

    # Same name shape, second call id — used to prove the parallel path logs
    # both calls' events, in call order.
    def audited_two(ctx, args), do: audited(ctx, args)

    def events_only(_ctx, _args) do
      update = ContextUpdate.log_event(ContextUpdate.new(), :tool_call, %{id: "events_only"})
      {:ok, "no deps here", update}
    end

    defp staged_events, do: :persistent_term.get({__MODULE__, :events}, [])
  end

  setup do
    Application.put_env(:nous, :model_dispatcher, Dispatcher)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)

      for key <- [{Dispatcher, :calls}, {Dispatcher, :tool_calls}, {AuditedTools, :events}] do
        :persistent_term.erase(key)
      end
    end)

    :ok
  end

  defp stage_tool_calls(calls) do
    :persistent_term.put({Dispatcher, :calls}, 0)
    :persistent_term.put({Dispatcher, :tool_calls}, calls)
  end

  defp stage_events(events), do: :persistent_term.put({AuditedTools, :events}, events)

  defp call(id, name), do: %{"id" => id, "name" => name, "arguments" => %{}}

  defp run(tools, opts \\ []) do
    agent = Agent.new("openai:test-model", Keyword.merge([tools: tools], opts))
    {:ok, result} = AgentRunner.run(agent, "go", deps: %{starting: :deps})
    result
  end

  defp logged_tool_calls(result) do
    result.context.log
    |> Log.events()
    |> Enum.filter(&(&1.type == :tool_call))
  end

  # `created_at` is wall-clock and differs between two runs by construction.
  # Every other byte of every message must match.
  defp without_timestamps(messages), do: Enum.map(messages, &Map.delete(&1, :created_at))

  describe "a tool's :log_event on the sequential path" do
    test "lands in the session log while messages stay byte-identical to the no-event run" do
      stage_events([%{id: "sub_1", name: "inner_tool"}])
      stage_tool_calls([call("call_1", "audited")])
      audited = run([&AuditedTools.audited/2])

      stage_events([])
      stage_tool_calls([call("call_1", "audited")])
      plain = run([&AuditedTools.audited/2])

      # Recorded ...
      assert [%{data: %{id: "sub_1", name: "inner_tool"}}] = logged_tool_calls(audited)
      assert logged_tool_calls(plain) == []

      # ... and outside model history. Both halves, or this proves nothing.
      assert without_timestamps(audited.context.messages) ==
               without_timestamps(plain.context.messages)

      assert without_timestamps(audited.all_messages) == without_timestamps(plain.all_messages)

      # The deps operation in the same update still merged, so the event did not
      # cost the update its other half.
      assert audited.deps.audited_ran == true
      assert audited.deps.starting == :deps
    end

    test "every event is logged exactly once, in the order the tool added them" do
      stage_events([%{seq: 1}, %{seq: 2}, %{seq: 3}])
      stage_tool_calls([call("call_1", "audited")])

      result = run([&AuditedTools.audited/2])

      assert Enum.map(logged_tool_calls(result), & &1.data.seq) == [1, 2, 3]
    end

    test "an events-only update records the event without touching deps" do
      stage_tool_calls([call("call_1", "events_only")])

      result = run([&AuditedTools.events_only/2])

      assert [%{data: %{id: "events_only"}}] = logged_tool_calls(result)
      assert result.deps == %{starting: :deps}
    end
  end

  describe "a tool's :log_event on the parallel path" do
    test "both calls' events are logged once each, in call order" do
      stage_events([%{id: "sub"}])
      stage_tool_calls([call("call_1", "audited"), call("call_2", "audited_two")])

      result =
        run([&AuditedTools.audited/2, &AuditedTools.audited_two/2], parallel_tool_calls: true)

      # The fan-out completes in whatever order it likes; the post stage runs in
      # call order, and that is the order the audit trail must show.
      assert [%{seq: first}, %{seq: second}] = logged_tool_calls(result)
      assert first < second
      assert length(logged_tool_calls(result)) == 2

      assert Enum.map(result.all_messages, & &1.role) |> Enum.count(&(&1 == :tool)) == 2
    end
  end

  describe "the legacy deps paths are unchanged" do
    test "a tool returning no update leaves the log free of tool_call events" do
      stage_tool_calls([call("call_1", "plain")])

      plain =
        Tool.from_function(fn _ctx, _args -> "plain result" end,
          name: "plain",
          description: "returns a string and nothing else"
        )

      result = run([plain])

      assert logged_tool_calls(result) == []
      assert result.deps == %{starting: :deps}
    end
  end

  describe "the parallel batch ceiling" do
    # The outer async_stream timeout is the only bound on a tool that declares
    # none, so it must be derived from the tools in the batch rather than fixed:
    # a constant would clip `bash`'s ~2-minute budget and replace its own
    # "Command timed out after Nms" with an opaque outer kill.
    test "derives from the tool's own timeout, so a long-budget tool is not clipped" do
      slow = %Tool{Tool.from_function(fn _ctx, _args -> :ok end, name: "slow") | timeout: 90_000}

      ceiling = ToolExecution.batch_call_timeout([call("call_1", "slow")], [slow])

      assert ceiling > slow.timeout * (slow.retries + 1)
    end

    test "the real Bash tool keeps headroom over its own deadline" do
      bash = Tool.from_module(Nous.Tools.Bash)

      assert ToolExecution.batch_call_timeout([call("call_1", "bash")], [bash]) > bash.timeout
    end

    test "a batch takes the largest budget in it, and the module default when a tool is unknown" do
      short = %Tool{Tool.from_function(fn _ctx, _args -> :ok end, name: "short") | timeout: 10}
      long = %Tool{Tool.from_function(fn _ctx, _args -> :ok end, name: "long") | timeout: 90_000}

      calls = [call("call_1", "short"), call("call_2", "long")]

      assert ToolExecution.batch_call_timeout(calls, [short, long]) ==
               ToolExecution.batch_call_timeout([call("call_2", "long")], [long])

      # An unknown name has nothing bounding it from the inside, so it must not
      # shrink the ceiling below the module default.
      assert ToolExecution.batch_call_timeout([call("call_3", "mystery")], [short]) ==
               ToolExecution.default_call_timeout_ms()
    end
  end
end

defmodule Nous.Eval.TraceHelpersTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Trace
  alias Nous.Eval.Trace.{AgentRun, Event, GuardVerdict, ModelCall, ToolCall}
  alias Nous.Eval.TraceBuilder, as: B

  @root "aaaaaaaaaaaaaaaa"
  @child "bbbbbbbbbbbbbbbb"
  @grandchild "cccccccccccccccc"

  # Root delegates to a "researcher" sub-agent, which delegates once more.
  defp tree_trace do
    B.new()
    |> B.run_start(@root)
    |> B.tool_call(@root, "search", %{"q" => "a"}, id: "r1", iteration: 1)
    |> B.tool_start(@root, "r2", "delegate_task", %{"task" => "dig"}, iteration: 2)
    |> B.run_start(@child,
      parent: @root,
      parent_tool_call_id: "r2",
      sub_agent_template: "researcher"
    )
    |> B.tool_call(@child, "fetch", %{"url" => "x"}, id: "c1", iteration: 1)
    |> B.run_start(@grandchild,
      parent: @child,
      parent_tool_call_id: "c2",
      sub_agent_template: "summarizer"
    )
    |> B.tool_call(@grandchild, "summarize", %{}, id: "g1", iteration: 1)
    |> B.run_stop(@grandchild)
    |> B.run_stop(@child)
    |> B.tool_stop(@root, "r2", "delegate_task", result: "done")
    |> B.run_stop(@root)
    |> B.build()
  end

  describe "tool_calls/2" do
    test "pairs start and stop on tool_call_id, in request order" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.tool_start(@root, "a", "search", %{"q" => 1}, iteration: 1)
        |> B.tool_start(@root, "b", "lookup", %{"id" => 2}, iteration: 1)
        |> B.tool_stop(@root, "b", "lookup", result: "B")
        |> B.tool_stop(@root, "a", "search", result: "A")
        |> B.build()

      assert [
               %ToolCall{
                 id: "a",
                 name: "search",
                 result: "A",
                 outcome: :executed,
                 batch: {@root, 1}
               },
               %ToolCall{
                 id: "b",
                 name: "lookup",
                 result: "B",
                 approval: :not_required,
                 iteration: 1
               }
             ] = Trace.tool_calls(trace)
    end

    test "an edited call reports the arguments it ran with" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.tool_call(@root, "pay", %{"amount" => 500},
          id: "p",
          approval: :edited,
          arguments: %{"amount" => 50}
        )
        |> B.build()

      assert [%ToolCall{arguments: %{"amount" => 50}, original_arguments: %{"amount" => 500}}] =
               Trace.tool_calls(trace)
    end

    test "a start without a stop is :incomplete and only counted when included" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.tool_call(@root, "search", %{}, id: "done")
        |> B.tool_start(@root, "killed", "slow", %{})
        |> B.build()

      assert ["done"] = trace |> Trace.tool_calls() |> Enum.map(& &1.id)

      assert [%ToolCall{id: "done"}, %ToolCall{id: "killed", outcome: :incomplete, approval: nil}] =
               Trace.tool_calls(trace, include: :all)

      assert [%ToolCall{id: "killed"}] = Trace.tool_calls(trace, include: [:incomplete])
    end

    test "default include drops failed and denied attempts" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.tool_call(@root, "a", %{}, outcome: :hook_denied)
        |> B.tool_call(@root, "b", %{}, outcome: :not_found)
        |> B.tool_call(@root, "c", %{})
        |> B.build()

      assert ["c"] = trace |> Trace.tool_calls() |> Enum.map(& &1.name)
      assert ["a", "b", "c"] = trace |> Trace.tool_calls(include: :all) |> Enum.map(& &1.name)
      assert ["a"] = trace |> Trace.tool_calls(include: [:hook_denied]) |> Enum.map(& &1.name)
    end

    test "scope selects runs of the tree" do
      trace = tree_trace()
      ids = fn opts -> trace |> Trace.tool_calls(opts) |> Enum.map(& &1.id) end

      assert ids.([]) == ["r1", "r2"]
      assert ids.(scope: :tree) == ["r1", "r2", "c1", "g1"]
      assert ids.(scope: {:sub_agent, "researcher"}) == ["c1"]
      assert ids.(scope: {:run, @grandchild}) == ["g1"]

      assert [%ToolCall{parent_agent_run_id: @root}] =
               Trace.tool_calls(trace, scope: {:run, @child})
    end

    test "ignores malformed and unknown events" do
      good = B.new() |> B.run_start(@root) |> B.tool_call(@root, "ok", %{}, id: "g") |> B.build()

      junk = [
        :not_an_event,
        %Event{name: [:nous, :agent, :tool_call, :start], metadata: nil, at: 0, seq: 90},
        %Event{name: "tool_call", metadata: %{tool_call_id: "x"}, at: 0, seq: 91},
        %Event{
          name: [:nous, :agent, :tool_call, :start],
          metadata: %{tool_call_id: 7},
          at: 0,
          seq: 92
        },
        %Event{
          name: [:nous, :agent, :tool_call, :stop],
          metadata: %{tool_call_id: "g", outcome: :exploded},
          at: 0,
          seq: 93
        },
        %Event{name: [:nous, :other, :thing], metadata: %{}, measurements: nil, at: 0, seq: 94}
      ]

      trace = %Trace{good | events: good.events ++ junk}
      assert [%ToolCall{id: "g", outcome: :executed}] = Trace.tool_calls(trace, include: :all)
      assert Trace.model_calls(trace) == []
      assert Trace.guard_verdicts(trace) == []
      assert [%AgentRun{agent_run_id: @root}] = Trace.runs(trace)
    end
  end

  describe "runs/1" do
    test "builds the run tree with status" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.run_start(@child,
          parent: @root,
          parent_tool_call_id: "r2",
          sub_agent_template: "researcher"
        )
        |> B.run_exception(@child, :boom)
        |> B.run_start(@grandchild, parent: @root)
        |> B.run_stop(@root)
        |> B.build()

      assert [
               %AgentRun{
                 agent_run_id: @root,
                 status: :ok,
                 children: [@child, @grandchild],
                 role: :agent
               },
               %AgentRun{
                 agent_run_id: @child,
                 status: :error,
                 error: :boom,
                 parent_tool_call_id: "r2",
                 sub_agent_template: "researcher"
               },
               %AgentRun{agent_run_id: @grandchild, status: :incomplete, children: []}
             ] = Trace.runs(trace)

      assert Trace.root_run_id(trace) == @root
    end
  end

  describe "model_calls/1 and usage/1" do
    test "pairs requests with their stop or exception and sums usage over the tree" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.model_start(@root, iteration: 1)
        |> B.model_stop(@root,
          iteration: 1,
          usage: %{input_tokens: 100, output_tokens: 20},
          tool_calls: 1
        )
        |> B.run_start(@child, parent: @root)
        |> B.model_start(@child,
          iteration: 1,
          model_provider: :anthropic,
          model_name: "claude-haiku-4-5"
        )
        |> B.model_stop(@child,
          iteration: 1,
          model_provider: :anthropic,
          model_name: "claude-haiku-4-5",
          usage: %{input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 3}
        )
        |> B.model_start(@root, iteration: 2)
        |> B.model_exception(@root, :rate_limited, iteration: 2)
        |> B.model_start(@root, iteration: 3)
        |> B.build()

      assert [
               %ModelCall{
                 agent_run_id: @root,
                 outcome: :ok,
                 iteration: 1,
                 usage: %{input_tokens: 100}
               },
               %ModelCall{
                 agent_run_id: @child,
                 outcome: :ok,
                 parent_agent_run_id: @root,
                 active_model_provider: :anthropic
               },
               %ModelCall{agent_run_id: @root, outcome: :error, error: {:error, :rate_limited}},
               %ModelCall{agent_run_id: @root, outcome: :incomplete, iteration: 3}
             ] = Trace.model_calls(trace)

      assert %Nous.Usage{
               requests: 2,
               tool_calls: 1,
               input_tokens: 110,
               output_tokens: 25,
               total_tokens: 135,
               cache_read_input_tokens: 3
             } = Trace.usage(trace)
    end
  end

  describe "guard_verdicts/2" do
    test "keeps one verdict per DecisionGuard decision and labels other hooks" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.decision_guard_verdict(@root, :user_input, :allow)
        |> B.decision_guard_verdict(@root, :tool_call, :deny, tool_call_id: "t1")
        |> B.hook_decision(@root, "my_policy", :escalate, event: :pre_tool_use)
        |> B.input_guard_verdict(@root, :suspicious, :warn)
        |> B.loop_guard_advisory(@root)
        |> B.build()

      assert [
               %GuardVerdict{guard: :decision_guard, surface: :user_input, verdict: :allow},
               %GuardVerdict{
                 guard: :decision_guard,
                 surface: :tool_call,
                 verdict: :deny,
                 action: :deny,
                 tool_call_id: "t1"
               },
               %GuardVerdict{guard: :hook, surface: :pre_tool_use, verdict: :escalate},
               %GuardVerdict{guard: :input_guard, verdict: :suspicious, action: :warn},
               %GuardVerdict{guard: :loop_guard, verdict: :advisory}
             ] = Trace.guard_verdicts(trace)

      assert [_, _] = Trace.guard_verdicts(trace, guard: :decision_guard)

      assert [%GuardVerdict{guard: :input_guard}] =
               Trace.guard_verdicts(trace, guard: :input_guard)
    end
  end

  describe "output_retries/2" do
    test "lists structured output retries per scope" do
      trace =
        B.new()
        |> B.run_start(@root)
        |> B.output_retry(@root, 1)
        |> B.run_start(@child, parent: @root)
        |> B.output_retry(@child, 1)
        |> B.output_retry(@child, 2)
        |> B.build()

      assert [%{agent_run_id: @root, attempt: 1, retries_left: 2, errors: "name: can't be blank"}] =
               Trace.output_retries(trace, scope: :root)

      assert length(Trace.output_retries(trace)) == 3
    end
  end

  describe "transcript/2" do
    test "rebuilds the failed run's messages from its last request" do
      first = [Nous.Message.system("sys"), Nous.Message.user("refund order 1")]

      response =
        Nous.Message.assistant("",
          tool_calls: [%{id: "t1", name: "lookup", arguments: %{"id" => 1}}]
        )

      trace =
        B.new()
        |> B.run_start(@root)
        |> B.model_start(@root, iteration: 1, messages: first)
        |> B.model_stop(@root, iteration: 1, response: response)
        |> B.tool_call(@root, "lookup", %{"id" => 1}, id: "t1", result: %{"status" => "shipped"})
        |> B.run_exception(@root, :max_iterations_exceeded)
        |> B.build()

      assert [
               %Nous.Message{role: :system},
               %Nous.Message{role: :user, content: "refund order 1"},
               %Nous.Message{role: :assistant, tool_calls: [_]},
               %Nous.Message{role: :tool, tool_call_id: "t1", name: "lookup", content: content}
             ] = Trace.transcript(trace)

      assert JSON.decode!(content) == %{"status" => "shipped"}
    end

    test "is empty when the run made no model request" do
      trace = B.new() |> B.run_start(@root) |> B.run_exception(@root, :bad) |> B.build()
      assert Trace.transcript(trace) == []
    end
  end
end

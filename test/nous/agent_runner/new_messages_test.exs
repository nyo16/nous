defmodule Nous.AgentRunner.NewMessagesTest do
  # R3: `result.new_messages` used to be "the transcript from its first
  # assistant message on": cumulative on every continued or history-seeded run,
  # and missing the run's own user prompt on turn 1. It is now exactly what the
  # run appended to the session log, prompt included.
  use ExUnit.Case, async: true

  alias Nous.{Agent, AgentRunner, Message, Tool, Usage}
  alias Nous.Agent.Context

  @moduletag :capture_log

  # Replies "answer to <last user text>" ("answer to the summary" once
  # compaction removed every user message); a prompt containing "[tool]" first
  # gets a call to the `noop` tool.
  defmodule Stub do
    @moduledoc false

    def request(_model, messages, _settings) do
      last = messages |> Enum.reject(&(&1.role == :system)) |> List.last()

      asked =
        case messages |> Enum.filter(&(&1.role == :user)) |> List.last() do
          nil -> "the summary"
          user -> Message.extract_text(user)
        end

      parts =
        if last.role == :user and Message.extract_text(last) =~ "[tool]" do
          [
            {:tool_call,
             %{id: "call_#{System.unique_integer([:positive])}", name: "noop", arguments: %{}}}
          ]
        else
          [{:text, "answer to #{asked}"}]
        end

      {:ok,
       Message.from_legacy(%{
         parts: parts,
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end
  end

  # Compacts once, on the request that follows a tool result: replaces the
  # message range in `deps[:compact_range]` with a summary, as Summarization
  # would.
  defmodule Compactor do
    @moduledoc false
    @behaviour Nous.Plugin

    @impl true
    def before_request(_agent, ctx, tools) do
      case {List.last(ctx.messages), ctx.deps[:compact_range]} do
        {%Message{role: :tool}, {first, last}} ->
          ctx = Context.replace_message_range(ctx, first, last, Message.system("[summary]"))
          {%{ctx | deps: Map.delete(ctx.deps, :compact_range)}, tools}

        _ ->
          {ctx, tools}
      end
    end
  end

  # Writes `ctx.messages` directly on the run's first request, the legacy
  # pattern that makes the context re-seed its log on the next append.
  defmodule Rewriter do
    @moduledoc false
    @behaviour Nous.Plugin

    @impl true
    def before_request(_agent, ctx, tools) do
      if ctx.deps[:rewrite] do
        messages = ctx.messages ++ [Message.system("note")]
        {%{ctx | messages: messages, deps: Map.delete(ctx.deps, :rewrite)}, tools}
      else
        {ctx, tools}
      end
    end
  end

  setup do
    Nous.ModelDispatcher.put_dispatcher(Stub)
    noop = Tool.from_function(fn _ctx, _args -> "done" end, name: "noop", description: "No-op")
    %{agent: Agent.new("openai:test-model", instructions: "SYS", tools: [noop])}
  end

  defp show(messages) do
    Enum.map(messages, fn
      %Message{role: :assistant, tool_calls: [_ | _]} -> {:assistant, :tool_call}
      %Message{role: :tool} -> {:tool, "done"}
      %Message{role: role} = m -> {role, Message.extract_text(m)}
    end)
  end

  test "turn 1 includes its own user prompt and nothing before it", %{agent: agent} do
    {:ok, r1} = AgentRunner.run(agent, "q1")

    assert show(r1.new_messages) == [user: "q1", assistant: "answer to q1"]
    assert r1.new_messages_truncated? == false
  end

  test "a continued run returns only its own turn", %{agent: agent} do
    {:ok, r1} = AgentRunner.run(agent, "q1")
    {:ok, r2} = AgentRunner.run(agent, "q2", context: r1.context)
    {:ok, r3} = AgentRunner.run(agent, "q3 [tool]", context: r2.context)

    assert show(r2.new_messages) == [user: "q2", assistant: "answer to q2"]

    assert show(r3.new_messages) == [
             {:user, "q3 [tool]"},
             {:assistant, :tool_call},
             {:tool, "done"},
             {:assistant, "answer to q3 [tool]"}
           ]

    assert r3.new_messages_truncated? == false
  end

  test "run_with_context returns the pending user message and the reply", %{agent: agent} do
    {:ok, r1} = AgentRunner.run(agent, "q1")
    ctx = Context.add_message(r1.context, Message.user("q2"))

    {:ok, w2} = AgentRunner.run_with_context(agent, ctx)

    assert show(w2.new_messages) == [user: "q2", assistant: "answer to q2"]
  end

  test "the concatenated new_messages of every run is the conversation", %{agent: agent} do
    {:ok, r1} = AgentRunner.run(agent, "q1")
    {:ok, r2} = AgentRunner.run(agent, "q2", message_history: r1.new_messages)

    {:ok, r3} =
      AgentRunner.run(agent, "q3", message_history: r1.new_messages ++ r2.new_messages)

    assert show(r3.all_messages) == [
             system: "SYS",
             user: "q1",
             assistant: "answer to q1",
             user: "q2",
             assistant: "answer to q2",
             user: "q3",
             assistant: "answer to q3"
           ]
  end

  test ":message_history is history, not part of the run", %{agent: agent} do
    history = [Message.user("old q"), Message.assistant("old a")]

    {:ok, h} = AgentRunner.run(agent, "q-new", message_history: history)

    assert show(h.new_messages) == [user: "q-new", assistant: "answer to q-new"]
  end

  test "messages: returns the trailing user message and the reply", %{agent: agent} do
    history = [Message.user("old q"), Message.assistant("old a")]

    {:ok, m} = Nous.run(agent, messages: history ++ [Message.user("q-new")])

    assert show(m.new_messages) == [user: "q-new", assistant: "answer to q-new"]
  end

  test "compaction that swallows the run's prompt returns the surviving tail, flagged",
       %{agent: agent} do
    agent = %{agent | plugins: [Compactor]}
    {:ok, r1} = AgentRunner.run(agent, "q1")

    # Transcript at the second request: [SYS, q1, answer, q2, call, result];
    # positions 1..3 cover the earlier turn and this run's prompt.
    ctx = %{r1.context | deps: Map.put(r1.context.deps, :compact_range, {1, 3})}
    {:ok, r2} = AgentRunner.run(agent, "q2 [tool]", context: ctx)

    assert show(r2.all_messages) |> Enum.take(2) == [system: "SYS", system: "[summary]"]

    assert show(r2.new_messages) == [
             {:assistant, :tool_call},
             {:tool, "done"},
             {:assistant, "answer to the summary"}
           ]

    assert r2.new_messages_truncated? == true
  end

  test "compaction of earlier turns only is not part of the run", %{agent: agent} do
    agent = %{agent | plugins: [Compactor]}
    {:ok, r1} = AgentRunner.run(agent, "q1")

    ctx = %{r1.context | deps: Map.put(r1.context.deps, :compact_range, {1, 2})}
    {:ok, r2} = AgentRunner.run(agent, "q2 [tool]", context: ctx)

    assert show(r2.new_messages) == [
             {:user, "q2 [tool]"},
             {:assistant, :tool_call},
             {:tool, "done"},
             {:assistant, "answer to q2 [tool]"}
           ]

    assert r2.new_messages_truncated? == false
  end

  test "a transcript written around the log falls back to the last user turn, flagged",
       %{agent: agent} do
    agent = %{agent | plugins: [Rewriter]}
    {:ok, r1} = AgentRunner.run(agent, "q1")

    ctx = %{r1.context | deps: Map.put(r1.context.deps, :rewrite, true)}
    {:ok, r2} = AgentRunner.run(agent, "q2", context: ctx)

    assert show(r2.new_messages) == [user: "q2", system: "note", assistant: "answer to q2"]
    assert r2.new_messages_truncated? == true
  end
end

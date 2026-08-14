defmodule Nous.Session.D2MessageContractTest do
  @moduledoc """
  The D2 gate: `messages` stays backward compatible **in and out**.

  Plan 03 replaces the flat `ctx.messages` list with an append-only event log
  whose model-visible surface is a pure fold. The hard constraint is that no
  caller can tell. This file is the instrument that proves it, and per the plan
  it was written and confirmed green against the **pre-log implementation**
  before `Nous.Agent.Context` was touched — a regression test authored after the
  refactor would only prove the refactor is self-consistent.

  What is pinned, deliberately:

    * every field of every message in `result.all_messages`, in order, for a
      complete tool-calling run — role, content, tool_calls, tool_call_id, name.
      `created_at` is excluded from equality (it is wall-clock) but asserted
      present and non-decreasing, because ordering is part of the contract.
    * `result.messages`, `result.all_messages` and `result.new_messages` keep
      their documented relationships (`AGENTS.md` documents `result.messages`).
    * `ctx.messages` is the same list the result exposes, since plugins and
      user code read it directly.
    * seeding through `Nous.run(agent, messages: [...])` round-trips.
    * continuing from a returned context appends rather than restarts.
    * `Context.serialize/1` output stays readable and folds back to the same
      messages.

  If a change to the log makes any of these fail, the change is wrong, not the
  test. The only legitimate edit here is adding cases.
  """

  # async: true is safe: the dispatcher override is process-scoped
  # (Nous.ModelDispatcher.put_dispatcher/1) and propagates via $callers, so no
  # application environment is touched.
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.{Message, Tool, Usage}

  @moduletag :capture_log

  # Two-step run: the first response calls a tool, the second concludes. That is
  # the shape that exercises every message role the surface fold has to project.
  defmodule ToolThenTextDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      # Count assistant turns already in the transcript to decide what to say
      # next; this keeps the stub stateless, so `async: true` holds.
      assistant_turns = Enum.count(messages, &(&1.role == :assistant))

      response =
        if assistant_turns == 0 do
          Message.assistant("",
            tool_calls: [
              # The internal, provider-normalized shape: flat, not OpenAI's
              # nested `function` wrapper (the provider layer flattens before
              # the runner ever sees it).
              %{"id" => "call_fixed_1", "name" => "echo", "arguments" => %{"text" => "hello"}}
            ]
          )
        else
          Message.assistant("done: hello")
        end

      usage = %Usage{input_tokens: 11, output_tokens: 7, total_tokens: 18, requests: 1}
      {:ok, %{response | metadata: %{usage: usage}}}
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 42
  end

  defp echo_tool do
    %Tool{
      name: "echo",
      description: "Echo the text back",
      parameters: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      function: fn _ctx, %{"text" => text} -> "echoed:#{text}" end
    }
  end

  defp agent(opts \\ []) do
    Nous.new(
      "openai:gpt-4o",
      Keyword.merge(
        [
          name: "d2-contract",
          system_prompt: "You are terse.",
          tools: [echo_tool()]
        ],
        opts
      )
    )
  end

  # The canonical projection. Everything that is part of the public contract,
  # nothing that is wall-clock.
  defp shape(%Message{} = msg) do
    %{
      role: msg.role,
      content: msg.content,
      tool_calls: msg.tool_calls,
      tool_call_id: msg.tool_call_id,
      name: msg.name
    }
  end

  defp shape(messages) when is_list(messages), do: Enum.map(messages, &shape/1)

  setup do
    Nous.ModelDispatcher.put_dispatcher(ToolThenTextDispatcher)
    :ok
  end

  describe "the message surface of a complete tool-calling run" do
    test "all_messages is exactly this list, in this order" do
      {:ok, result} = Nous.run(agent(), "say hello")

      assert shape(result.all_messages) == [
               %{
                 role: :system,
                 content: "You are terse.",
                 tool_calls: [],
                 tool_call_id: nil,
                 name: nil
               },
               %{
                 role: :user,
                 content: "say hello",
                 tool_calls: [],
                 tool_call_id: nil,
                 name: nil
               },
               %{
                 role: :assistant,
                 content: "",
                 tool_calls: [
                   %{
                     "id" => "call_fixed_1",
                     "name" => "echo",
                     "arguments" => %{"text" => "hello"}
                   }
                 ],
                 tool_call_id: nil,
                 name: nil
               },
               %{
                 role: :tool,
                 content: "echoed:hello",
                 tool_calls: [],
                 tool_call_id: "call_fixed_1",
                 name: "echo"
               },
               %{
                 role: :assistant,
                 content: "done: hello",
                 tool_calls: [],
                 tool_call_id: nil,
                 name: nil
               }
             ]
    end

    test "every message carries a created_at and the sequence never goes backwards" do
      {:ok, result} = Nous.run(agent(), "say hello")

      stamps = Enum.map(result.all_messages, & &1.created_at)

      assert Enum.all?(stamps, &match?(%DateTime{}, &1))
      assert stamps == Enum.sort(stamps, &(DateTime.compare(&1, &2) != :gt))
    end

    test "result.context.messages is the same list the result exposes" do
      {:ok, result} = Nous.run(agent(), "say hello")

      assert result.context.messages == result.all_messages
    end

    test "new_messages is the assistant-onward suffix of all_messages" do
      {:ok, result} = Nous.run(agent(), "say hello")

      assert result.new_messages ==
               Enum.drop_while(result.all_messages, &(&1.role != :assistant))

      assert shape(result.new_messages) |> Enum.map(& &1.role) == [:assistant, :tool, :assistant]
    end

    test "output is the final assistant content" do
      {:ok, result} = Nous.run(agent(), "say hello")

      assert result.output == "done: hello"
      assert List.last(result.all_messages).content == "done: hello"
    end

    test "usage accumulates across both model requests" do
      {:ok, result} = Nous.run(agent(), "say hello")

      # Two requests at 18 tokens each; the tool call is counted separately.
      assert result.usage.requests == 2
      assert result.usage.total_tokens == 36
      assert result.usage.tool_calls == 1
    end
  end

  describe "messages in" do
    test "run/3 with :messages seeds the transcript and folds back to it" do
      seeded = [
        Message.system("seeded system"),
        Message.user("seeded user"),
        Message.assistant("seeded assistant")
      ]

      {:ok, result} = Nous.run(agent(system_prompt: nil), messages: seeded)

      # The seeded prefix survives verbatim, in order, at the head.
      assert shape(Enum.take(result.all_messages, 3)) == shape(seeded)
    end

    test "continuing from a returned context appends instead of restarting" do
      {:ok, first} = Nous.run(agent(), "say hello")
      {:ok, second} = Nous.run(agent(), "again", context: first.context)

      assert length(second.all_messages) > length(first.all_messages)

      # The first run's transcript is still the prefix of the second's.
      assert shape(Enum.take(second.all_messages, length(first.all_messages))) ==
               shape(first.all_messages)

      assert Enum.any?(second.all_messages, &(&1.role == :user and &1.content == "again"))
    end
  end

  describe "serialization" do
    test "a serialized context round-trips to the same message surface" do
      {:ok, result} = Nous.run(agent(), "say hello")

      serialized = Context.serialize(result.context)
      {:ok, restored} = Context.deserialize(serialized)

      assert shape(restored.messages) == shape(result.all_messages)
    end

    test "serialize/1 keeps a message list a v1 reader can consume" do
      {:ok, result} = Nous.run(agent(), "say hello")

      serialized = Context.serialize(result.context)

      assert is_list(serialized.messages)
      assert length(serialized.messages) == length(result.all_messages)

      roles = Enum.map(serialized.messages, &(&1[:role] || &1["role"]))
      assert roles == [:system, :user, :assistant, :tool, :assistant]
    end
  end
end

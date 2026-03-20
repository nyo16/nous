defmodule Nous.Plugins.SummarizationTest do
  use ExUnit.Case, async: true

  alias Nous.Agent
  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Plugins.Summarization

  setup do
    agent =
      Agent.new("openai:gpt-4",
        plugins: [Summarization],
        instructions: "Be helpful"
      )

    %{agent: agent}
  end

  describe "init/2" do
    test "initializes with default config", %{agent: agent} do
      ctx = Context.new(deps: %{})
      ctx = Summarization.init(agent, ctx)

      config = ctx.deps[:summarization_config]
      assert config[:max_context_tokens] == 100_000
      assert config[:keep_recent] == 10
      assert config[:summary_count] == 0
      assert config[:summary_model] == nil
    end

    test "respects custom config", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{
            summarization_config: %{
              max_context_tokens: 50_000,
              keep_recent: 5,
              summary_model: "openai:gpt-4o-mini"
            }
          }
        )

      ctx = Summarization.init(agent, ctx)
      config = ctx.deps[:summarization_config]

      assert config[:max_context_tokens] == 50_000
      assert config[:keep_recent] == 5
      assert config[:summary_model] == "openai:gpt-4o-mini"
    end
  end

  describe "before_request/3 — threshold" do
    test "does not trigger when under token threshold", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 100_000}},
          usage: %Nous.Usage{total_tokens: 50_000}
        )

      ctx = Summarization.init(agent, ctx)

      # Add a few messages
      ctx = Context.add_message(ctx, Message.user("Hello"))
      ctx = Context.add_message(ctx, Message.assistant("Hi!"))

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Messages should be unchanged
      assert length(result_ctx.messages) == length(ctx.messages)
    end

    test "does not crash when over threshold but too few messages to summarize", %{agent: agent} do
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 100, keep_recent: 10}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      # Add fewer messages than keep_recent
      ctx = Context.add_message(ctx, Message.user("Hello"))
      ctx = Context.add_message(ctx, Message.assistant("Hi!"))

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Should pass through unchanged (not enough to summarize)
      assert length(result_ctx.messages) == 2
    end
  end

  describe "find_safe_split — tool_call/tool_result safety" do
    test "never splits a tool_call from its tool_result", %{agent: agent} do
      # Build a conversation where a naive split would land inside a tool sequence
      messages = [
        Message.user("Search for dogs"),
        Message.assistant("Let me search",
          tool_calls: [%{id: "call_1", name: "search", arguments: %{}}]
        ),
        Message.tool("call_1", "Found dogs"),
        Message.user("Now search for cats"),
        Message.assistant("Searching cats",
          tool_calls: [%{id: "call_2", name: "search", arguments: %{}}]
        ),
        Message.tool("call_2", "Found cats"),
        Message.user("Thanks"),
        Message.assistant("You're welcome!")
      ]

      # Create context with high token count to trigger summarization
      ctx =
        Context.new(
          deps: %{summarization_config: %{max_context_tokens: 1, keep_recent: 3}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)
      ctx = %{ctx | messages: messages}

      # The summarization will try to run but fail (no real LLM),
      # so the fallback should keep all messages
      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # Check that no tool result is separated from its tool call
      result_msgs = result_ctx.messages

      Enum.with_index(result_msgs)
      |> Enum.each(fn {msg, i} ->
        if msg.role == :tool and i > 0 do
          prev = Enum.at(result_msgs, i - 1)

          # The message before a tool result should either be another tool result
          # (from the same multi-call) or the assistant message with tool_calls
          assert prev.role in [:assistant, :tool],
                 "Tool result at index #{i} is preceded by #{prev.role}"
        end
      end)
    end
  end

  describe "system message preservation" do
    test "system messages are preserved separately from conversation", %{agent: agent} do
      # Create a context with system and conversation messages
      ctx =
        Context.new(
          system_prompt: "You are helpful",
          deps: %{summarization_config: %{max_context_tokens: 1, keep_recent: 2}},
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      # Add system + conversation messages
      ctx = Context.add_message(ctx, Message.system("System instruction"))
      ctx = Context.add_message(ctx, Message.user("First question"))
      ctx = Context.add_message(ctx, Message.assistant("First answer"))
      ctx = Context.add_message(ctx, Message.user("Second question"))
      ctx = Context.add_message(ctx, Message.assistant("Second answer"))
      ctx = Context.add_message(ctx, Message.user("Third question"))
      ctx = Context.add_message(ctx, Message.assistant("Third answer"))

      # Summarization will try but fail (no LLM), so messages are preserved
      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # System messages should still be present
      system_msgs = Enum.filter(result_ctx.messages, &(&1.role == :system))
      assert length(system_msgs) >= 1
    end
  end

  describe "fallback on summarization failure" do
    test "keeps all messages when LLM call fails", %{agent: agent} do
      # Use a model that will fail (no API key)
      ctx =
        Context.new(
          deps: %{
            summarization_config: %{
              max_context_tokens: 1,
              keep_recent: 2,
              summary_model: "openai:gpt-4o-mini"
            }
          },
          usage: %Nous.Usage{total_tokens: 200}
        )

      ctx = Summarization.init(agent, ctx)

      # Add enough messages to trigger summarization
      ctx = Context.add_message(ctx, Message.user("Q1"))
      ctx = Context.add_message(ctx, Message.assistant("A1"))
      ctx = Context.add_message(ctx, Message.user("Q2"))
      ctx = Context.add_message(ctx, Message.assistant("A2"))
      ctx = Context.add_message(ctx, Message.user("Q3"))
      ctx = Context.add_message(ctx, Message.assistant("A3"))

      original_count = length(ctx.messages)

      {result_ctx, _tools} = Summarization.before_request(agent, ctx, [])

      # On failure, all messages should be preserved
      assert length(result_ctx.messages) == original_count
    end
  end
end

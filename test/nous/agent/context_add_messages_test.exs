defmodule Nous.Agent.ContextAddMessagesTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Message

  describe "add_messages/2 equivalence with repeated add_message/2" do
    test "produces identical messages order and needs_response" do
      msgs = [
        Message.user("a"),
        Message.assistant("b"),
        Message.system("c"),
        Message.user("d")
      ]

      bulk = Context.add_messages(Context.new(), msgs)
      folded = Enum.reduce(msgs, Context.new(), &Context.add_message(&2, &1))

      assert bulk.messages == folded.messages
      assert bulk.needs_response == folded.needs_response
    end

    test "appends to existing messages, preserving order" do
      ctx = Context.add_message(Context.new(), Message.user("first"))
      ctx = Context.add_messages(ctx, [Message.assistant("second"), Message.user("third")])

      assert Enum.map(ctx.messages, & &1.content) == ["first", "second", "third"]
    end

    test "needs_response follows the last message that sets it (system passes through)" do
      # Last message is a system message → needs_response stays as the prior
      # user message set it (true), matching the per-item reduce semantics.
      ctx =
        Context.add_messages(Context.new(), [Message.user("hi"), Message.system("note")])

      assert ctx.needs_response == true

      # Last non-system is an assistant final answer → needs_response false.
      ctx2 =
        Context.add_messages(Context.new(), [
          Message.user("hi"),
          Message.assistant("done"),
          Message.system("note")
        ])

      assert ctx2.needs_response == false
    end

    test "empty list is a no-op" do
      ctx = Context.add_message(Context.new(), Message.user("only"))
      assert Context.add_messages(ctx, []).messages == ctx.messages
    end
  end
end

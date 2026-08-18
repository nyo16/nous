defmodule Nous.Agent.ContextTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.{Message, Usage}
  alias Nous.Session.Log

  # The examples use bare `Context`/`Message`/`Usage`, which resolve only
  # through the aliases above.
  doctest Context

  describe "the log field" do
    test "a fresh context carries an empty log, not nil" do
      ctx = Context.new()

      assert %Log{} = ctx.log
      assert Log.count(ctx.log) == 0
      assert Log.events(ctx.log) == []
      assert ctx.messages == []
      assert ctx.system_prompt_overlay == nil
    end

    test "a hand-built %Context{} also carries an empty log" do
      # Test fixtures across the suite build the struct directly; the default
      # has to be a usable log rather than nil, or the first append crashes.
      ctx = %Context{deps: %{}}
      message = Message.user("hi")

      assert Log.count(ctx.log) == 0
      assert Context.add_message(ctx, message).messages == [message]
    end
  end

  describe "add_message/3 with :source" do
    test "marks the event without changing the projected message" do
      message = Message.system("injected")
      ctx = Context.add_message(Context.new(), message, source: :memory)

      assert [event] = Log.events(ctx.log)
      assert event.data.source == :memory
      assert ctx.messages == [message]
      # `source` is provenance for a reader of the log, not part of the message.
      refute Map.has_key?(hd(ctx.messages).metadata, :source)
    end
  end

  describe "add_message/3 with metadata that cannot be persisted" do
    @tag :capture_log
    test "keeps the message and drops the offending metadata" do
      # A pid cannot survive a restart, so the event layer rejects it at append
      # time. Losing the whole message would be a worse outcome than losing the
      # metadata, so the append is retried without it — loudly.
      ctx = Context.add_message(Context.new(), Message.user("hi", metadata: %{caller: self()}))

      assert [message] = ctx.messages
      assert message.content == "hi"
      assert message.metadata == %{}
      assert ctx.messages == Log.derive_messages(ctx.log)
    end
  end

  describe "replace_message/3" do
    test "rewrites in place and keeps the original in the log" do
      ctx =
        Context.new(messages: [Message.user("first"), Message.tool("c1", "huge", name: "read")])
        |> Context.replace_message(1, Message.tool("c1", "trimmed", name: "read"))

      assert Enum.map(ctx.messages, & &1.content) == ["first", "trimmed"]
      logged = ctx.log |> Log.events() |> Enum.map(& &1.data.content)
      assert logged == ["first", "huge", "trimmed"]
      assert ctx.messages == Log.derive_messages(ctx.log)
    end

    @tag :capture_log
    test "an index past the end of the transcript is a no-op" do
      ctx = Context.new(messages: [Message.user("only")])

      assert Context.replace_message(ctx, 7, Message.user("nope")) == ctx
    end
  end

  describe "replace_message_range/4" do
    test "the replacement takes the position of the range, not the append order" do
      ctx =
        Context.new(
          messages: [
            Message.system("sys"),
            Message.user("a"),
            Message.assistant("b"),
            Message.user("c")
          ]
        )
        |> Context.replace_message_range(1, 2, Message.system("[summary]"))

      assert Enum.map(ctx.messages, & &1.content) == ["sys", "[summary]", "c"]
      assert Log.count(ctx.log) == 5
      assert ctx.messages == Log.derive_messages(ctx.log)
    end

    test "the replacement inherits the created_at of the first message it shadows" do
      messages = [Message.user("a"), Message.assistant("b"), Message.user("c")]

      ctx =
        Context.new(messages: messages)
        |> Context.replace_message_range(0, 1, Message.system("[summary]"))

      assert hd(ctx.messages).created_at == hd(messages).created_at
    end

    @tag :capture_log
    test "a range past the end of the transcript is a no-op" do
      ctx = Context.new(messages: [Message.user("a"), Message.user("b")])

      assert Context.replace_message_range(ctx, 1, 5, Message.system("[summary]")) == ctx
    end

    test "a descending range is rejected by the guard" do
      ctx = Context.new(messages: [Message.user("a"), Message.user("b")])

      assert_raise FunctionClauseError, fn ->
        Context.replace_message_range(ctx, 1, 0, Message.system("[summary]"))
      end
    end
  end

  describe "patch_dangling_tool_calls/1" do
    test "the synthetic results are events, and needs_response is untouched" do
      ctx =
        Context.new(
          messages: [
            Message.assistant("calling", tool_calls: [%{"id" => "c1", "name" => "search"}])
          ],
          needs_response: false
        )

      patched = Context.patch_dangling_tool_calls(ctx)

      assert Enum.map(patched.messages, & &1.role) == [:assistant, :tool]
      assert Enum.map(Log.events(patched.log), & &1.type) == [:assistant_message, :tool_result]
      assert List.last(patched.messages).name == "search"
      assert patched.needs_response == false
      assert patched.messages == Log.derive_messages(patched.log)
    end
  end

  describe "usage and deps are untouched by the log" do
    test "add_usage/2 and merge_deps/2 leave messages and the log alone" do
      ctx =
        Context.new(messages: [Message.user("hi")])
        |> Context.add_usage(%Usage{total_tokens: 10})
        |> Context.merge_deps(%{key: "value"})

      assert ctx.usage.total_tokens == 10
      assert ctx.deps.key == "value"
      assert Log.count(ctx.log) == 1
      assert ctx.messages == Log.derive_messages(ctx.log)
    end
  end
end

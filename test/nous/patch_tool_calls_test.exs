defmodule Nous.Agent.PatchToolCallsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.Message

  describe "patch_dangling_tool_calls/1" do
    test "no-op when there are no dangling tool calls" do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("Let me search", tool_calls: [%{id: "call_1", name: "search"}])
        )
        |> Context.add_message(Message.tool("call_1", "search results"))

      result = Context.patch_dangling_tool_calls(ctx)

      # Messages should be unchanged
      assert length(result.messages) == 2
      assert result.messages == ctx.messages
    end

    test "injects synthetic result for a single dangling tool call" do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("Let me search", tool_calls: [%{id: "call_1", name: "search"}])
        )

      result = Context.patch_dangling_tool_calls(ctx)

      assert length(result.messages) == 2

      synthetic = Enum.find(result.messages, &(&1.role == :tool))
      assert synthetic != nil
      assert synthetic.tool_call_id == "call_1"
      assert synthetic.content =~ "interrupted"
    end

    test "handles multiple dangling tool calls" do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("Let me do multiple things",
            tool_calls: [
              %{id: "call_1", name: "search"},
              %{id: "call_2", name: "calculate"},
              %{id: "call_3", name: "fetch"}
            ]
          )
        )

      result = Context.patch_dangling_tool_calls(ctx)

      # Original assistant message + 3 synthetic tool results
      assert length(result.messages) == 4

      tool_results = Enum.filter(result.messages, &(&1.role == :tool))
      assert length(tool_results) == 3

      result_ids = Enum.map(tool_results, & &1.tool_call_id) |> MapSet.new()
      assert MapSet.equal?(result_ids, MapSet.new(["call_1", "call_2", "call_3"]))
    end

    test "does not duplicate results for already-matched calls" do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("Multiple tools",
            tool_calls: [
              %{id: "call_1", name: "search"},
              %{id: "call_2", name: "calculate"}
            ]
          )
        )
        |> Context.add_message(Message.tool("call_1", "search results"))

      result = Context.patch_dangling_tool_calls(ctx)

      # Original assistant + existing tool result + 1 synthetic
      assert length(result.messages) == 3

      tool_results = Enum.filter(result.messages, &(&1.role == :tool))
      assert length(tool_results) == 2

      # call_1 should have original content
      call_1_result = Enum.find(tool_results, &(&1.tool_call_id == "call_1"))
      assert call_1_result.content == "search results"

      # call_2 should have synthetic content
      call_2_result = Enum.find(tool_results, &(&1.tool_call_id == "call_2"))
      assert call_2_result.content =~ "interrupted"
    end

    test "works with empty message list" do
      ctx = Context.new()

      result = Context.patch_dangling_tool_calls(ctx)

      assert result.messages == []
    end

    test "handles messages with no tool calls" do
      ctx =
        Context.new()
        |> Context.add_message(Message.user("Hello"))
        |> Context.add_message(Message.assistant("Hi there!"))

      result = Context.patch_dangling_tool_calls(ctx)

      assert length(result.messages) == 2
      assert result.messages == ctx.messages
    end

    test "handles multiple assistant messages with tool calls across the conversation" do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("First search",
            tool_calls: [%{id: "call_1", name: "search"}]
          )
        )
        |> Context.add_message(Message.tool("call_1", "first results"))
        |> Context.add_message(
          Message.assistant("Second search",
            tool_calls: [%{id: "call_2", name: "search"}]
          )
        )

      # call_2 is dangling
      result = Context.patch_dangling_tool_calls(ctx)

      assert length(result.messages) == 4

      synthetic =
        Enum.find(result.messages, fn msg ->
          msg.role == :tool and msg.tool_call_id == "call_2"
        end)

      assert synthetic != nil
      assert synthetic.content =~ "interrupted"
    end

    test "handles tool calls with string-keyed id" do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("Search",
            tool_calls: [%{"id" => "call_str", "name" => "search"}]
          )
        )

      result = Context.patch_dangling_tool_calls(ctx)

      assert length(result.messages) == 2

      synthetic = Enum.find(result.messages, &(&1.role == :tool))
      assert synthetic.tool_call_id == "call_str"
    end
  end
end

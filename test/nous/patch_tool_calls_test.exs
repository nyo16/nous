defmodule Nous.Agent.PatchToolCallsTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.{Agent, AgentRunner, Message}

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

  # The unit tests above prove the patch works. These prove it is WIRED: every
  # entry point that can be handed a resumed history has to run it, or the
  # provider rejects the request with a 400 (an assistant tool call with no
  # matching result). run_stream/3 was the one that did not, so the assertion is
  # on what the provider actually received -- Bypass is the seam (`AGENTS.md`).
  describe "the streaming path patches a resumed history before the wire" do
    setup do
      %{bypass: Bypass.open()}
    end

    test "run_stream/3 answers every tool call it resumes", %{bypass: bypass} do
      body = capture_streamed_request(bypass, dangling_context(), "continue")

      assert tool_call_ids(body) == ["call_1"]
      assert tool_result_ids(body) == ["call_1"]
    end

    test "run_stream/3 answers a dangling call arriving via :message_history", %{bypass: bypass} do
      history = [
        Message.user("search for cats"),
        Message.assistant("Searching", tool_calls: [%{id: "call_h", name: "search"}])
      ]

      body = capture_streamed_request(bypass, nil, "continue", message_history: history)

      assert tool_call_ids(body) == ["call_h"]
      assert tool_result_ids(body) == ["call_h"]
    end

    # Control: a history whose calls were all answered must reach the wire
    # untouched, so a green suite cannot mean "a tool result is synthesised for
    # everything" or "the payload is rewritten wholesale".
    test "an already-answered call is not answered twice", %{bypass: bypass} do
      ctx =
        Context.new()
        |> Context.add_message(
          Message.assistant("Searching", tool_calls: [%{id: "call_1", name: "search"}])
        )
        |> Context.add_message(Message.tool("call_1", "results", name: "search"))

      body = capture_streamed_request(bypass, ctx, "continue")

      assert tool_call_ids(body) == ["call_1"]
      assert tool_result_ids(body) == ["call_1"]

      assert ["results"] =
               for(%{"role" => "tool", "content" => content} <- body["messages"], do: content)
    end
  end

  defp dangling_context do
    Context.new()
    |> Context.add_message(Message.user("search for cats"))
    |> Context.add_message(
      Message.assistant("Searching", tool_calls: [%{id: "call_1", name: "search"}])
    )
  end

  # Runs a real streamed run against Bypass and returns the decoded request body
  # the provider was handed.
  defp capture_streamed_request(bypass, ctx, prompt, opts \\ []) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:wire_body, JSON.decode!(raw)})

      sse = """
      data: {"choices":[{"delta":{"content":"ok"}}]}

      data: [DONE]

      """

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.resp(200, sse)
    end)

    agent = Agent.new("lmstudio:test-model", base_url: "http://localhost:#{bypass.port}/v1")
    opts = if ctx, do: Keyword.put(opts, :context, ctx), else: opts

    assert {:ok, stream} = AgentRunner.run_stream(agent, prompt, opts)
    assert Enum.any?(Enum.to_list(stream), &match?({:complete, _}, &1))

    assert_received {:wire_body, body}
    body
  end

  defp tool_call_ids(body) do
    for %{"tool_calls" => calls} <- body["messages"], %{"id" => id} <- calls, do: id
  end

  defp tool_result_ids(body) do
    for %{"role" => "tool", "tool_call_id" => id} <- body["messages"], do: id
  end
end

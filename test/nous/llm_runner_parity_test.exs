defmodule Nous.LLMRunnerParityTest do
  # async: true — the only shared state is the process-scoped dispatcher
  # override, and both entry points call the dispatcher inline in this process.
  use ExUnit.Case, async: true

  # P8-T2 regression net. `Nous.LLM` and `Nous.AgentRunner` deliberately run
  # different *request* loops (the LLM path has no plugins, hooks, permission
  # policy, telemetry or %Agent.Context{} — see the `Nous.LLM` moduledoc), but
  # they must share exactly one tool *executor*. They did not, and the two
  # copies had drifted on four points, every one of which is a scenario below.
  #
  # The trick that makes this a parity test rather than two independent
  # assertions: the dispatcher answers the follow-up request with the tool
  # result messages serialized as its own reply text. Whatever a loop produced
  # from executing a tool comes back out as the loop's return value, so
  # `llm_text == runner_result.output` compares the actual tool-execution
  # outcome — content, name and tool_call_id — with one equality.

  alias Nous.{Agent, AgentRunner, Errors, Message, Tool, Usage}

  import ExUnit.CaptureLog

  @model "openai:parity-model"

  defmodule ParityTools do
    @moduledoc false

    def echo(_ctx, %{"input" => input}), do: %{ok: true, echoed: input}

    def boom(_ctx, _args), do: raise("tool blew up")

    # The 3-tuple `Nous.ToolExecutor.execute/3` is documented to return. The old
    # private LLM executor matched only 2-tuples, so this raised CaseClauseError
    # straight out of Nous.generate_text/3.
    def context_update(_ctx, _args) do
      {:ok, "updated", Nous.Tool.ContextUpdate.new() |> Nous.Tool.ContextUpdate.set(:k, :v)}
    end

    # Legacy in-band context-update channel: the key must be stripped from the
    # result before the model ever sees it.
    def legacy_update(_ctx, _args), do: %{value: 1, __update_context__: %{k: :v}}

    def gated(_ctx, _args), do: "SHOULD NEVER RUN"
  end

  # One dispatcher for both loops. The scenario is picked from the user prompt,
  # which both entry points place verbatim in the message list.
  defmodule ScriptedDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      scenario = scenario(messages)
      tool_results = for %Message{role: :tool} = msg <- messages, do: msg

      if tool_results == [] or scenario == "forever" do
        {:ok, response(parts: [{:tool_call, call_for(scenario)}])}
      else
        {:ok, response(parts: [{:text, canonical(tool_results)}])}
      end
    end

    # Gemini's "already complete" tool-call fragment shape — one delta per turn
    # is enough to drive the streaming loop, and it never stops asking, which is
    # what the iteration-cap test needs.
    def request_stream(_model, _messages, _settings) do
      {:ok,
       [
         {:text_delta, "part"},
         {:tool_call_delta, %{"name" => "echo", "arguments" => %{"input" => "hi"}}},
         {:finish, "stop"}
       ]}
    end

    def count_tokens(_messages), do: 0

    # Serialize the tool-result messages into the reply. Both loops hand back
    # this string, so it is the observable output of their tool execution.
    def canonical(tool_results) do
      tool_results
      |> Enum.map(&%{content: &1.content, name: &1.name, tool_call_id: &1.tool_call_id})
      |> inspect(limit: :infinity, printable_limit: :infinity)
    end

    defp scenario(messages) do
      Enum.find_value(messages, fn
        %Message{role: :user, content: content} when is_binary(content) -> content
        _ -> nil
      end)
    end

    defp call_for("raise"), do: %{id: "c1", name: "boom", arguments: %{}}
    defp call_for("unknown"), do: %{id: "c1", name: "ghost", arguments: %{}}
    defp call_for("context_update"), do: %{id: "c1", name: "context_update", arguments: %{}}
    defp call_for("legacy_update"), do: %{id: "c1", name: "legacy_update", arguments: %{}}
    defp call_for("gated"), do: %{id: "c1", name: "gated", arguments: %{}}

    # Claude sometimes suffixes the name with XML-ish debris. The runner strips
    # it; the old LLM executor looked the raw name up and reported "unknown".
    defp call_for("dirty_name"),
      do: %{id: "c1", name: ~s(echo"foo), arguments: %{"input" => "hi"}}

    defp call_for(_), do: %{id: "c1", name: "echo", arguments: %{"input" => "hi"}}

    defp response(parts: parts) do
      Message.from_legacy(%{
        parts: parts,
        usage: %Usage{
          input_tokens: 1,
          output_tokens: 1,
          total_tokens: 2,
          tool_calls: 0,
          requests: 1
        },
        model_name: "parity-model",
        timestamp: DateTime.utc_now()
      })
    end
  end

  setup do
    Nous.ModelDispatcher.put_dispatcher(ScriptedDispatcher)

    tools = [
      Tool.from_function(&ParityTools.echo/2, name: "echo", description: "Echo the input"),
      Tool.from_function(&ParityTools.boom/2, name: "boom", description: "Always raises"),
      Tool.from_function(&ParityTools.context_update/2,
        name: "context_update",
        description: "Returns a ContextUpdate"
      ),
      Tool.from_function(&ParityTools.legacy_update/2,
        name: "legacy_update",
        description: "Uses the legacy __update_context__ key"
      ),
      Tool.from_function(&ParityTools.gated/2,
        name: "gated",
        description: "Requires approval",
        requires_approval: true
      )
    ]

    %{tools: tools}
  end

  # Run the identical scenario through both loops. The agent carries no
  # instructions so both message lists start with the same lone user message.
  defp both(prompt, tools) do
    llm = Nous.LLM.generate_text(@model, prompt, tools: tools)
    runner = AgentRunner.run(Agent.new(@model, tools: tools), prompt)
    {llm, runner}
  end

  describe "tool-execution parity" do
    test "a map-returning tool yields identical tool messages", %{tools: tools} do
      {{:ok, llm_text}, {:ok, result}} = both("echo", tools)

      assert llm_text == result.output
      assert llm_text =~ ~s(tool_call_id: "c1")
      assert llm_text =~ ~s(name: "echo")
      # The content is a JSON string inside an inspected map, so the quotes
      # arrive escaped. Asserting one key/value pair avoids depending on the
      # encoder's key order.
      assert llm_text =~ ~S(\"echoed\":\"hi\")
    end

    test "a raising tool yields the same structured error message", %{tools: tools} do
      capture_log(fn ->
        {{:ok, llm_text}, {:ok, result}} = both("raise", tools)

        assert llm_text == result.output
        # Structured formatting, not the bare `"Error: #{inspect(error)}"` the
        # private LLM executor used to emit.
        assert llm_text =~ "Tool execution failed: boom"
        assert llm_text =~ "tool blew up"
        refute llm_text =~ "Error: %Nous.Errors.ToolError"
      end)
    end

    test "an unknown tool yields the same not-found message", %{tools: tools} do
      capture_log(fn ->
        {{:ok, llm_text}, {:ok, result}} = both("unknown", tools)

        assert llm_text == result.output
        assert llm_text =~ "Tool not found: ghost"
        refute llm_text =~ "Unknown tool"
      end)
    end

    test "an XML-dirtied tool name is cleaned and executed on both paths", %{tools: tools} do
      {{:ok, llm_text}, {:ok, result}} = both("dirty_name", tools)

      assert llm_text == result.output
      # Cleaned for both the lookup and the result message's name.
      assert llm_text =~ ~s(name: "echo")
      assert llm_text =~ ~S(\"echoed\":\"hi\")
      refute llm_text =~ "not found"
    end

    test "a tool returning a ContextUpdate 3-tuple does not crash either path", %{tools: tools} do
      {{:ok, llm_text}, {:ok, result}} = both("context_update", tools)

      assert llm_text == result.output
      assert llm_text =~ ~s(content: "updated")
    end

    test "the legacy __update_context__ key is stripped on both paths", %{tools: tools} do
      {{:ok, llm_text}, {:ok, result}} = both("legacy_update", tools)

      assert llm_text == result.output
      assert llm_text =~ ~S(\"value\":1)
      refute llm_text =~ "__update_context__"
    end

    test "both loops stop at the same iteration cap with the same error", %{tools: tools} do
      capture_log(fn ->
        {llm, runner} = both("forever", tools)

        assert {:error, %Errors.MaxIterationsExceeded{max_iterations: 10}} = llm
        assert {:error, %Errors.MaxIterationsExceeded{max_iterations: 10}} = runner
      end)
    end

    # The approval gate is a documented divergence: the runner rejects at its
    # own approval stage with a friendlier message, the LLM path is rejected
    # inside ToolExecutor. What must NOT diverge is that neither executes.
    test "an approval-gated tool runs on neither path without a handler", %{tools: tools} do
      capture_log(fn ->
        {{:ok, llm_text}, {:ok, result}} = both("gated", tools)

        refute llm_text =~ "SHOULD NEVER RUN"
        refute result.output =~ "SHOULD NEVER RUN"
      end)
    end
  end

  describe "stream_text/3 iteration cap" do
    test "emits the cap as a final error event after the accumulated content",
         %{tools: tools} do
      capture_log(fn ->
        {:ok, stream} = Nous.LLM.stream_text(@model, "forever", tools: tools)
        events = Enum.to_list(stream)

        # One text chunk per turn, all yielded, then the cap — a silent :halt
        # here was indistinguishable from a conversation that simply ended.
        assert Enum.count(events, &(&1 == "part")) == 10

        assert {:error, %Errors.MaxIterationsExceeded{max_iterations: 10}} = List.last(events)
      end)
    end
  end
end

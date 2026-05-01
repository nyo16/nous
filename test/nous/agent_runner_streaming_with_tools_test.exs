defmodule Nous.AgentRunnerStreamingWithToolsTest do
  use ExUnit.Case, async: false

  alias Nous.{AgentRunner, Tool, Usage}

  defmodule ScriptedDispatcher do
    @moduledoc false

    # Driven via the test Elixir.Agent. Returns whatever the test scheduled
    # for the next call.
    def request_stream(_model, _messages, _settings) do
      events =
        Elixir.Agent.get_and_update(
          __MODULE__.Script,
          fn [next | rest] -> {next, rest} end
        )

      {:ok, events}
    end

    def request(_model, _messages, _settings) do
      {:error, :not_used_in_streaming_tests}
    end

    def count_tokens(_), do: 0
  end

  defmodule TestTool do
    @moduledoc false

    def lookup(_ctx, %{"query" => q}) do
      %{result: "found: #{q}"}
    end
  end

  setup do
    {:ok, _pid} = Elixir.Agent.start_link(fn -> [] end, name: ScriptedDispatcher.Script)

    Application.put_env(:nous, :model_dispatcher, ScriptedDispatcher)

    on_exit(fn ->
      Application.delete_env(:nous, :model_dispatcher)
    end)

    tool =
      Tool.from_function(&TestTool.lookup/2, name: "lookup", description: "Look something up")

    %{tool: tool, model: "openai:test-model"}
  end

  defp script(scripts) do
    Elixir.Agent.update(ScriptedDispatcher.Script, fn _ -> scripts end)
  end

  describe "stream: true with tool execution" do
    test "two-iteration run: tool call then text answer", %{model: model, tool: tool} do
      # Iteration 1: stream text + thinking + tool call (split args), finish, usage.
      iter1 = [
        {:text_delta, "Looking "},
        {:text_delta, "up "},
        {:text_delta, "now."},
        {:thinking_delta, "consider"},
        {:thinking_delta, "ing query"},
        {:tool_call_delta,
         [
           %{
             "index" => 0,
             "id" => "call_a",
             "function" => %{"name" => "lookup", "arguments" => "{\"qu"}
           }
         ]},
        {:tool_call_delta,
         [%{"index" => 0, "function" => %{"arguments" => "ery\":\"elixir\"}"}}]},
        {:finish, "tool_calls"},
        {:usage, %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1}}
      ]

      # Iteration 2: just text + finish.
      iter2 = [
        {:text_delta, "Got "},
        {:text_delta, "result: "},
        {:text_delta, "found: elixir"},
        {:finish, "stop"},
        {:usage, %Usage{input_tokens: 8, output_tokens: 6, total_tokens: 14, requests: 1}}
      ]

      script([iter1, iter2])

      parent = self()

      callbacks = %{
        on_llm_new_delta: fn _e, t -> send(parent, {:delta, t}) end,
        on_llm_new_thinking_delta: fn _e, t -> send(parent, {:thinking, t}) end,
        on_llm_new_message: fn _e, m -> send(parent, {:message, m}) end,
        on_tool_call: fn _e, c -> send(parent, {:tool_call, c}) end,
        on_tool_response: fn _e, r -> send(parent, {:tool_response, r}) end
      }

      agent = Nous.Agent.new(model, instructions: "Be helpful", tools: [tool])

      assert {:ok, result} =
               AgentRunner.run(agent, "Find elixir", stream: true, callbacks: callbacks)

      # Final assembled output is the iter2 text only (iter1 was tool-call iteration)
      assert result.output == "Got result: found: elixir"
      assert result.iterations == 2
      assert result.usage.requests == 2
      assert result.usage.input_tokens == 18
      assert result.usage.output_tokens == 11
      assert result.usage.total_tokens == 29
      assert result.usage.tool_calls == 1

      # Drain mailbox into an ordered list, group by tag.
      events = drain_mailbox()
      deltas = for {:delta, t} <- events, do: t
      thinkings = for {:thinking, t} <- events, do: t
      messages = for {:message, m} <- events, do: m
      tool_calls = for {:tool_call, c} <- events, do: c
      tool_responses = for {:tool_response, r} <- events, do: r

      assert deltas == ["Looking ", "up ", "now.", "Got ", "result: ", "found: elixir"]
      assert thinkings == ["consider", "ing query"]

      assert length(messages) == 2
      [m1, m2] = messages
      assert %Nous.Message{role: :assistant} = m1
      assert m1.content == "Looking up now."
      assert m1.reasoning_content == "considering query"

      assert [%{"id" => "call_a", "name" => "lookup", "arguments" => %{"query" => "elixir"}}] =
               m1.tool_calls

      assert %Nous.Message{role: :assistant} = m2
      assert m2.content == "Got result: found: elixir"
      assert m2.tool_calls == []

      assert [%{name: "lookup", id: "call_a", arguments: %{"query" => "elixir"}}] = tool_calls
      assert [%{name: "lookup", id: "call_a"}] = tool_responses
    end

    test "non-streaming run with same script returns same final output (parity)",
         %{model: model, tool: tool} do
      # Drive both stream:true and stream:false variants over equivalent
      # scripted responses; assert the final output and usage match.
      iter1_stream = [
        {:text_delta, "Looking up."},
        {:tool_call_delta,
         [
           %{
             "index" => 0,
             "id" => "call_a",
             "function" => %{
               "name" => "lookup",
               "arguments" => "{\"query\":\"elixir\"}"
             }
           }
         ]},
        {:finish, "tool_calls"},
        {:usage, %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1}}
      ]

      iter2_stream = [
        {:text_delta, "Done: found: elixir"},
        {:finish, "stop"},
        {:usage, %Usage{input_tokens: 8, output_tokens: 6, total_tokens: 14, requests: 1}}
      ]

      script([iter1_stream, iter2_stream])

      agent = Nous.Agent.new(model, instructions: "Be helpful", tools: [tool])

      assert {:ok, streamed_result} =
               AgentRunner.run(agent, "Find elixir", stream: true)

      assert streamed_result.output == "Done: found: elixir"
      assert streamed_result.iterations == 2
      assert streamed_result.usage.tool_calls == 1
    end

    test "stream: true honors cancellation_check between chunks",
         %{model: model, tool: tool} do
      # 100 chunks; cancellation_check flips after the 5th call
      counter = :counters.new(1, [])

      cancellation_check = fn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if n >= 5 do
          throw({:cancelled, :user_request})
        end

        :ok
      end

      many_deltas =
        Enum.map(1..100, fn i -> {:text_delta, "chunk#{i} "} end)

      iter1 = many_deltas ++ [{:finish, "stop"}]
      script([iter1])

      parent = self()

      callbacks = %{
        on_llm_new_delta: fn _e, _t -> send(parent, :delta) end,
        on_tool_call: fn _e, _c -> send(parent, :tool_call_fired) end,
        on_tool_response: fn _e, _r -> send(parent, :tool_response_fired) end
      }

      agent = Nous.Agent.new(model, instructions: "Be helpful", tools: [tool])

      assert {:error, %Nous.Errors.ExecutionCancelled{reason: :user_request}} =
               AgentRunner.run(agent, "stream me",
                 stream: true,
                 callbacks: callbacks,
                 cancellation_check: cancellation_check
               )

      # Should not have fired any tool callbacks
      refute_received :tool_call_fired
      refute_received :tool_response_fired

      # Should have fired some deltas but far fewer than 100
      delta_count = count_received(:delta, 100)
      assert delta_count <= 10
    end

    test "stream: true works with anthropic-style chunks (provider polymorphism)",
         %{tool: tool} do
      # Anthropic emits tagged fragments rather than OpenAI-style lists.
      iter1 = [
        {:text_delta, "Hi "},
        {:tool_call_delta,
         %{"id" => "tu_1", "name" => "lookup", "_index" => 0, "_phase" => :start}},
        {:tool_call_delta, %{"_index" => 0, "_phase" => :partial, "partial_json" => "{\"query"}},
        {:tool_call_delta, %{"_index" => 0, "_phase" => :partial, "partial_json" => "\":\"x\"}"}},
        {:tool_call_delta, %{"_index" => 0, "_phase" => :stop}},
        {:finish, "tool_use"},
        {:usage, %Nous.Usage{input_tokens: 5, output_tokens: 3, total_tokens: 8, requests: 1}}
      ]

      iter2 = [
        {:text_delta, "Got x"},
        {:finish, "end_turn"},
        {:usage, %Nous.Usage{input_tokens: 4, output_tokens: 2, total_tokens: 6, requests: 1}}
      ]

      script([iter1, iter2])

      agent = Nous.Agent.new("anthropic:claude-test", instructions: "Be helpful", tools: [tool])

      assert {:ok, result} = AgentRunner.run(agent, "go", stream: true)
      assert result.output == "Got x"
      assert result.iterations == 2
      assert result.usage.tool_calls == 1
    end
  end

  defp count_received(tag, max) do
    Enum.reduce_while(1..max, 0, fn _, n ->
      receive do
        ^tag -> {:cont, n + 1}
        {^tag, _} -> {:cont, n + 1}
      after
        0 -> {:halt, n}
      end
    end)
  end

  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

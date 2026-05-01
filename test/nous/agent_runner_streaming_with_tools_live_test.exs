defmodule Nous.AgentRunnerStreamingWithToolsLiveTest do
  use ExUnit.Case, async: false

  # Live smoke tests for the `stream: true` path of `Nous.Agent.run/3`.
  # Excluded by default; run with: `mix test --include llm`.
  #
  # Defaults to LM Studio (lmstudio:qwen3-vl-4b-instruct-mlx). Override
  # with TEST_MODEL=... and LMSTUDIO_BASE_URL=... env vars.
  @moduletag :llm

  alias Nous.{Errors, Tool}

  setup do
    case Nous.LLMTestHelper.check_model_available() do
      :ok -> :ok
      {:error, reason} -> {:skip, "Model unavailable: #{reason}"}
    end
  end

  describe "stream: true against a real model" do
    test "basic stream: true (no tools) produces deltas + final output" do
      parent = self()

      callbacks = %{
        on_llm_new_delta: fn _e, t -> send(parent, {:delta, t}) end
      }

      agent =
        Nous.new(Nous.LLMTestHelper.test_model(),
          instructions: "Answer in one short sentence.",
          max_tokens: 60
        )

      assert {:ok, result} =
               Nous.run(agent, "What is 2+2?", stream: true, callbacks: callbacks)

      deltas = drain(:delta)
      assert length(deltas) > 0
      assert result.output != ""
      assert String.contains?(result.output, "4")
      assert result.usage.total_tokens > 0
    end

    test "stream: true with a tool runs the loop end-to-end" do
      parent = self()

      add_tool =
        Tool.from_function(
          fn _ctx, %{"a" => a, "b" => b} -> %{result: a + b} end,
          name: "add",
          description: "Add two integers",
          parameters: %{
            type: "object",
            properties: %{
              a: %{type: "integer", description: "first number"},
              b: %{type: "integer", description: "second number"}
            },
            required: ["a", "b"]
          }
        )

      callbacks = %{
        on_llm_new_delta: fn _e, t -> send(parent, {:delta, t}) end,
        on_tool_call: fn _e, c -> send(parent, {:tool_call, c}) end,
        on_tool_response: fn _e, r -> send(parent, {:tool_response, r}) end
      }

      agent =
        Nous.new(Nous.LLMTestHelper.test_model(),
          instructions: "Use the add tool to compute. Always call the tool, then answer.",
          tools: [add_tool],
          max_tokens: 200
        )

      assert {:ok, result} =
               Nous.run(agent, "What is 17 + 25? Use the add tool.",
                 stream: true,
                 callbacks: callbacks
               )

      tool_calls = drain(:tool_call)
      tool_responses = drain(:tool_response)

      assert length(tool_calls) >= 1
      assert length(tool_responses) >= 1
      assert result.iterations >= 2
      assert result.usage.tool_calls >= 1
      assert String.contains?(result.output, "42")

      [first_call | _] = tool_calls
      assert first_call.name == "add"
      assert is_map(first_call.arguments)
    end

    test "mid-stream cancellation aborts cleanly without partial tool execution" do
      counter = :counters.new(1, [])
      parent = self()

      callbacks = %{
        on_llm_new_delta: fn _e, _t ->
          :counters.add(counter, 1, 1)
          send(parent, :delta)
        end,
        on_tool_call: fn _e, _ -> send(parent, :tool_call_fired) end,
        on_tool_response: fn _e, _ -> send(parent, :tool_response_fired) end
      }

      cancellation_check = fn ->
        if :counters.get(counter, 1) >= 5, do: throw({:cancelled, :live_smoke})
        :ok
      end

      agent =
        Nous.new(Nous.LLMTestHelper.test_model(),
          instructions: "Write a long detailed essay.",
          max_tokens: 500
        )

      assert {:error, %Errors.ExecutionCancelled{reason: :live_smoke}} =
               Nous.run(agent, "Write 200 words about Alan Turing.",
                 stream: true,
                 callbacks: callbacks,
                 cancellation_check: cancellation_check
               )

      refute_received :tool_call_fired
      refute_received :tool_response_fired

      delta_count = drain_count(:delta, 100)
      # We should have stopped well before producing the full essay
      assert delta_count <= 30
    end

    test ":on_llm_new_thinking_delta callback is wired without crashing" do
      parent = self()

      callbacks = %{
        on_llm_new_delta: fn _e, t -> send(parent, {:delta, t}) end,
        on_llm_new_thinking_delta: fn _e, t -> send(parent, {:thinking, t}) end
      }

      agent =
        Nous.new(Nous.LLMTestHelper.test_model(),
          instructions: "Be concise.",
          max_tokens: 30
        )

      # Most non-reasoning models won't emit thinking deltas — we just
      # assert the run completes with the callback wired.
      assert {:ok, result} = Nous.run(agent, "Hi", stream: true, callbacks: callbacks)
      assert result.output != ""
    end
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, payload} -> drain(tag, [payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_count(tag, max) do
    Enum.reduce_while(1..max, 0, fn _, n ->
      receive do
        ^tag -> {:cont, n + 1}
        {^tag, _} -> {:cont, n + 1}
      after
        0 -> {:halt, n}
      end
    end)
  end
end

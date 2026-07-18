defmodule Nous.LMStudioSmokeTest do
  use ExUnit.Case, async: false

  # Live smoke tests against a local LM Studio server, one per extracted
  # AgentRunner submodule path:
  #
  #   * plain run            → RequestDispatch.request_with_fallback + core loop
  #   * sequential tool loop → ToolExecution.run_tool_calls_sequential
  #   * parallel tool calls  → ToolExecution.run_tool_calls_parallel (when the
  #                            model batches calls; sequential otherwise)
  #   * run_stream/3         → Streaming.wrap_stream_with_callbacks/_with_result
  #                            + RequestDispatch.stream_with_fallback
  #
  # Excluded by default; run with:
  #   TEST_MODEL=lmstudio:google/gemma-4-12b-qat mix test --include llm test/nous/lmstudio_smoke_test.exs
  #
  # Assertions are deliberately model-agnostic: thinking models (qwen3.6,
  # gemma-4 with reasoning enabled) spend tokens on reasoning before text, so
  # max_tokens is generous and no test asserts on exact response wording.
  @moduletag :llm
  @moduletag timeout: 180_000

  alias Nous.Tool

  setup do
    case Nous.LLMTestHelper.check_model_available() do
      :ok -> :ok
      {:error, reason} -> {:skip, "Model unavailable: #{reason}"}
    end
  end

  defp model, do: Nous.LLMTestHelper.test_model()

  describe "plain run" do
    test "round-trips a simple prompt through the full runner" do
      agent =
        Nous.new(model(),
          instructions: "Answer in one short sentence.",
          max_tokens: 1024
        )

      assert {:ok, result} = Nous.run(agent, "Say hello.")

      assert is_binary(result.output)
      assert result.output != ""
      assert result.usage.requests >= 1
      assert result.usage.total_tokens > 0
      assert result.iterations >= 1
    end
  end

  describe "tool calling" do
    test "sequential tool loop executes a tool and completes" do
      parent = self()

      lookup_tool =
        Tool.from_function(
          fn _ctx, _args ->
            send(parent, :lookup_ran)
            %{code: "ZX-417"}
          end,
          name: "lookup_code",
          description: "Look up the secret code. Takes no arguments.",
          parameters: %{type: "object", properties: %{}, required: []}
        )

      agent =
        Nous.new(model(),
          instructions:
            "You must call the lookup_code tool to find the secret code, then report it.",
          tools: [lookup_tool],
          max_tokens: 1024
        )

      assert {:ok, result} =
               Nous.run(agent, "What is the secret code? Use the tool.", max_iterations: 5)

      assert_received :lookup_ran
      assert result.usage.tool_calls >= 1
      assert result.iterations >= 2
      assert is_binary(result.output)
      assert result.output != ""
    end

    test "parallel_tool_calls: true executes multiple tools and completes" do
      parent = self()

      make_tool = fn name, value ->
        Tool.from_function(
          fn _ctx, _args ->
            send(parent, {:tool_ran, name})
            %{value: value}
          end,
          name: name,
          description: "Read sensor #{name}. Takes no arguments.",
          parameters: %{type: "object", properties: %{}, required: []}
        )
      end

      agent =
        Nous.new(model(),
          instructions:
            "You must call BOTH the sensor_alpha and sensor_beta tools " <>
              "(in a single response if you can), then report both values.",
          tools: [make_tool.("sensor_alpha", 11), make_tool.("sensor_beta", 22)],
          parallel_tool_calls: true,
          max_tokens: 1024
        )

      assert {:ok, result} =
               Nous.run(agent, "Read both sensors and report the values.", max_iterations: 6)

      assert_received {:tool_ran, "sensor_alpha"}
      assert_received {:tool_ran, "sensor_beta"}
      assert result.usage.tool_calls >= 2
      assert is_binary(result.output)
      assert result.output != ""
    end
  end

  describe "run_stream/3 public API" do
    test "yields delta events and a final {:complete, result}" do
      agent =
        Nous.new(model(),
          instructions: "Answer in one short sentence.",
          max_tokens: 1024
        )

      assert {:ok, stream} = Nous.run_stream(agent, "Say hello.")

      events = Enum.to_list(stream)

      deltas =
        Enum.filter(events, fn
          {:text_delta, _} -> true
          {:thinking_delta, _} -> true
          _ -> false
        end)

      assert deltas != [], "expected at least one text/thinking delta event"

      assert [{:complete, result}] =
               Enum.filter(events, &match?({:complete, _}, &1))

      assert is_binary(result.output)
      assert is_binary(result.finish_reason)
    end
  end
end

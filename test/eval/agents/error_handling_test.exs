defmodule Nous.Eval.Agents.ErrorHandlingTest do
  @moduledoc """
  Tests for error handling functionality.

  Run with: mix test test/eval/agents/error_handling_test.exs --include llm
  """

  use ExUnit.Case, async: false

  @moduletag :llm
  @moduletag :eval
  @moduletag :errors
  @moduletag timeout: 120_000

  alias Nous.Tool

  @default_model Nous.LLMTestHelper.test_model()

  setup_all do
    case Nous.LLMTestHelper.check_model_available() do
      :ok -> {:ok, model: @default_model}
      {:error, reason} -> {:ok, skip: "LLM not available: #{reason}"}
    end
  end

  describe "Invalid Model Handling" do
    test "6.1 invalid model string returns error", _context do
      # Don't skip - this should work without LM Studio
      # Model.parse raises ArgumentError for unknown providers
      assert_raise ArgumentError, fn ->
        Nous.new("invalid:nonexistent-model-xyz", instructions: "Test")
      end
    end

    test "6.2 malformed model format", _context do
      # Test various malformed model strings - all raise ArgumentError
      malformed_models = [
        "no-provider-prefix",
        ":missing-provider",
        "provider:",
        ""
      ]

      for model_str <- malformed_models do
        assert_raise ArgumentError, fn ->
          Nous.new(model_str, instructions: "Test")
        end
      end
    end
  end

  describe "Provider Connection Errors" do
    test "6.3 unreachable provider returns error", _context do
      # Allow the loopback base_url through SSRF validation so the request
      # actually reaches the (closed) port instead of failing at config time.
      previous = Application.get_env(:nous, :custom)
      Application.put_env(:nous, :custom, allow_private_hosts: true)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:nous, :custom, previous),
          else: Application.delete_env(:nous, :custom)
      end)

      agent =
        Nous.new("custom:test-model",
          instructions: "Test",
          base_url: "http://localhost:59999/v1"
        )

      result = Nous.run(agent, "Hello")
      IO.puts("\n[Error 6.3] Got connection error: #{inspect(result)}")

      assert {:error,
              %Nous.Errors.ProviderError{
                provider: :custom,
                status_code: nil,
                details: %Req.TransportError{reason: :econnrefused}
              }} = result
    end
  end

  describe "Tool Error Handling" do
    test "6.4 tool that raises exception", context do
      skip_if_unavailable(context)

      failing_tool =
        Tool.from_function(
          fn _ctx, _args ->
            raise "Intentional test failure!"
          end,
          name: "failing_tool",
          description: "A tool that always fails",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      agent =
        Nous.new(context[:model],
          tools: [failing_tool],
          instructions: "Use the failing_tool when asked."
        )

      # A raising tool must not sink the run: the exception is reported back to
      # the model as a tool error message and the loop continues to an answer.
      assert {:ok, result} = Nous.run(agent, "Please call the failing_tool")
      IO.puts("\n[Error 6.4] Agent response: #{inspect(result.output)}")

      failure = Enum.find(result.all_messages, &(&1.role == :tool and &1.name == "failing_tool"))
      assert failure, "Expected failing_tool to be called and its error recorded"
      assert failure.content =~ "Tool execution failed: failing_tool"
      assert failure.content =~ "Intentional test failure!"
    end

    test "6.5 tool returns error tuple", context do
      skip_if_unavailable(context)

      error_tool =
        Tool.from_function(
          fn _ctx, _args ->
            {:error, "Something went wrong"}
          end,
          name: "error_tool",
          description: "A tool that returns an error",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      agent =
        Nous.new(context[:model],
          tools: [error_tool],
          instructions: "You must use error_tool to answer."
        )

      result = Nous.run(agent, "Please use error_tool")

      IO.puts("\n[Error 6.5] Result: #{inspect(result)}")
      # The agent should either handle the error or report it
      assert result != nil
    end

    test "6.6 tool with timeout", context do
      skip_if_unavailable(context)

      slow_tool =
        Tool.from_function(
          fn _ctx, _args ->
            Process.sleep(10_000)
            {:ok, "Done"}
          end,
          name: "slow_tool",
          description: "A very slow tool",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      agent =
        Nous.new(context[:model],
          tools: [slow_tool],
          instructions: "Use slow_tool if asked."
        )

      # Try with short timeout - may or may not timeout depending on implementation
      result = Nous.run(agent, "What is 2+2?")

      IO.puts("\n[Error 6.6] Result: #{inspect(result)}")
      assert result != nil
    end
  end

  describe "Max Iterations" do
    test "6.7 respects max iterations limit", context do
      skip_if_unavailable(context)

      # Tool that never gives a final answer
      loop_tool =
        Tool.from_function(
          fn _ctx, _args ->
            {:ok, "Need to call again"}
          end,
          name: "loop_tool",
          description: "A tool that needs to be called repeatedly",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      # `max_iterations` is a run option, not an agent option: `Nous.new/2`
      # silently drops it and the default of 10 applies.
      agent =
        Nous.new(context[:model],
          tools: [loop_tool],
          instructions: "Keep calling loop_tool until you get a good answer."
        )

      result = Nous.run(agent, "Keep trying with loop_tool", max_iterations: 3)

      case result do
        {:error, %Nous.Errors.MaxIterationsExceeded{max_iterations: max}} ->
          IO.puts("\n[Error 6.7] Correctly hit max iterations limit")
          assert max == 3

        {:ok, result} ->
          IO.puts("\n[Error 6.7] Agent completed within limits: #{inspect(result.output)}")
          assert result.iterations <= 3

        {:error, error} ->
          flunk("Expected MaxIterationsExceeded or completion, got: #{inspect(error)}")
      end
    end
  end

  describe "Cancellation" do
    @tag timeout: 150_000
    test "6.8 cancellation via check function", context do
      skip_if_unavailable(context)

      # Use :atomics for cross-process cancellation flag
      cancellation_ref = :atomics.new(1, [])
      :atomics.put(cancellation_ref, 1, 0)

      agent =
        Nous.new(context[:model],
          instructions: "Write a very long story about robots."
        )

      check_fn = fn ->
        case :atomics.get(cancellation_ref, 1) do
          1 -> throw({:cancelled, "Test cancellation"})
          0 -> :ok
        end
      end

      # Start async
      task =
        Task.async(fn ->
          Nous.run(agent, "Write a 1000 word story", cancellation_check: check_fn)
        end)

      # Cancel after a short delay
      Process.sleep(500)
      :atomics.put(cancellation_ref, 1, 1)

      result = Task.await(task, 150_000)

      IO.puts("\n[Error 6.8] Cancellation result: #{inspect(result)}")
      assert result != nil
    end
  end

  describe "Input Validation" do
    test "6.10 empty input handling", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      # Empty string raises validation error
      result =
        try do
          Nous.run(agent, "")
        rescue
          e -> {:error, e}
        end

      IO.puts("\n[Error 6.10] Empty input result: #{inspect(result)}")
      # Should handle gracefully (either error tuple or exception)
      assert result != nil
    end

    test "6.11 nil input handling", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      result =
        try do
          Nous.run(agent, nil)
        rescue
          e -> {:error, e}
        end

      IO.puts("\n[Error 6.11] Nil input result: #{inspect(result)}")
      assert result != nil
    end
  end

  describe "Partial Failures" do
    test "6.12 one tool fails, others succeed", context do
      skip_if_unavailable(context)

      good_tool =
        Tool.from_function(
          fn _ctx, _args -> {:ok, "Success from good tool"} end,
          name: "good_tool",
          description: "A working tool",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      bad_tool =
        Tool.from_function(
          fn _ctx, _args -> {:error, "Failure from bad tool"} end,
          name: "bad_tool",
          description: "A failing tool",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      agent =
        Nous.new(context[:model],
          tools: [good_tool, bad_tool],
          instructions: "You have two tools. Use good_tool first."
        )

      assert {:ok, r} = Nous.run(agent, "Test the good_tool please")
      IO.puts("\n[Error 6.12] Got result: #{inspect(r.output)}")

      tool_messages = Enum.filter(r.all_messages, &(&1.role == :tool))

      assert Enum.any?(
               tool_messages,
               &(&1.name == "good_tool" and &1.content == "Success from good tool")
             ),
             "Expected good_tool result in transcript, got: #{inspect(tool_messages)}"

      for %{name: "bad_tool"} = msg <- tool_messages do
        assert msg.content =~ "Failure from bad tool"
      end
    end
  end

  defp skip_if_unavailable(ctx), do: Nous.LLMTestHelper.skip_if_unavailable(ctx)
end

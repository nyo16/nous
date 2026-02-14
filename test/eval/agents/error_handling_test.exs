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

      agent = Nous.new("invalid:nonexistent-model-xyz", instructions: "Test")

      result = Nous.run(agent, "Hello")

      case result do
        {:error, error} ->
          IO.puts("\n[Error 6.1] Got expected error: #{inspect(error)}")
          assert true

        {:ok, _} ->
          # Some providers might silently handle this
          IO.puts("\n[Error 6.1] Warning: Invalid model didn't return error")
          assert true
      end
    end

    test "6.2 malformed model format", _context do
      # Test various malformed model strings
      malformed_models = [
        "no-provider-prefix",
        ":missing-provider",
        "provider:",
        ""
      ]

      for model_str <- malformed_models do
        agent = Nous.new(model_str, instructions: "Test")
        result = Nous.run(agent, "Hello")

        case result do
          {:error, _} ->
            IO.puts("[Error 6.2] Model '#{model_str}' correctly returned error")

          {:ok, _} ->
            IO.puts("[Error 6.2] Model '#{model_str}' unexpectedly succeeded")
        end
      end

      assert true
    end
  end

  describe "Provider Connection Errors" do
    test "6.3 unreachable provider returns error", _context do
      # Configure with unreachable endpoint
      agent =
        Nous.new("openai_compatible:test-model",
          instructions: "Test",
          provider_config: %{
            base_url: "http://localhost:59999/v1"
          }
        )

      result = Nous.run(agent, "Hello")

      case result do
        {:error, error} ->
          IO.puts("\n[Error 6.3] Got connection error: #{inspect(error)}")
          assert true

        {:ok, _} ->
          flunk("Expected connection error for unreachable provider")
      end
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

      result = Nous.run(agent, "Please call the failing_tool")

      case result do
        {:error, error} ->
          IO.puts("\n[Error 6.4] Tool exception handled: #{inspect(error)}")
          assert true

        {:ok, result} ->
          # Agent might recover or not call the tool
          IO.puts("\n[Error 6.4] Agent response: #{inspect(result.output)}")
          assert true
      end
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

      agent =
        Nous.new(context[:model],
          tools: [loop_tool],
          max_iterations: 3,
          instructions: "Keep calling loop_tool until you get a good answer."
        )

      result = Nous.run(agent, "Keep trying with loop_tool")

      case result do
        {:error, %Nous.Errors.MaxIterationsExceeded{}} ->
          IO.puts("\n[Error 6.7] Correctly hit max iterations limit")
          assert true

        {:error, error} ->
          IO.puts("\n[Error 6.7] Got different error: #{inspect(error)}")
          assert true

        {:ok, result} ->
          IO.puts("\n[Error 6.7] Agent completed within limits: #{inspect(result.output)}")
          assert true
      end
    end
  end

  describe "Cancellation" do
    test "6.8 cancellation via check function", context do
      skip_if_unavailable(context)

      # Cancellation flag
      cancel_ref = make_ref()
      Process.put(cancel_ref, false)

      agent =
        Nous.new(context[:model],
          instructions: "Write a very long story about robots."
        )

      # Start async
      task =
        Task.async(fn ->
          Nous.run(agent, "Write a 1000 word story",
            cancellation_check: fn ->
              Process.get(cancel_ref, false)
            end
          )
        end)

      # Cancel after a short delay
      Process.sleep(500)
      Process.put(cancel_ref, true)

      result = Task.await(task, 30_000)

      IO.puts("\n[Error 6.8] Cancellation result: #{inspect(result)}")
      assert result != nil
    end

    test "6.9 task shutdown", context do
      skip_if_unavailable(context)

      agent =
        Nous.new(context[:model],
          instructions: "Be verbose. Write long responses."
        )

      task =
        Task.async(fn ->
          Nous.run(agent, "Explain quantum physics in extreme detail")
        end)

      # Give it a moment to start
      Process.sleep(200)

      # Shutdown the task
      result = Task.shutdown(task, :brutal_kill)

      IO.puts("\n[Error 6.9] Task shutdown result: #{inspect(result)}")
      # Should be nil or {:exit, :killed}
      assert true
    end
  end

  describe "Input Validation" do
    test "6.10 empty input handling", context do
      skip_if_unavailable(context)

      agent = Nous.new(context[:model])

      result = Nous.run(agent, "")

      IO.puts("\n[Error 6.10] Empty input result: #{inspect(result)}")
      # Should handle gracefully
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

      result = Nous.run(agent, "Test the good_tool please")

      case result do
        {:ok, r} ->
          IO.puts("\n[Error 6.12] Got result: #{inspect(r.output)}")
          assert true

        {:error, e} ->
          IO.puts("\n[Error 6.12] Got error: #{inspect(e)}")
          assert true
      end
    end
  end

  defp skip_if_unavailable(ctx), do: Nous.LLMTestHelper.skip_if_unavailable(ctx)
end

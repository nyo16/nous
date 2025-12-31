defmodule Nous.AgentCancellationTest do
  use ExUnit.Case, async: true

  # These tests require a real LLM (LM Studio)
  # Run with: mix test --include llm
  @moduletag :llm

  alias Nous.{Agent, Tool, Errors}

  describe "cancellation via cancellation_check" do
    test "agent stops when cancellation check throws" do
      # Create a simple tool
      tool = Tool.from_function(
        fn _ctx, %{"input" => input} -> "Result: #{input}" end,
        name: "echo",
        description: "Echo input"
      )

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Use the echo tool",
        tools: [tool]
      )

      # Create cancellation flag
      cancellation_ref = :atomics.new(1, [])
      :atomics.put(cancellation_ref, 1, 0)

      # Cancellation check function
      check_fn = fn ->
        case :atomics.get(cancellation_ref, 1) do
          1 -> throw({:cancelled, "Test cancellation"})
          0 -> :ok
        end
      end

      # Run in a task so we can trigger cancellation
      task = Task.async(fn ->
        Agent.run(agent, "Echo hello",
          cancellation_check: check_fn,
          max_iterations: 5
        )
      end)

      # Trigger cancellation after a tiny delay
      Process.sleep(10)
      :atomics.put(cancellation_ref, 1, 1)

      # Wait for result (longer timeout for slower models)
      result = Task.await(task, 30_000)

      # Should get cancellation error
      assert {:error, %Errors.ExecutionCancelled{reason: "Test cancellation"}} = result
    end

    test "agent completes normally without cancellation check" do
      # This test just verifies that without cancellation check, things work normally
      # We can't actually run the model in tests, so we expect a model error
      tool = Tool.from_function(
        fn _ctx, %{"input" => input} -> "Result: #{input}" end,
        name: "echo",
        description: "Echo input"
      )

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Use the echo tool",
        tools: [tool]
      )

      # Run without cancellation check (will fail on model call, but that's expected)
      result = Agent.run(agent, "Echo hello", max_iterations: 1)

      # Should get model error, not cancellation error
      assert {:error, error} = result
      refute match?(%Errors.ExecutionCancelled{}, error)
    end
  end

  describe "AgentServer cancellation" do
    test "tracks current task" do
      {:ok, pid} = Nous.AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:qwen3-vl-4b-thinking-mlx",
          instructions: "Test agent",
          tools: []
        }
      )

      # Initially no task
      state = :sys.get_state(pid)
      assert state.current_task == nil
      assert state.cancelled == false

      # Send message starts a task
      Nous.AgentServer.send_message(pid, "Test")
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.current_task != nil

      # Cancel clears the task
      {:ok, :cancelled} = Nous.AgentServer.cancel_execution(pid)
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.current_task == nil
    end

    test "returns :no_execution when nothing is running" do
      {:ok, pid} = Nous.AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:qwen3-vl-4b-thinking-mlx",
          instructions: "Test agent",
          tools: []
        }
      )

      # No execution running
      {:ok, :no_execution} = Nous.AgentServer.cancel_execution(pid)
    end

    test "cancels existing task when new message arrives" do
      {:ok, pid} = Nous.AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:qwen3-vl-4b-thinking-mlx",
          instructions: "Test agent",
          tools: []
        }
      )

      # Start first execution
      Nous.AgentServer.send_message(pid, "First message")
      Process.sleep(10)

      state = :sys.get_state(pid)
      first_task = state.current_task
      assert first_task != nil

      # Send second message should cancel first
      Nous.AgentServer.send_message(pid, "Second message")
      Process.sleep(10)

      state = :sys.get_state(pid)
      second_task = state.current_task

      # Should have a new task (different reference)
      assert second_task != nil
      assert first_task != second_task
    end
  end
end

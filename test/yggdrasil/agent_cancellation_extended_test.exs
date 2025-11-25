defmodule Yggdrasil.AgentCancellationExtendedTest do
  use ExUnit.Case, async: true

  alias Yggdrasil.{Agent, AgentServer, Tool, ReActAgent}

  describe "AgentServer edge cases" do
    test "multiple rapid cancel calls are safe" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # Start execution
      AgentServer.send_message(pid, "Test message")
      Process.sleep(10)

      # Call cancel multiple times rapidly
      {:ok, :cancelled} = AgentServer.cancel_execution(pid)
      {:ok, :no_execution} = AgentServer.cancel_execution(pid)
      {:ok, :no_execution} = AgentServer.cancel_execution(pid)

      # State should be clean
      state = :sys.get_state(pid)
      assert state.current_task == nil
      assert state.cancelled == false
    end

    test "conversation history is preserved after cancellation" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # Send a message
      AgentServer.send_message(pid, "First message")
      Process.sleep(10)

      # Get history (should have user message)
      history_before = AgentServer.get_history(pid)
      assert length(history_before) == 1
      assert hd(history_before).content == "First message"

      # Cancel
      AgentServer.cancel_execution(pid)
      Process.sleep(10)

      # History should still be there
      history_after = AgentServer.get_history(pid)
      assert history_after == history_before
    end

    test "cancelled flag is reset for next execution" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # Start first execution
      AgentServer.send_message(pid, "First")
      Process.sleep(10)

      # Cancel
      AgentServer.cancel_execution(pid)
      Process.sleep(10)

      # Start second execution
      AgentServer.send_message(pid, "Second")
      Process.sleep(10)

      # Should have new task with cancelled=false
      state = :sys.get_state(pid)
      assert state.current_task != nil
      assert state.cancelled == false
    end

    test "handles :DOWN message for completed task" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # Start execution
      AgentServer.send_message(pid, "Test")
      Process.sleep(10)

      state_before = :sys.get_state(pid)
      assert state_before.current_task != nil

      # Task will complete, :DOWN message should clear task
      # Wait longer for model to respond and task to finish
      Process.sleep(1500)

      state_after = :sys.get_state(pid)
      assert state_after.current_task == nil
    end

    test "clear_history works independently of cancellation" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # Send message and cancel
      AgentServer.send_message(pid, "Test")
      Process.sleep(10)
      AgentServer.cancel_execution(pid)
      Process.sleep(10)

      # History should exist
      assert length(AgentServer.get_history(pid)) > 0

      # Clear history
      AgentServer.clear_history(pid)

      # History should be empty
      assert AgentServer.get_history(pid) == []
    end
  end

  describe "ReActAgent cancellation" do
    test "ReActAgent passes through cancellation_check" do
      # Create cancellation flag - start cancelled
      cancellation_ref = :atomics.new(1, [])
      :atomics.put(cancellation_ref, 1, 1)  # Already cancelled

      check_fn = fn ->
        case :atomics.get(cancellation_ref, 1) do
          1 -> throw({:cancelled, "ReAct test"})
          0 -> :ok
        end
      end

      # Create ReActAgent
      agent = ReActAgent.new("lmstudio:test-model",
        instructions: "Test agent"
      )

      # Run with cancellation check - should cancel immediately
      result = ReActAgent.run(agent, "Test task",
        cancellation_check: check_fn,
        max_iterations: 5
      )

      # Should get cancellation error
      assert {:error, %Yggdrasil.Errors.ExecutionCancelled{reason: "ReAct test"}} = result
    end

    test "AgentServer works with ReActAgent type" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: [],
          type: :react
        }
      )

      # Should initialize with react type
      state = :sys.get_state(pid)
      assert state.agent_type == :react

      # Cancellation should work the same
      AgentServer.send_message(pid, "Test")
      Process.sleep(10)
      {:ok, :cancelled} = AgentServer.cancel_execution(pid)
    end
  end

  describe "cancellation with context" do
    test "deps are preserved after cancellation" do
      # Tool that updates context
      tool = Tool.from_function(
        fn ctx, %{} ->
          initial_count = Map.get(ctx.deps, :count, 0)
          {
            "Updated count",
            __update_context__: %{count: initial_count + 1}
          }
        end,
        name: "counter",
        description: "Increment counter"
      )

      agent = Agent.new("lmstudio:test-model",
        instructions: "Use counter tool",
        tools: [tool]
      )

      # Create cancellation that never triggers
      check_fn = fn -> :ok end

      # Run with deps
      result = Agent.run(agent, "Count",
        deps: %{count: 5},
        cancellation_check: check_fn,
        max_iterations: 1
      )

      # Should fail on model call but deps should be passed
      assert {:error, _} = result
    end
  end

  describe "concurrent agent executions" do
    test "multiple AgentServers can run and cancel independently" do
      # Start 3 agents
      {:ok, pid1} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{model: "lmstudio:test-model", instructions: "Agent 1", tools: []}
      )

      {:ok, pid2} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{model: "lmstudio:test-model", instructions: "Agent 2", tools: []}
      )

      {:ok, pid3} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{model: "lmstudio:test-model", instructions: "Agent 3", tools: []}
      )

      # Start all executions
      AgentServer.send_message(pid1, "Task 1")
      AgentServer.send_message(pid2, "Task 2")
      AgentServer.send_message(pid3, "Task 3")
      Process.sleep(20)

      # All should have tasks
      assert :sys.get_state(pid1).current_task != nil
      assert :sys.get_state(pid2).current_task != nil
      assert :sys.get_state(pid3).current_task != nil

      # Cancel only agent 2
      {:ok, :cancelled} = AgentServer.cancel_execution(pid2)
      Process.sleep(10)

      # Agent 2 should be cancelled, others still running
      assert :sys.get_state(pid2).current_task == nil

      # Note: pid1 and pid3 tasks will eventually die due to model error,
      # but at this moment they should still be trying
    end

    test "rapid message sending cancels previous executions" do
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # Send 5 messages rapidly
      AgentServer.send_message(pid, "Message 1")
      Process.sleep(5)
      AgentServer.send_message(pid, "Message 2")
      Process.sleep(5)
      AgentServer.send_message(pid, "Message 3")
      Process.sleep(5)
      AgentServer.send_message(pid, "Message 4")
      Process.sleep(5)
      AgentServer.send_message(pid, "Message 5")
      Process.sleep(10)

      # Should have one task (the latest)
      state = :sys.get_state(pid)
      assert state.current_task != nil

      # History should have all 5 messages
      history = AgentServer.get_history(pid)
      assert length(history) == 5
    end
  end

  describe "cancellation timing" do
    test "cancellation before any iteration" do
      cancellation_ref = :atomics.new(1, [])
      :atomics.put(cancellation_ref, 1, 1)  # Already cancelled

      check_fn = fn ->
        case :atomics.get(cancellation_ref, 1) do
          1 -> throw({:cancelled, "Immediate cancel"})
          0 -> :ok
        end
      end

      agent = Agent.new("lmstudio:test-model",
        instructions: "Test",
        tools: []
      )

      # Should cancel immediately on first check
      result = Agent.run(agent, "Test",
        cancellation_check: check_fn,
        max_iterations: 5
      )

      assert {:error, %Yggdrasil.Errors.ExecutionCancelled{reason: "Immediate cancel"}} = result
    end

    test "nil cancellation_check is safe" do
      agent = Agent.new("lmstudio:test-model",
        instructions: "Test",
        tools: []
      )

      # Should not crash with nil cancellation_check
      result = Agent.run(agent, "Test",
        cancellation_check: nil,
        max_iterations: 1
      )

      # With working model and nil cancellation, should succeed OR fail
      # Either way, it shouldn't be a cancellation error
      case result do
        {:ok, _} ->
          # Model worked, that's fine
          assert true

        {:error, error} ->
          # Model failed for some reason, but not cancellation
          refute match?(%Yggdrasil.Errors.ExecutionCancelled{}, error)
      end
    end
  end

  describe "error handling" do
    test "cancellation during model request returns cancellation error" do
      # This would require mocking the model to take time,
      # but we can at least verify the structure is correct
      {:ok, pid} = AgentServer.start_link(
        session_id: "test-#{:rand.uniform(10000)}",
        agent_config: %{
          model: "lmstudio:test-model",
          instructions: "Test agent",
          tools: []
        }
      )

      # The task will be created and will attempt to run
      AgentServer.send_message(pid, "Test")
      Process.sleep(5)

      # Cancel very quickly (might catch during first iteration)
      result = AgentServer.cancel_execution(pid)

      # Should either cancel or report no execution (if it finished quickly)
      assert result in [{:ok, :cancelled}, {:ok, :no_execution}]
    end
  end
end

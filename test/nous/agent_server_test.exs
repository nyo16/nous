defmodule Nous.AgentServerTest do
  use ExUnit.Case, async: false

  alias Nous.AgentServer
  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Persistence.ETS, as: PersistenceETS

  @agent_config %{
    model: "openai:gpt-4",
    instructions: "Be helpful",
    tools: [],
    type: :standard
  }

  setup do
    # Ensure persistence ETS table is clean
    if :ets.whereis(:nous_persistence) != :undefined do
      :ets.delete_all_objects(:nous_persistence)
    end

    :ok
  end

  describe "start_link/1 and init" do
    test "starts with required options" do
      {:ok, pid} =
        AgentServer.start_link(
          session_id: "test_init_#{System.unique_integer([:positive])}",
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "initializes context with system prompt and agent_name" do
      session_id = "test_ctx_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      ctx = AgentServer.get_context(pid)
      assert ctx.system_prompt == "Be helpful"
      assert ctx.agent_name == "agent_server_#{session_id}"
      GenServer.stop(pid)
    end

    test "initializes with deps from agent_config" do
      session_id = "test_deps_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: Map.put(@agent_config, :deps, %{user_id: "u123"}),
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      ctx = AgentServer.get_context(pid)
      assert ctx.deps[:user_id] == "u123"
      GenServer.stop(pid)
    end

    test "loads persisted context on init" do
      session_id = "test_persist_load_#{System.unique_integer([:positive])}"

      # Pre-save a context to persistence
      ctx =
        Context.new(system_prompt: "Restored prompt", agent_name: "restored_agent")
        |> Context.add_message(Message.user("Previously saved"))

      data = Context.serialize(ctx)
      PersistenceETS.save(session_id, data)

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      loaded_ctx = AgentServer.get_context(pid)
      assert loaded_ctx.system_prompt == "Restored prompt"
      assert [%{role: :user, content: "Previously saved"}] = loaded_ctx.messages
      GenServer.stop(pid)
    end
  end

  describe "get_context/1 and get_history/1" do
    test "returns initial empty state" do
      session_id = "test_empty_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      ctx = AgentServer.get_context(pid)
      assert ctx.messages == []

      history = AgentServer.get_history(pid)
      assert history == []
      GenServer.stop(pid)
    end
  end

  describe "clear_history/1" do
    test "resets messages while preserving deps and system_prompt" do
      session_id = "test_clear_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: Map.put(@agent_config, :deps, %{user_id: "u456"}),
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      # Manually inject a message into context via internal state
      # We send context via the response_ready message
      ctx = AgentServer.get_context(pid)
      ctx = Context.add_message(ctx, Message.user("Hello"))
      ctx = Context.add_message(ctx, Message.assistant("Hi!"))
      send(pid, {:agent_response_ready, ctx, nil})

      # Give the GenServer time to process
      Process.sleep(50)

      # Verify messages were added
      assert length(AgentServer.get_history(pid)) == 2

      # Clear history
      AgentServer.clear_history(pid)
      Process.sleep(50)

      # Messages should be empty, deps preserved
      ctx = AgentServer.get_context(pid)
      assert ctx.messages == []
      assert ctx.deps[:user_id] == "u456"
      assert ctx.system_prompt == "Be helpful"
      GenServer.stop(pid)
    end

    test "syncs with persistence after clearing" do
      session_id = "test_clear_persist_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      # Inject messages and save
      ctx = AgentServer.get_context(pid)
      ctx = Context.add_message(ctx, Message.user("Pre-clear"))
      send(pid, {:agent_response_ready, ctx, nil})
      Process.sleep(50)

      # Verify it was saved with messages
      {:ok, data} = PersistenceETS.load(session_id)
      assert length(data.messages) == 1

      # Clear
      AgentServer.clear_history(pid)
      Process.sleep(50)

      # Persistence should now have empty messages
      {:ok, data} = PersistenceETS.load(session_id)
      assert data.messages == []
      GenServer.stop(pid)
    end
  end

  describe "cancel_execution/1" do
    test "returns :no_execution when nothing is running" do
      session_id = "test_cancel_idle_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      assert {:ok, :no_execution} = AgentServer.cancel_execution(pid)
      GenServer.stop(pid)
    end
  end

  describe "save_context/1" do
    test "saves to persistence backend" do
      session_id = "test_save_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      assert :ok = AgentServer.save_context(pid)

      {:ok, data} = PersistenceETS.load(session_id)
      assert data.version == 1
      assert data.system_prompt == "Be helpful"
      GenServer.stop(pid)
    end

    test "returns error when no persistence configured" do
      session_id = "test_no_persist_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      assert {:error, :no_persistence} = AgentServer.save_context(pid)
      GenServer.stop(pid)
    end
  end

  describe "load_context/2" do
    test "loads and replaces current context" do
      session_id = "test_load_#{System.unique_integer([:positive])}"

      # Pre-save a context
      ctx =
        Context.new(system_prompt: "Loaded prompt")
        |> Context.add_message(Message.user("Loaded message"))

      PersistenceETS.save(session_id, Context.serialize(ctx))

      {:ok, pid} =
        AgentServer.start_link(
          session_id: "test_load_server_#{System.unique_integer([:positive])}",
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      assert :ok = AgentServer.load_context(pid, session_id)

      loaded = AgentServer.get_context(pid)
      assert loaded.system_prompt == "Loaded prompt"
      assert [%{role: :user, content: "Loaded message"}] = loaded.messages
      GenServer.stop(pid)
    end

    test "returns error for missing session" do
      session_id = "test_load_missing_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      assert {:error, :not_found} = AgentServer.load_context(pid, "nonexistent")
      GenServer.stop(pid)
    end

    test "returns error when no persistence configured" do
      session_id = "test_load_no_persist_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      assert {:error, :no_persistence} = AgentServer.load_context(pid, "any")
      GenServer.stop(pid)
    end
  end

  describe "persistence auto-save on agent response" do
    test "saves context when agent_response_ready is received" do
      session_id = "test_auto_save_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      # Simulate agent response completing
      ctx =
        Context.new(system_prompt: "Be helpful")
        |> Context.add_message(Message.user("Hello"))
        |> Context.add_message(Message.assistant("Hi!"))

      send(pid, {:agent_response_ready, ctx, nil})
      Process.sleep(50)

      # Context should be persisted
      {:ok, data} = PersistenceETS.load(session_id)
      assert length(data.messages) == 2
      GenServer.stop(pid)
    end
  end

  describe "inactivity timeout" do
    test "terminates after timeout" do
      session_id = "test_inactivity_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: 100
        )

      ref = Process.monitor(pid)
      assert Process.alive?(pid)

      # Wait for the timeout
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end

    test "does not terminate when set to infinity" do
      session_id = "test_no_inactivity_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      Process.sleep(200)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "event forwarding" do
    test "handles agent events without crashing" do
      session_id = "test_events_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      # Send various agent events — should not crash
      send(pid, {:agent_delta, "chunk"})
      send(pid, {:tool_call, %{name: "test"}})
      send(pid, {:tool_result, %{result: "ok"}})
      send(pid, {:agent_complete, %{output: "done"}})
      send(pid, {:agent_error, "something went wrong"})
      send(pid, {:agent_start, %{}})
      send(pid, {:agent_message, %{}})
      send(pid, {:agent_task_completed, :error})
      send(pid, {:unknown_event, "ignored"})

      Process.sleep(50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end

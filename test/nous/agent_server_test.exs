# Persistence backend that stalls before delegating to the ETS backend, used to
# prove the agent server doesn't block its mailbox on a slow save.
defmodule Nous.AgentServerTest.SlowPersistence do
  @behaviour Nous.Persistence

  @sleep_ms 300
  @key {__MODULE__, :test_pid}

  # The save runs in a task the GenServer spawns, so `$callers` never reaches
  # the test process and `send(self(), _)` would go nowhere. Registering the
  # owner is the seam agent_cancellation_test.exs already uses for its
  # dispatcher stubs; this file is async: false, so the key cannot collide.
  #
  # With an owner registered the save signals and then parks until released,
  # which takes the wall clock out of the "is the mailbox still responsive
  # mid-save?" assertion entirely. Without one it just sleeps, which is what
  # the fire-and-forget response-ready test wants.
  def register(pid), do: :persistent_term.put(@key, pid)
  def erase, do: :persistent_term.erase(@key)

  @impl true
  def save(session_id, data) do
    case :persistent_term.get(@key, nil) do
      nil -> Process.sleep(@sleep_ms)
      pid -> await_release(pid)
    end

    Nous.Persistence.ETS.save(session_id, data)
  end

  defp await_release(pid) do
    send(pid, {:save_started, self()})

    receive do
      :proceed -> :ok
    after
      # Long enough that a GenServer.call waiting behind this save always times
      # out first, so a regression fails as a blocked caller and not as a hang.
      30_000 -> :ok
    end
  end

  @impl true
  def load(session_id), do: Nous.Persistence.ETS.load(session_id)

  @impl true
  def delete(session_id), do: Nous.Persistence.ETS.delete(session_id)

  @impl true
  def list, do: Nous.Persistence.ETS.list()
end

defmodule Nous.AgentServerTest do
  use ExUnit.Case, async: false

  alias Nous.AgentServer
  alias Nous.Agent.Context
  alias Nous.Message
  alias Nous.Persistence.ETS, as: PersistenceETS
  alias Nous.AgentServerTest.SlowPersistence

  # Poll until `fun` returns truthy (async saves run in a supervised Task now).
  defp eventually(fun, retries \\ 50, delay \\ 20) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(delay)
        eventually(fun, retries - 1, delay)
    end
  end

  @agent_config %{
    model: "openai:gpt-4",
    instructions: "Be helpful",
    tools: [],
    type: :standard
  }

  setup do
    # Ensure persistence ETS table is clean (table is :protected; clear via owner)
    PersistenceETS.clear()
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

  describe "task generation (regression for silent message loss)" do
    test "stale :agent_response_ready (gen 0) is discarded after clear_history" do
      session_id = "test_stale_resp_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          inactivity_timeout: :infinity
        )

      # Simulate: a fresh server (generation 0) where clear_history bumps
      # the generation, then a *stale* :agent_response_ready from a now-
      # cancelled task arrives. Without generation tagging this would
      # clobber the cleared context.
      AgentServer.clear_history(pid)

      stale_ctx =
        Context.new(system_prompt: "Be helpful")
        |> Context.add_message(Message.user("STALE - should be discarded"))

      send(pid, {:agent_response_ready, 0, stale_ctx, nil})

      # No sleeps: clear_history (cast) and the response_ready (info) are sent
      # from this process in order, so FIFO message delivery guarantees the
      # generation is bumped before the stale reply is handled. get_context is a
      # call, so it is processed after both — its return proves they ran.
      ctx = AgentServer.get_context(pid)
      assert ctx.messages == [], "stale response from gen 0 should not have re-populated context"
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
      send(pid, {:agent_response_ready, 0, ctx, nil})

      # get_history is a call, processed after the response_ready info message
      # (FIFO from this process) — no sleep needed.
      assert length(AgentServer.get_history(pid)) == 2

      # Clear history
      AgentServer.clear_history(pid)

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

      # Inject messages via the (now async) response-ready save path.
      ctx = AgentServer.get_context(pid)
      ctx = Context.add_message(ctx, Message.user("Pre-clear"))
      send(pid, {:agent_response_ready, 0, ctx, nil})

      # The save runs in a supervised Task now, so poll until it lands.
      assert eventually(fn ->
               match?({:ok, %{messages: [_]}}, PersistenceETS.load(session_id))
             end)

      assert {:ok, %{messages: [%{content: "Pre-clear"}]}} = PersistenceETS.load(session_id)

      # Clear (also persists asynchronously).
      AgentServer.clear_history(pid)

      # Persistence should converge to empty messages.
      assert eventually(fn -> match?({:ok, %{messages: []}}, PersistenceETS.load(session_id)) end)
      GenServer.stop(pid)
    end

    test "does not block the GenServer while a slow backend persists" do
      session_id = "test_slow_persist_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: SlowPersistence,
          inactivity_timeout: :infinity
        )

      ctx = AgentServer.get_context(pid)
      ctx = Context.add_message(ctx, Message.user("Hello"))

      # Trigger a save via the response-ready path; the backend sleeps 300ms.
      send(pid, {:agent_response_ready, 0, ctx, nil})

      # The GenServer must stay responsive — a get_context call returns well
      # within the backend's sleep, proving the save runs off the mailbox.
      {elapsed_us, _ctx} = :timer.tc(fn -> AgentServer.get_context(pid) end)

      assert elapsed_us < 150_000,
             "get_context blocked for #{div(elapsed_us, 1000)}ms (>150ms) — save is not async"

      # And the save still lands eventually.
      assert eventually(fn ->
               match?({:ok, %{messages: [%{content: "Hello"}]}}, SlowPersistence.load(session_id))
             end)

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

    test "serializes and writes off the GenServer, but stays synchronous (P-2)" do
      session_id = "test_save_offload_#{System.unique_integer([:positive])}"

      SlowPersistence.register(self())
      on_exit(&SlowPersistence.erase/0)

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: SlowPersistence,
          inactivity_timeout: :infinity
        )

      saver = Task.async(fn -> AgentServer.save_context(pid) end)

      # Deterministic hand-off proof. The old Process.sleep(50) was a guess that
      # the handler had already reached its Task; on a loaded runner it had not,
      # and the wall-clock bound below it then failed on correct code.
      assert_receive {:save_started, save_pid}, 2_000
      refute save_pid == pid, "the backend write ran on the server process"

      # The save is parked and cannot finish until we release it, so this is a
      # structural assertion with no timing component: a server that ran the
      # write on its own process could not answer here at all.
      assert %Context{} = AgentServer.get_context(pid)
      refute Task.yield(saver, 0), "save_context replied before the backend write landed"

      # The caller's contract is unchanged: :ok comes back only once the
      # backend write has actually landed.
      send(save_pid, :proceed)
      assert :ok = Task.await(saver, 5_000)
      assert {:ok, %{version: 1}} = SlowPersistence.load(session_id)

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

      send(pid, {:agent_response_ready, 0, ctx, nil})

      # The save now runs in a supervised Task (off the mailbox), so poll until
      # it lands instead of assuming it completed by the next call.
      assert eventually(fn ->
               match?({:ok, %{messages: [_, _]}}, PersistenceETS.load(session_id))
             end)

      assert {:ok, %{messages: [%{content: "Hello"}, %{content: "Hi!"}]}} =
               PersistenceETS.load(session_id)

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

      # The assertion is that the inactivity timer fires at all, not that it
      # fires promptly — so give it real headroom. At 500ms against a 100ms
      # timeout this raced on a loaded runner, with the :DOWN arriving just
      # after the deadline.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
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

      # Assert the server does NOT terminate within the window. refute_receive
      # is deterministic where a bare sleep is not: it fails fast if a :DOWN
      # arrives and otherwise blocks exactly the timeout.
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert Process.alive?(pid)
      Process.demonitor(ref, [:flush])
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

      # A call serializes after all the info messages above; if any had crashed
      # the server, this would exit. Returning a context proves it processed them
      # all and is alive — deterministic, no sleep.
      assert AgentServer.get_context(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # Nous.TaskSupervisor carries a finite :max_children (see Nous.Application),
  # so every spawn this module makes can be REFUSED. All three of them used to
  # assume success: two owe a blocked GenServer.call its reply, and the third is
  # the context checkpoint. `Nous.TaskSupervisorSaturation` is async: false-only,
  # and this module is async: false.
  describe "task supervisor saturation" do
    test "save_context/1 answers the caller instead of leaving it blocked" do
      session_id = "test_sat_save_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      Nous.TaskSupervisorSaturation.saturate!()

      {elapsed_us, result} = :timer.tc(fn -> AgentServer.save_context(pid) end)

      assert result == {:error, :saturated}

      # The answer came from the handler, not from GenServer.call/3 giving up.
      # The refused task was the one that owed `from` a reply, so before the fix
      # this blocked for the full 5_000 ms call timeout and then exited.
      assert elapsed_us < 1_000_000

      # Refused means refused: the error is not covering a partial write.
      assert {:error, :not_found} = PersistenceETS.load(session_id)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "load_context/2 answers the caller instead of leaving it blocked" do
      session_id = "test_sat_load_#{System.unique_integer([:positive])}"

      saved =
        Context.new(system_prompt: "Loaded prompt")
        |> Context.add_message(Message.user("Loaded message"))

      PersistenceETS.save(session_id, Context.serialize(saved))

      {:ok, pid} =
        AgentServer.start_link(
          session_id: "test_sat_load_server_#{System.unique_integer([:positive])}",
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      Nous.TaskSupervisorSaturation.saturate!()

      {elapsed_us, result} = :timer.tc(fn -> AgentServer.load_context(pid, session_id) end)

      assert result == {:error, :saturated}
      assert elapsed_us < 1_000_000

      # Nothing was loaded, so the server's own context is untouched.
      current = AgentServer.get_context(pid)
      assert current.system_prompt == "Be helpful"
      assert current.messages == []

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "the fire-and-forget save logs the dropped checkpoint instead of claiming :ok" do
      session_id = "test_sat_autosave_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        AgentServer.start_link(
          session_id: session_id,
          agent_config: @agent_config,
          pubsub: nil,
          persistence: PersistenceETS,
          inactivity_timeout: :infinity
        )

      ctx =
        Context.new(system_prompt: "Be helpful")
        |> Context.add_message(Message.user("Hello"))
        |> Context.add_message(Message.assistant("Hi!"))

      Nous.TaskSupervisorSaturation.saturate!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, {:agent_response_ready, 0, ctx, nil})
          # A call serializes behind the info message, so the handler (and its
          # warning) have both run by the time this returns.
          assert %Context{} = AgentServer.get_context(pid)
        end)

      # Nobody is waiting on this save, so the loss is only ever visible in the
      # log — which is the whole reason it has to be there.
      assert log =~ "at its :max_children ceiling"
      assert log =~ session_id

      # What the drop costs: this checkpoint never lands. The in-memory context
      # is unaffected and the next successful save supersedes it.
      assert {:error, :not_found} = PersistenceETS.load(session_id)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end

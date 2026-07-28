defmodule Nous.AgentCancellationExtendedTest do
  # async: false — swaps the global :model_dispatcher app env; see
  # agent_cancellation_test.exs. The AgentServer runs in its own GenServer, so
  # the process-scoped dispatcher override cannot reach it.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentServer, Errors, Message, ReActAgent, Usage}

  @moduletag :capture_log

  # See agent_cancellation_test.exs for the rationale: these tests need a model
  # that is slow enough to cancel, not a real one. Every stub signals the test
  # process the instant the model request begins, so `assert_receive` replaces
  # the `Process.sleep(10)` (and one `Process.sleep(130_000)`) this file used to
  # rely on to guess when a run had become cancellable.

  defmodule Stub do
    @moduledoc false

    @key {__MODULE__, :test_pid}

    def register(pid), do: :persistent_term.put(@key, pid)
    def erase, do: :persistent_term.erase(@key)

    def request_started, do: notify({:model_request_started, self()})
    def unexpected_request, do: notify({:unexpected_model_request, self()})

    defp notify(message) do
      case :persistent_term.get(@key, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end

    def text(content, opts \\ []) do
      usage = %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1}
      {:ok, %{Message.assistant(content, opts) | metadata: %{usage: usage}}}
    end
  end

  defmodule BlockingDispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      Stub.request_started()
      Process.sleep(:infinity)
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  defmodule CompletingDispatcher do
    @moduledoc false

    def request(_model, _messages, _settings) do
      Stub.request_started()
      Stub.text("done")
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  defmodule NeverCalledDispatcher do
    @moduledoc false
    # Installed by tests that assert cancellation short-circuits *before* the
    # model is reached. `refute_received {:unexpected_model_request, _}` turns
    # "we think it never dispatched" into an assertion that can actually fail.

    def request(_model, _messages, _settings) do
      Stub.unexpected_request()
      {:error, %Nous.Errors.ModelError{message: "should not have been called", provider: :test}}
    end

    def request_stream(_model, _messages, _settings), do: {:error, "should not be called"}
    def count_tokens(_messages), do: 50
  end

  setup do
    original = Application.get_env(:nous, :model_dispatcher)
    Stub.register(self())
    use_dispatcher(BlockingDispatcher)

    on_exit(fn ->
      Stub.erase()

      if original,
        do: Application.put_env(:nous, :model_dispatcher, original),
        else: Application.delete_env(:nous, :model_dispatcher)
    end)

    :ok
  end

  defp use_dispatcher(module), do: Application.put_env(:nous, :model_dispatcher, module)

  defp start_agent(config_overrides \\ []) do
    session_id = "cancel-ext-#{System.unique_integer([:positive])}"

    config =
      %{model: "openai:test-model", instructions: "Test agent", tools: []}
      |> Map.merge(Map.new(config_overrides))

    start_supervised!(
      Supervisor.child_spec(
        {AgentServer, [session_id: session_id, agent_config: config]},
        id: {AgentServer, session_id}
      )
    )
  end

  # Bounded poll for the two facts the server only reaches via handle_info, which
  # a caller cannot observe synchronously. Unlike a fixed sleep it returns the
  # instant the condition holds and still fails a genuinely broken server at the
  # deadline — it hides no race, it only bounds one.
  defp eventually(fun, retries \\ 200, delay \\ 5) do
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

  describe "AgentServer edge cases" do
    test "repeated cancel_execution calls are idempotent" do
      pid = start_agent()

      AgentServer.send_message(pid, "Test message")
      assert_receive {:model_request_started, _}, 1_000

      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)
      assert {:ok, :no_execution} = AgentServer.cancel_execution(pid)
      assert {:ok, :no_execution} = AgentServer.cancel_execution(pid)

      state = :sys.get_state(pid)
      assert state.current_task == nil
      assert :atomics.get(state.cancelled_ref, 1) == 0
    end

    test "history from a completed run survives a later cancellation" do
      pid = start_agent()

      use_dispatcher(CompletingDispatcher)
      AgentServer.send_message(pid, "First message")
      assert_receive {:model_request_started, _}, 1_000
      assert eventually(fn -> AgentServer.get_history(pid) != [] end)

      history_before = AgentServer.get_history(pid)
      assert Enum.any?(history_before, &(&1.role == :user and &1.content == "First message"))

      use_dispatcher(BlockingDispatcher)
      AgentServer.send_message(pid, "Second message")
      assert_receive {:model_request_started, _}, 1_000
      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)

      # A cancelled run must not clobber the context the completed one saved.
      assert AgentServer.get_history(pid) == history_before
    end

    test "the cancelled flag is reset so the next execution is not born cancelled" do
      pid = start_agent()

      AgentServer.send_message(pid, "First")
      assert_receive {:model_request_started, _}, 1_000
      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)

      AgentServer.send_message(pid, "Second")

      # Reaching the model at all is the assertion: run_agent_and_respond
      # short-circuits before the first iteration while the flag is still set,
      # so a stale flag means this signal never arrives.
      assert_receive {:model_request_started, _}, 1_000

      state = :sys.get_state(pid)
      assert state.current_task != nil
      assert :atomics.get(state.cancelled_ref, 1) == 0
    end

    test "current_task is cleared when the task completes on its own" do
      use_dispatcher(CompletingDispatcher)
      pid = start_agent()

      AgentServer.send_message(pid, "Test")
      assert_receive {:model_request_started, task_pid}, 1_000
      assert :sys.get_state(pid).current_task != nil

      task_ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _}, 2_000

      assert eventually(fn -> :sys.get_state(pid).current_task == nil end)
    end

    test "clear_history empties the context even after a cancellation" do
      pid = start_agent()

      use_dispatcher(CompletingDispatcher)
      AgentServer.send_message(pid, "Test")
      assert_receive {:model_request_started, _}, 1_000
      assert eventually(fn -> AgentServer.get_history(pid) != [] end)

      use_dispatcher(BlockingDispatcher)
      AgentServer.send_message(pid, "Another")
      assert_receive {:model_request_started, _}, 1_000
      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)

      assert AgentServer.get_history(pid) != []

      # clear_history is a cast and get_history is a call on the same mailbox,
      # so the call is already serialised behind it. No sleep required.
      AgentServer.clear_history(pid)
      assert AgentServer.get_history(pid) == []
    end
  end

  describe "ReActAgent cancellation" do
    test "ReActAgent.run stops before the first model call when already cancelled" do
      use_dispatcher(NeverCalledDispatcher)

      cancel_ref = :atomics.new(1, [])
      :atomics.put(cancel_ref, 1, 1)

      check_fn = fn ->
        if :atomics.get(cancel_ref, 1) == 1, do: throw({:cancelled, "ReAct test"})
      end

      agent = ReActAgent.new("openai:test-model", instructions: "Test agent")

      assert {:error, %Errors.ExecutionCancelled{reason: "ReAct test"}} =
               ReActAgent.run(agent, "Test task", cancellation_check: check_fn, max_iterations: 5)

      refute_received {:unexpected_model_request, _}
    end

    test "an AgentServer of type :react cancels like a standard one" do
      pid = start_agent(type: :react)

      assert :sys.get_state(pid).agent_type == :react

      AgentServer.send_message(pid, "Test")
      assert_receive {:model_request_started, task_pid}, 1_000

      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)
      refute Process.alive?(task_pid)
      assert :sys.get_state(pid).current_task == nil
    end
  end

  describe "concurrent agent executions" do
    test "cancelling one AgentServer leaves the others running" do
      pid1 = start_agent()
      pid2 = start_agent()
      pid3 = start_agent()

      AgentServer.send_message(pid1, "Task 1")
      AgentServer.send_message(pid2, "Task 2")
      AgentServer.send_message(pid3, "Task 3")

      for _ <- 1..3, do: assert_receive({:model_request_started, _}, 1_000)

      task1 = :sys.get_state(pid1).current_task
      task2 = :sys.get_state(pid2).current_task
      task3 = :sys.get_state(pid3).current_task

      assert task1 != nil
      assert task2 != nil
      assert task3 != nil

      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid2)

      assert :sys.get_state(pid2).current_task == nil
      refute Process.alive?(task2.pid)

      # Isolation: neither neighbour lost its task to its sibling's cancel.
      assert :sys.get_state(pid1).current_task.pid == task1.pid
      assert :sys.get_state(pid3).current_task.pid == task3.pid
      assert Process.alive?(task1.pid)
      assert Process.alive?(task3.pid)
    end

    test "each new message shuts down the run before it" do
      pid = start_agent()

      task_pids =
        for i <- 1..5 do
          AgentServer.send_message(pid, "Message #{i}")
          assert_receive {:model_request_started, task_pid}, 1_000
          task_pid
        end

      assert Enum.uniq(task_pids) == task_pids

      [current | previous] = Enum.reverse(task_pids)

      # handle_cast calls Task.shutdown on the in-flight task before spawning
      # its successor, and the successor's signal is what we just received —
      # so every earlier task is provably dead by now, no sleep needed.
      assert Enum.all?(previous, &(not Process.alive?(&1)))
      assert Process.alive?(current)
      assert :sys.get_state(pid).current_task.pid == current
    end
  end

  describe "cancellation timing" do
    test "a run cancelled before the first iteration never reaches the model" do
      use_dispatcher(NeverCalledDispatcher)

      cancel_ref = :atomics.new(1, [])
      :atomics.put(cancel_ref, 1, 1)

      check_fn = fn ->
        if :atomics.get(cancel_ref, 1) == 1, do: throw({:cancelled, "Immediate cancel"})
      end

      agent = Agent.new("openai:test-model", instructions: "Test", tools: [])

      assert {:error, %Errors.ExecutionCancelled{reason: "Immediate cancel"}} =
               Agent.run(agent, "Test", cancellation_check: check_fn, max_iterations: 5)

      refute_received {:unexpected_model_request, _}
    end

    test "a nil cancellation_check runs the agent to completion" do
      use_dispatcher(CompletingDispatcher)

      agent = Agent.new("openai:test-model", instructions: "Test", tools: [])

      assert {:ok, result} = Agent.run(agent, "Test", cancellation_check: nil, max_iterations: 1)
      assert result.output == "done"
    end
  end

  describe "error handling" do
    test "the server survives a cancellation and accepts further work" do
      pid = start_agent()

      AgentServer.send_message(pid, "Test")
      assert_receive {:model_request_started, _}, 1_000
      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)

      assert Process.alive?(pid)

      use_dispatcher(CompletingDispatcher)
      AgentServer.send_message(pid, "After cancel")
      assert_receive {:model_request_started, _}, 1_000
      assert eventually(fn -> AgentServer.get_history(pid) != [] end)

      assert Enum.any?(AgentServer.get_history(pid), &(&1.content == "After cancel"))
    end
  end
end

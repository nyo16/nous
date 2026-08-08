defmodule Nous.AgentCancellationTest do
  # async: false — swaps the global :model_dispatcher app env. The runs here go
  # through Nous.AgentServer, which is a GenServer, and `$callers` does not
  # cross GenServer.start_link — so the process-scoped
  # `Nous.ModelDispatcher.put_dispatcher/1` seam cannot reach the server.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentServer, Errors, Message, Tool, Usage}

  @moduletag :capture_log

  # Cancellation does not need a real model — it needs one that is slow enough
  # to cancel. These stubs replace the LM Studio dependency that kept the whole
  # file behind `@moduletag :llm`, i.e. out of CI, leaving `cancel_execution/1`
  # covered only by the trivial `{:ok, :no_execution}` case in agent_server_test.
  #
  # Every stub signals the test process the instant the model request begins.
  # `assert_receive {:model_request_started, task_pid}` is the deterministic
  # replacement for `Process.sleep(10)`: once it lands, the run is provably
  # parked inside the model call, so there is something real to cancel. A
  # cancellation test that races is worse than no cancellation test.

  defmodule Stub do
    @moduledoc false

    @key {__MODULE__, :test_pid}

    def register(pid), do: :persistent_term.put(@key, pid)
    def erase, do: :persistent_term.erase(@key)

    def request_started do
      case :persistent_term.get(@key, nil) do
        nil -> :ok
        pid -> send(pid, {:model_request_started, self()})
      end
    end

    def text(content, opts \\ []) do
      usage = %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, requests: 1}
      {:ok, %{Message.assistant(content, opts) | metadata: %{usage: usage}}}
    end
  end

  defmodule BlockingDispatcher do
    @moduledoc false
    # Parks the run inside the model call forever: the "slow model" the
    # cancellation path needs, with none of the wall-clock nondeterminism.

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

  defmodule ToolLoopDispatcher do
    @moduledoc false
    # Answers every request with the same tool call, so the loop iterates until
    # something stops it. Nothing here is slow — the tool raises the cancellation
    # flag and the loop's next `check_cancellation/1` has to catch it.

    def request(_model, _messages, _settings) do
      Stub.request_started()
      Stub.text("", tool_calls: [%{"id" => "call_1", "name" => "waiter", "arguments" => %{}}])
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 50
  end

  defmodule HangingToolDispatcher do
    @moduledoc false
    # Answers with one tool call whose tool never returns, so the run parks
    # *inside a tool* rather than inside the model call.

    def request(_model, _messages, _settings) do
      Stub.request_started()
      Stub.text("", tool_calls: [%{"id" => "call_1", "name" => "hanger", "arguments" => %{}}])
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
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
    session_id = "cancel-test-#{System.unique_integer([:positive])}"

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

  describe "cancellation via cancellation_check" do
    test "a run is cancelled between iterations once the check throws" do
      use_dispatcher(ToolLoopDispatcher)
      test_pid = self()
      cancel_ref = :atomics.new(1, [])

      tool =
        Tool.from_function(
          fn _ctx, _args ->
            send(test_pid, :tool_ran)
            :atomics.put(cancel_ref, 1, 1)
            "waited"
          end,
          name: "waiter",
          description: "Raises the cancellation flag once the run is underway"
        )

      check_fn = fn ->
        if :atomics.get(cancel_ref, 1) == 1, do: throw({:cancelled, "Test cancellation"})
      end

      agent = Agent.new("openai:test-model", instructions: "Use the waiter tool", tools: [tool])

      assert {:error, %Errors.ExecutionCancelled{reason: "Test cancellation"}} =
               Agent.run(agent, "go", cancellation_check: check_fn, max_iterations: 5)

      # Exactly one iteration ran. The dispatcher never stops asking for the
      # tool, so without a working cancellation check the run would end in
      # MaxIterationsExceeded after five tool executions — which is why the
      # single :tool_ran is the proof that *cancellation* ended the loop.
      assert_received :tool_ran
      refute_received :tool_ran
    end

    test "a run without a cancellation check completes normally" do
      use_dispatcher(CompletingDispatcher)

      agent = Agent.new("openai:test-model", instructions: "Be brief", tools: [])

      assert {:ok, result} = Agent.run(agent, "hello", max_iterations: 1)
      assert result.output == "done"
    end
  end

  describe "AgentServer cancellation" do
    test "cancelling a running execution clears current_task and kills the task" do
      pid = start_agent()

      state = :sys.get_state(pid)
      assert state.current_task == nil
      assert :atomics.get(state.cancelled_ref, 1) == 0

      AgentServer.send_message(pid, "Test")
      assert_receive {:model_request_started, task_pid}, 1_000

      state = :sys.get_state(pid)
      assert state.current_task != nil
      assert state.current_task.pid == task_pid

      task_ref = Process.monitor(task_pid)

      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)

      # The runaway process is actually gone, not merely forgotten by the server.
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _}, 1_000

      state = :sys.get_state(pid)
      assert state.current_task == nil
      # Reset, so the next execution is not born cancelled.
      assert :atomics.get(state.cancelled_ref, 1) == 0
    end

    test "cancelling a run kills the process the tool is executing in" do
      use_dispatcher(HangingToolDispatcher)
      test_pid = self()

      tool =
        Tool.from_function(
          fn _ctx, _args ->
            send(test_pid, {:tool_running, self()})
            Process.sleep(:infinity)
          end,
          name: "hanger",
          description: "Never returns"
        )

      pid = start_agent(tools: [tool])

      AgentServer.send_message(pid, "Test")
      assert_receive {:model_request_started, _}, 1_000
      assert_receive {:tool_running, tool_pid}, 1_000

      tool_ref = Process.monitor(tool_pid)

      assert {:ok, :cancelled} = AgentServer.cancel_execution(pid)

      # Shutting the run task down is not enough. ToolExecutor deliberately
      # runs the tool in a process linked to nothing, so a crashing tool cannot
      # take the run with it — which also meant the tool kept running, holding
      # whatever it held, after the run that asked for it was cancelled.
      assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, :killed}, 2_000
    end

    test "cancel_execution returns :no_execution when nothing is running" do
      pid = start_agent()

      assert {:ok, :no_execution} = AgentServer.cancel_execution(pid)
      assert :sys.get_state(pid).current_task == nil
    end

    test "a new message cancels and replaces the in-flight task" do
      pid = start_agent()

      AgentServer.send_message(pid, "First message")
      assert_receive {:model_request_started, first_task_pid}, 1_000

      first_task = :sys.get_state(pid).current_task
      assert first_task.pid == first_task_pid

      AgentServer.send_message(pid, "Second message")
      assert_receive {:model_request_started, second_task_pid}, 1_000

      second_task = :sys.get_state(pid).current_task
      assert second_task.ref != first_task.ref
      assert second_task.pid == second_task_pid

      # handle_cast shuts the previous task down synchronously before spawning
      # its replacement, so by the time the new run signals, the old one is dead.
      refute Process.alive?(first_task_pid)
    end
  end
end

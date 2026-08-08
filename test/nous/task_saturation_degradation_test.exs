defmodule Nous.TaskSaturationDegradationTest do
  # async: false — Nous.TaskSupervisorSaturation drops the VM-wide
  # Nous.TaskSupervisor ceiling for the duration of each test, so nothing else
  # may be spawning tasks concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Nous.AgentServer
  alias Nous.Eval.{Result, Runner, TestCase}
  alias Nous.Memory.{Entry, Search}
  alias Nous.Research.Coordinator
  alias Nous.TaskSupervisorSaturation
  alias Nous.Tools.FileGrep
  alias Nous.Transcript

  # `:max_children` on Nous.TaskSupervisor made refusal reachable at every
  # callsite, not just the tool fan-out it was written for. Each test here pins
  # ONE callsite's chosen degradation through that module's public API — a
  # degradation nobody can observe from outside is a comment, not a behaviour.
  #
  # Every one of these fails loudly before the fix: the refusal raises out of
  # whatever process called it.

  # Records into the CALLING process's dictionary. On the happy path that is the
  # embed task's dictionary, invisible to the test; run inline it is the test's
  # own — which is precisely the difference being asserted.
  defmodule RecordingProvider do
    @moduledoc false

    def embed(_text, _opts) do
      Process.put(:embedded_in_caller, true)
      {:ok, [1.0, 0.0]}
    end
  end

  # Nous.Memory.Store.ETS does not export search_vector/3, and
  # Search.supports_vector?/1 probes for exactly that — with ETS the embed task
  # is never started at all, so the refusal path would be unreachable.
  defmodule VectorStore do
    @moduledoc false

    def search_text(entries, _query, _opts), do: {:ok, Enum.map(entries, &{&1, 0.5})}
    def search_vector(entries, _embedding, _opts), do: {:ok, Enum.map(entries, &{&1, 0.9})}
  end

  describe "Nous.Transcript.compact_async/2" do
    test "runs the compaction inline and still returns an awaitable Task" do
      messages = for i <- 1..20, do: Nous.Message.user("msg #{i}")

      TaskSupervisorSaturation.saturate!()

      {task, log} = with_log(fn -> Transcript.compact_async(messages, 10) end)

      # No process was spawned (Task.completed/1 carries no pid), yet the public
      # return type is unchanged and the result matches the happy path's 11.
      assert %Task{pid: nil} = task
      assert length(Task.await(task)) == 11
      assert log =~ "task_supervisor_max_children"
    end
  end

  describe "Nous.Memory.Search.search/5" do
    setup do
      entries = [
        Entry.new(%{content: "dark mode", type: :semantic, importance: 0.9, agent_id: "a"})
      ]

      %{entries: entries}
    end

    test "runs the embedding inline and still fuses vector results", %{entries: entries} do
      TaskSupervisorSaturation.saturate!()

      {result, log} =
        with_log(fn ->
          Search.search(VectorStore, entries, "dark mode", RecordingProvider, [])
        end)

      assert {:ok, [{_entry, _score}]} = result

      # The embedding ran in THIS process rather than a task. That is the whole
      # point of the degradation: search/5 keeps returning hybrid results, so its
      # spec needs no error arm, and only latency changes.
      assert Process.get(:embedded_in_caller) == true
      assert log =~ "task_supervisor_max_children"
    end

    test "with room the embedding runs in a task, not inline", %{entries: entries} do
      assert {:ok, [_ | _]} =
               Search.search(VectorStore, entries, "dark mode", RecordingProvider, [])

      # Control for the test above. Without this, that test would pass whether or
      # not the inline degradation exists.
      refute Process.get(:embedded_in_caller)
    end
  end

  describe "Nous.Tools.FileGrep pure-Elixir fallback" do
    setup do
      dir = Path.join(System.tmp_dir!(), "nous_grep_sat_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "haystack.txt"), "a needle in here\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      %{dir: dir, ctx: Nous.RunContext.new(%{workspace_root: dir})}
    end

    test "refuses rather than running an LLM regex with no timeout", %{dir: dir, ctx: ctx} do
      without_ripgrep(fn ->
        TaskSupervisorSaturation.saturate!()

        {result, log} =
          with_log(fn -> FileGrep.execute(ctx, %{"pattern" => "needle", "path" => dir}) end)

        # The task IS the ReDoS bound here, so there is nothing to degrade to:
        # inline would put an unbounded LLM-supplied regex in the caller.
        assert {:error, message} = result
        assert message =~ "at capacity"
        assert message =~ "ripgrep"
        assert log =~ "task_supervisor_max_children"
      end)
    end

    test "with room the fallback still searches", %{dir: dir, ctx: ctx} do
      # Control for the test above, and cover for the await_grep/1 extraction:
      # both tests reach run_elixir_grep/5, only one of them saturated.
      without_ripgrep(fn ->
        assert {:ok, output} = FileGrep.execute(ctx, %{"pattern" => "needle", "path" => dir})
        assert output =~ "haystack.txt"
      end)
    end
  end

  describe "Nous.Research.Coordinator.run/2" do
    test "answers {:error, :saturated} instead of starting an unbounded loop" do
      TaskSupervisorSaturation.saturate!()

      # No network: the refusal lands before research_loop/1 runs, which is why
      # this needs no :search_tool.
      {result, log} = with_log(fn -> Coordinator.run("anything", max_iterations: 1) end)

      # run/2 already advertised {:error, term()}; the task it wanted is what
      # enforces `:timeout`, so running inline was not an option.
      assert result == {:error, :saturated}
      assert log =~ "task_supervisor_max_children"
    end
  end

  describe "Nous.Eval.Runner.run_case/2" do
    test "records the refusal as a test-case error instead of raising" do
      test_case = TestCase.new(id: "sat-1", input: "hi", expected: "hi")

      TaskSupervisorSaturation.saturate!()

      {result, log} = with_log(fn -> Runner.run_case(test_case, model: "openai:test-model") end)

      assert {:ok, %Result{error: :saturated}} = result
      assert log =~ "task_supervisor_max_children"
    end
  end

  describe "Nous.AgentServer user_message cast" do
    test "survives a refused run instead of taking the session's context down" do
      session_id = "sat-#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          Supervisor.child_spec(
            {AgentServer,
             [
               session_id: session_id,
               agent_config: %{model: "openai:test-model", instructions: "hi", tools: []},
               pubsub: nil,
               inactivity_timeout: :infinity
             ]},
            id: {AgentServer, session_id}
          )
        )

      ref = Process.monitor(pid)

      TaskSupervisorSaturation.saturate!()

      {_context, log} =
        with_log(fn ->
          AgentServer.send_message(pid, "hello")
          # get_context/1 is a call, so it cannot be served until the cast above
          # has been handled. That is the synchronisation point — no sleep.
          AgentServer.get_context(pid)
        end)

      # The regression this closes: handle_cast/2 had no refusal branch, so the
      # raise killed the server and the live session's context went with it.
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}
      assert Process.alive?(pid)

      # And the turn was dropped cleanly: nothing was recorded as running.
      assert :sys.get_state(pid).current_task == nil
      assert log =~ "task_supervisor_max_children"
    end
  end

  # FileGrep prefers ripgrep, which needs no task at all; the pure-Elixir
  # fallback is the only path with a supervised task, and it is chosen by
  # System.find_executable/1. Emptying PATH is what makes the fallback reachable
  # on a machine that has rg installed (safe here: async: false, and the
  # fallback shells out to nothing).
  defp without_ripgrep(fun) do
    original = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      fun.()
    after
      System.put_env("PATH", original || "")
    end
  end
end

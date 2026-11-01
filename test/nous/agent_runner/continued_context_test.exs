defmodule Nous.AgentRunner.ContinuedContextTest do
  # R1/R1b: `ctx.iteration` was never reset on a continued context, so
  # `max_iterations` capped the whole conversation (an AgentServer session died
  # after 15 model calls in total) and plugin system-prompt fragments froze at
  # turn 1, because the fragment rebuild is gated on the run's first iteration.
  #
  # async: false — the AgentServer case swaps the global :model_dispatcher app
  # env: runs happen in a task spawned from the server and `$callers` does not
  # cross GenServer.start_link.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, AgentServer, Message, Usage}

  @moduletag :capture_log

  # Answers every request with text and reports the system messages it was
  # sent, so the test can see what the model saw.
  defmodule Recorder do
    @moduledoc false

    @pid_key {__MODULE__, :test_pid}

    def install(pid), do: :persistent_term.put(@pid_key, pid)
    def uninstall, do: :persistent_term.erase(@pid_key)

    def request(_model, messages, _settings) do
      users = Enum.count(messages, &(&1.role == :user))
      system = for %Message{role: :system} = m <- messages, do: Message.extract_text(m)

      case :persistent_term.get(@pid_key, nil) do
        nil -> :ok
        pid -> send(pid, {:model_request, users, system})
      end

      {:ok,
       Message.from_legacy(%{
         parts: [{:text, "reply #{users}"}],
         usage: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
         model_name: "test-model",
         timestamp: DateTime.utc_now()
       })}
    end
  end

  # Its system-prompt fragment names the latest user message: a stale fragment
  # on turn 2 means the fragment was not rebuilt for the new run.
  defmodule LastUserPlugin do
    @moduledoc false
    @behaviour Nous.Plugin

    @impl true
    def system_prompt(_agent, ctx) do
      last = ctx.messages |> Enum.filter(&(&1.role == :user)) |> List.last()
      "FRAGMENT for: #{Message.extract_text(last)}"
    end
  end

  # Contributes a fragment only while the latest user message asks for it,
  # like a skill that matched on turn 1 and is inactive on turn 2.
  defmodule SometimesPlugin do
    @moduledoc false
    @behaviour Nous.Plugin

    @impl true
    def system_prompt(_agent, ctx) do
      last = ctx.messages |> Enum.filter(&(&1.role == :user)) |> List.last()
      if Message.extract_text(last) =~ "skill", do: "SKILL INSTRUCTIONS", else: nil
    end
  end

  setup do
    Recorder.install(self())
    Nous.ModelDispatcher.put_dispatcher(Recorder)

    on_exit(fn ->
      Recorder.uninstall()
      Application.delete_env(:nous, :model_dispatcher)
    end)

    :ok
  end

  test "a fragment that stops contributing is not sent on the next run" do
    agent = Agent.new("openai:test-model", instructions: "BASE", plugins: [SometimesPlugin])

    {:ok, first} = AgentRunner.run(agent, "use the skill")
    assert_receive {:model_request, 1, ["BASE\n\nSKILL INSTRUCTIONS"]}

    {:ok, _} = AgentRunner.run(agent, "plain question", context: first.context)
    assert_receive {:model_request, 2, ["BASE"]}
  end

  test "max_iterations caps each continued run, not the conversation" do
    agent = Agent.new("openai:test-model", max_iterations: 3)

    {:ok, first} = AgentRunner.run(agent, "turn 1")
    assert first.iterations == 1

    final =
      Enum.reduce(2..5, first, fn turn, prev ->
        assert {:ok, result} = AgentRunner.run(agent, "turn #{turn}", context: prev.context)
        assert result.output == "reply #{turn}"
        assert result.iterations == 1
        result
      end)

    assert final.context.iteration == 1
  end

  test "run_with_context counts its own iterations" do
    agent = Agent.new("openai:test-model", max_iterations: 1)
    {:ok, first} = AgentRunner.run(agent, "turn 1")

    ctx = Nous.Agent.Context.add_message(first.context, Message.user("turn 2"))
    assert {:ok, second} = AgentRunner.run_with_context(agent, ctx)
    assert second.output == "reply 2"
    assert second.iterations == 1
  end

  test "plugin system-prompt fragments are rebuilt for every run" do
    agent = Agent.new("openai:test-model", instructions: "BASE", plugins: [LastUserPlugin])

    {:ok, first} = AgentRunner.run(agent, "first question")
    assert_receive {:model_request, 1, ["BASE\n\nFRAGMENT for: first question"]}

    {:ok, _} = AgentRunner.run(agent, "second question", context: first.context)
    assert_receive {:model_request, 2, ["BASE\n\nFRAGMENT for: second question"]}
  end

  test "an AgentServer session keeps answering past max_iterations total requests" do
    Application.put_env(:nous, :model_dispatcher, Recorder)

    pid =
      start_supervised!(
        {AgentServer,
         [
           session_id: "continued-#{System.unique_integer([:positive])}",
           agent_config: %{model: "openai:test-model", instructions: "T", max_iterations: 2},
           inactivity_timeout: :infinity
         ]}
      )

    for turn <- 1..4 do
      AgentServer.send_message(pid, "turn #{turn}")
      assert_receive {:model_request, ^turn, _system}, 2_000
      await_assistant_count(pid, turn)
    end

    users =
      for %Message{role: :user} = m <- AgentServer.get_context(pid).messages,
          do: Message.extract_text(m)

    assert users == ["turn 1", "turn 2", "turn 3", "turn 4"]
  end

  defp await_assistant_count(pid, n, attempts \\ 100) do
    count = Enum.count(AgentServer.get_context(pid).messages, &(&1.role == :assistant))

    cond do
      count >= n ->
        :ok

      attempts == 0 ->
        flunk("expected #{n} assistant messages, got #{count}")

      true ->
        Process.sleep(20)
        await_assistant_count(pid, n, attempts - 1)
    end
  end
end

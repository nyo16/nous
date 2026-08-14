defmodule Nous.AgentServerSteeringTest do
  # async: false — swaps the global :model_dispatcher app env. Runs started by
  # Nous.AgentServer happen in a task spawned from the server process, and
  # `$callers` does not cross GenServer.start_link, so the process-scoped
  # Nous.ModelDispatcher.put_dispatcher/1 seam cannot reach them.
  use ExUnit.Case, async: false

  alias Nous.{Agent, AgentRunner, AgentServer, Hook, Message, Tool, Usage}
  alias Nous.Agent.{Behaviour, Context}
  alias Nous.AgentRunner.IterationLoop
  alias Nous.Session.Log

  @moduletag :capture_log

  # A dispatcher that reports every model request to the test process and answers
  # from a script. Two things it buys over sleeping: the request number is
  # explicit, so "which step claimed my message" is an assertion rather than an
  # inference, and a `refute_receive` can prove that NO request happened — which
  # is the whole verification for `inject/2`.
  defmodule Recorder do
    @moduledoc false

    @pid_key {__MODULE__, :test_pid}
    @script_key {__MODULE__, :script}
    @count_key {__MODULE__, :count}

    def install(pid, script) do
      :persistent_term.put(@pid_key, pid)
      :persistent_term.put(@script_key, script)
      :persistent_term.put(@count_key, :atomics.new(1, signed: false))
      Application.put_env(:nous, :model_dispatcher, __MODULE__)
    end

    def uninstall do
      Enum.each([@pid_key, @script_key, @count_key], &:persistent_term.erase/1)
    end

    def requests, do: :atomics.get(:persistent_term.get(@count_key), 1)

    def request(_model, messages, _settings) do
      n = :atomics.add_get(:persistent_term.get(@count_key), 1, 1)
      Kernel.send(:persistent_term.get(@pid_key), {:model_request, n, messages})
      answer(Enum.at(:persistent_term.get(@script_key), n - 1, "unscripted"))
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 10

    defp answer({:tool_call, name}) do
      reply("", tool_calls: [%{"id" => "call_#{name}", "name" => name, "arguments" => %{}}])
    end

    defp answer(text) when is_binary(text), do: reply(text)

    defp reply(content, opts \\ []) do
      usage = %Usage{input_tokens: 5, output_tokens: 5, total_tokens: 10, requests: 1}
      {:ok, %{Message.assistant(content, opts) | metadata: %{usage: usage}}}
    end
  end

  setup do
    original = Application.get_env(:nous, :model_dispatcher)

    on_exit(fn ->
      Recorder.uninstall()

      if original,
        do: Application.put_env(:nous, :model_dispatcher, original),
        else: Application.delete_env(:nous, :model_dispatcher)
    end)

    :ok
  end

  # ── inject vs steer, the named plan verification ────────────────────────────

  describe "inject/2 and steer/2 on an idle agent" do
    test "inject does not wake the agent, steer does, and the injection rides along" do
      Recorder.install(self(), ["acknowledged"])
      pid = start_agent()

      AgentServer.inject(pid, "FYI: the staging deploy is frozen")

      # Flush the cast through the server's mailbox, then prove nothing started.
      # If inject woke the agent there would be a request in flight by now.
      _ = AgentServer.get_context(pid)
      refute_receive {:model_request, _n, _messages}, 200
      assert Recorder.requests() == 0

      AgentServer.steer(pid, "Which services are pending?")

      assert_receive {:model_request, 1, messages}, 2_000

      # One request, carrying both messages in send order: the injection waited
      # for the next admitted request instead of being dropped or starting one.
      assert user_contents(messages) == [
               "FYI: the staging deploy is frozen",
               "Which services are pending?"
             ]

      refute_receive {:model_request, 2, _messages}, 200
    end

    test "followup/2 wakes an idle agent and its message reaches the first request" do
      Recorder.install(self(), ["answered"])
      pid = start_agent()

      AgentServer.followup(pid, "handle this next")

      assert_receive {:model_request, 1, messages}, 2_000
      assert user_contents(messages) == ["handle this next"]

      # The turn opened before its first input was claimed.
      assert eventually(fn ->
               pid |> AgentServer.get_context() |> event_types() |> Enum.take(2) ==
                 [:turn_start, :user_message]
             end)
    end
  end

  # ── turn and step events ────────────────────────────────────────────────────

  describe "turn and step events" do
    test "a two-step run emits a turn, one step pair per request, and a turn_end" do
      Recorder.install(self(), [{:tool_call, "ping"}, "all done"])
      agent = Agent.new("openai:test-model", instructions: "Test", tools: [ping_tool()])

      assert {:ok, result} = AgentRunner.run(agent, "go")
      assert result.output == "all done"

      assert bookkeeping(result.context) == [
               {:turn_start, %{turn: 1}},
               {:step_start, %{turn: 1, step: 1}},
               {:step_end, %{turn: 1, step: 1, outcome: :ok}},
               {:step_start, %{turn: 1, step: 2}},
               {:step_end, %{turn: 1, step: 2, outcome: :ok}},
               {:turn_end, %{turn: 1, steps: 2, reason: :complete}}
             ]

      # `:interrupted` belongs to crash recovery and to nothing else. If a live
      # loop can emit it, recovery can no longer tell a crash from a clean exit.
      refute Enum.any?(Log.events(result.context.log), &(&1.data[:reason] == :interrupted))

      # And none of it is visible to the model or to result.messages (D2).
      assert Enum.map(result.all_messages, & &1.role) ==
               [:system, :user, :assistant, :tool, :assistant]
    end

    test "a rejected first claim closes a durable turn that spent no step" do
      # Asserted against IterationLoop rather than AgentRunner.run/3 on purpose.
      # A rejected first claim leaves a trailing user message, and
      # BasicAgent.extract_output/2 answers `{:error, :no_output}` to a
      # transcript that does not end in an assistant or tool message — which is
      # how a denied `:pre_request` has always ended, and which throws the
      # context away. The durable turn is a property of the loop, so that is
      # where it is pinned; the end-to-end consequence is the test below.
      Recorder.install(self(), ["never reached"])

      # `{:deny, reason}` rather than the bare `:deny`: a hook that explains
      # itself must block just as hard as one that does not.
      gate =
        Hook.new(:pre_request,
          name: "gate",
          handler: fn :pre_request, _payload -> {:deny, "not now"} end
        )

      agent = Agent.new("openai:test-model", instructions: "Test", hooks: [gate])

      ctx = %{
        Context.new(messages: [Message.user("earlier"), Message.assistant("answered")])
        | hook_registry: Hook.Registry.from_hooks([gate]),
          deps: %{claim_inbox: one_shot_claim("and again")}
      }

      assert {:ok, ctx} = IterationLoop.execute_loop(agent, Behaviour.get_module(agent), ctx)

      assert bookkeeping(ctx) == [
               {:turn_start, %{turn: 1}},
               {:turn_end, %{turn: 1, steps: 0, reason: :rejected}}
             ]

      # No request was made, and the rejected input is still in the transcript:
      # the rejection refused the request, not the fact that the user said
      # something.
      assert Recorder.requests() == 0
      assert "and again" in user_contents(ctx.messages)
    end

    test "a pre_step rejection blocks the model request end to end" do
      Recorder.install(self(), ["never reached"])

      gate =
        Hook.new(:pre_request,
          name: "gate",
          handler: fn :pre_request, _payload -> {:deny, "not now"} end
        )

      agent = Agent.new("openai:test-model", instructions: "Test", hooks: [gate])

      assert {:error, :no_output} = AgentRunner.run(agent, "go")
      assert Recorder.requests() == 0
    end

    test "the pre_step hook sees the batch the step boundary claimed" do
      Recorder.install(self(), ["answered"])
      test_pid = self()

      spy =
        Hook.new(:pre_request,
          name: "spy",
          handler: fn :pre_request, payload ->
            Kernel.send(test_pid, {:pre_step, payload.claimed, payload.claimed_content})
            :allow
          end
        )

      agent = Agent.new("openai:test-model", instructions: "Test", hooks: [spy])

      # Drive the claim seam by hand rather than through a server: the payload is
      # what is under test, and `deps[:claim_inbox]` is the whole contract
      # between the loop and whoever owns an inbox.
      claim = one_shot_claim("look at this")

      assert {:ok, _result} = AgentRunner.run(agent, "go", deps: %{claim_inbox: claim})

      assert_receive {:pre_step, 1, ["look at this"]}, 2_000
      assert Recorder.requests() == 1
    end
  end

  # ── steering a run that is already in flight ────────────────────────────────

  describe "steering mid-run" do
    test "a steer sent mid-run is claimed by the NEXT step, not the current one" do
      Recorder.install(self(), [{:tool_call, "hold"}, "acknowledged"])
      pid = start_agent(tools: [holding_tool(self())])

      AgentServer.send_message(pid, "start working")

      # Request 1 is on the wire and its tool is parked, so the run is provably
      # inside a step and cannot claim anything until we release it.
      assert_receive {:model_request, 1, first_messages}, 2_000
      assert_receive {:tool_running, tool_pid}, 2_000

      AgentServer.steer(pid, "also skip /legacy")
      # A cast is not ordered against the run task's claim call, so flush the
      # server's mailbox before releasing the tool. Without this the test races
      # the very boundary it exists to observe.
      _ = AgentServer.get_context(pid)

      Kernel.send(tool_pid, :release)

      assert_receive {:model_request, 2, second_messages}, 2_000

      refute "also skip /legacy" in user_contents(first_messages)
      assert "also skip /legacy" in user_contents(second_messages)

      # Claimed after the tool result, so the assistant/tool pairing every
      # provider validates is never split by a mid-run message.
      assert Enum.map(second_messages, & &1.role) == [:system, :user, :assistant, :tool, :user]

      assert eventually(fn ->
               "also skip /legacy" in user_contents(AgentServer.get_context(pid).messages)
             end)
    end

    test "a followup sent mid-run waits for a new turn, and the run's end starts it" do
      # The case a `wakeRequested` latch exists to paper over upstream: a waking
      # message that no boundary of the current run will ever claim. Here the
      # `:running -> :idle` transition asks the inbox instead.
      Recorder.install(self(), [{:tool_call, "hold"}, "first answer", "second answer"])
      pid = start_agent(tools: [holding_tool(self())])

      AgentServer.send_message(pid, "start working")

      assert_receive {:model_request, 1, _messages}, 2_000
      assert_receive {:tool_running, tool_pid}, 2_000

      AgentServer.followup(pid, "then do the other thing")
      _ = AgentServer.get_context(pid)

      Kernel.send(tool_pid, :release)

      # The current run finishes without ever seeing it: next_turn is claimed at
      # a turn boundary, and this run's turn opened before the message existed.
      assert_receive {:model_request, 2, second_messages}, 2_000
      refute "then do the other thing" in user_contents(second_messages)

      # A new run starts on its own and claims it at the new turn's boundary.
      assert_receive {:model_request, 3, third_messages}, 2_000
      assert "then do the other thing" in user_contents(third_messages)

      refute_receive {:model_request, 4, _messages}, 200
    end

    test "an injection queued mid-run is claimed by the next step without extending the run" do
      Recorder.install(self(), [{:tool_call, "hold"}, "acknowledged"])
      pid = start_agent(tools: [holding_tool(self())])

      AgentServer.send_message(pid, "start working")

      assert_receive {:model_request, 1, _messages}, 2_000
      assert_receive {:tool_running, tool_pid}, 2_000

      AgentServer.inject(pid, "note: rate limits are tight today")
      _ = AgentServer.get_context(pid)

      Kernel.send(tool_pid, :release)

      assert_receive {:model_request, 2, second_messages}, 2_000
      assert "note: rate limits are tight today" in user_contents(second_messages)

      # It rode along with a request that was going to happen anyway, and did
      # not cause one of its own once the run finished.
      refute_receive {:model_request, 3, _messages}, 300
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp start_agent(overrides \\ []) do
    session_id = "steer-#{System.unique_integer([:positive])}"

    config =
      %{model: "openai:test-model", instructions: "Test agent", tools: []}
      |> Map.merge(Map.new(overrides))

    start_supervised!(
      Supervisor.child_spec(
        {AgentServer,
         [session_id: session_id, agent_config: config, inactivity_timeout: :infinity]},
        id: {AgentServer, session_id}
      )
    )
  end

  defp ping_tool do
    Tool.from_function(fn _ctx, _args -> "pong" end,
      name: "ping",
      description: "Answers pong"
    )
  end

  # The claim seam an inbox owner installs, driven by hand: hands `text` to the
  # first `:next_step` claim and nothing to any claim after it.
  defp one_shot_claim(text) do
    spent = :atomics.new(1, signed: false)

    fn
      :next_step ->
        if :atomics.add_get(spent, 1, 1) == 1, do: [Message.user(text)], else: []

      :next_turn ->
        []
    end
  end

  # A tool that parks until the test releases it, which is how "the run is
  # provably mid-step" becomes an assertion instead of a sleep.
  defp holding_tool(test_pid) do
    Tool.from_function(
      fn _ctx, _args ->
        Kernel.send(test_pid, {:tool_running, self()})

        receive do
          :release -> "held"
        after
          5_000 -> "the test never released this tool"
        end
      end,
      name: "hold",
      description: "Blocks until released"
    )
  end

  @turn_step_types [:turn_start, :turn_end, :step_start, :step_end]

  defp bookkeeping(ctx) do
    ctx.log
    |> Log.events()
    |> Enum.filter(&(&1.type in @turn_step_types))
    |> Enum.map(&{&1.type, &1.data})
  end

  defp event_types(ctx), do: ctx.log |> Log.events() |> Enum.map(& &1.type)

  defp user_contents(messages) do
    messages |> Enum.filter(&(&1.role == :user)) |> Enum.map(& &1.content)
  end

  defp eventually(fun, retries \\ 100, delay \\ 20) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(delay) && eventually(fun, retries - 1, delay)
    end
  end
end

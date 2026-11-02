defmodule Nous.Eval.Trace.CollectorTest do
  # async: false - the collector's handler and tables are global, and one test
  # detaches the handler.
  use ExUnit.Case, async: false

  alias Nous.{Agent, Message, Tool, Usage}
  alias Nous.Eval.Trace
  alias Nous.Eval.Trace.Collector
  alias Nous.Eval.Trace.Collector.TableOwner
  alias Nous.Eval.Trace.Event
  alias Nous.Telemetry.RunScope

  @moduletag :capture_log

  @script_key :"$nous_collector_test_script"

  @run_start [:nous, :agent, :run, :start]
  @run_stop [:nous, :agent, :run, :stop]
  @run_exception [:nous, :agent, :run, :exception]
  @model_start [:nous, :agent, :model, :start]
  @tool_start [:nous, :agent, :tool_call, :start]
  @tool_stop [:nous, :agent, :tool_call, :stop]

  # Answers from a script function the test installs in its own process
  # dictionary, found through `$callers` from sample, tool and sub-agent
  # processes.
  defmodule ScriptDispatcher do
    @moduledoc false

    def request(_model, messages, _settings) do
      script = Nous.CallerLookup.lookup(:"$nous_collector_test_script")
      script.(messages)
    end

    def request_stream(_model, _messages, _settings), do: {:ok, []}
    def count_tokens(_messages), do: 10
  end

  setup do
    Nous.ModelDispatcher.put_dispatcher(ScriptDispatcher)
    :ok = Collector.attach()
    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp script(fun), do: Process.put(@script_key, fun)

  defp usage, do: %Usage{input_tokens: 10, output_tokens: 4, total_tokens: 14, requests: 1}

  defp text(content),
    do: {:ok, Message.assistant(content, metadata: %{usage: usage(), finish_reason: "stop"})}

  defp calls(calls) do
    {:ok,
     Message.assistant("",
       tool_calls: calls,
       metadata: %{usage: usage(), finish_reason: "tool_calls"}
     )}
  end

  defp call(id, name, args \\ %{}), do: %{"id" => id, "name" => name, "arguments" => args}

  defp tool(name, fun, opts \\ []),
    do: Tool.from_function(fun, Keyword.merge([name: name, description: name], opts))

  defp agent(opts \\ []), do: Agent.new("openai:test-model", opts)

  defp user_prompt(messages), do: Enum.find_value(messages, &(&1.role == :user and &1.content))

  defp tool_messages(messages), do: Enum.count(messages, &(&1.role == :tool))

  defp named(%Trace{events: events}, name), do: Enum.filter(events, &(&1.name == name))

  defp sink_rows(trace_id),
    do: :ets.select(TableOwner.sink(), [{{{trace_id, :_, :_}, :_, :_, :_, :_}, [], [:"$_"]}])

  # Forwards every model.start's request messages, as emitted, to the test.
  def forward_request(_event, _m, %{trace_id: trace_id, messages: messages}, pid),
    do: send(pid, {:emitted_request, trace_id, messages})

  def forward_request(_event, _m, _meta, _pid), do: :ok

  defp capture_requests do
    id = "collector-test-requests-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, @model_start, &__MODULE__.forward_request/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp emitted_requests(trace_id, acc \\ []) do
    receive do
      {:emitted_request, ^trace_id, messages} -> emitted_requests(trace_id, [messages | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── isolation ──────────────────────────────────────────────────────────────

  test "concurrent samples of one agent never share events" do
    echo = tool("echo", fn _ctx, %{"n" => n} -> "echo-#{n}" end)

    script(fn messages ->
      "sample-" <> n = user_prompt(messages)

      if tool_messages(messages) == 0,
        do: calls([call("c1", "echo", %{"n" => n})]),
        else: text("done-#{n}")
    end)

    agent = agent(name: "iso", tools: [echo])

    samples =
      0..19
      |> Enum.map(fn n ->
        Task.async(fn ->
          {:ok, sample} = Collector.run_sample(fn -> Nous.run(agent, "sample-#{n}") end)
          {n, sample}
        end)
      end)
      |> Task.await_many(30_000)

    trace_ids = for {_n, %{trace: trace}} <- samples, do: trace.trace_id
    assert length(Enum.uniq(trace_ids)) == 20

    shapes =
      for {n, %{outcome: outcome, trace: trace}} <- samples do
        assert {:ok, %{output: output}} = outcome
        assert output == "done-#{n}"
        refute trace.truncated?
        assert trace.dropped == 0

        [%Event{metadata: start}] = named(trace, @run_start)
        assert Enum.map(trace.events, & &1.seq) == Enum.to_list(0..(length(trace.events) - 1))

        for event <- trace.events do
          assert event.metadata.trace_id == trace.trace_id
          assert event.metadata.agent_run_id == start.agent_run_id
        end

        for %Event{metadata: meta} <- named(trace, @model_start) do
          assert user_prompt(meta.messages) == "sample-#{n}"
        end

        assert [%{arguments: %{"n" => n_arg}, result: result}] = Trace.tool_calls(trace)
        assert n_arg == "#{n}"
        assert result == "echo-#{n}"

        Enum.map(trace.events, & &1.name)
      end

    # Same agent, same script: every trace holds exactly one run's events.
    assert shapes |> Enum.uniq() |> length() == 1
    assert [@run_start | _] = hd(shapes)
    assert @run_stop in hd(shapes)
  end

  test "events outside a registered trace insert nothing" do
    script(fn _ -> text("ok") end)
    size = :ets.info(TableOwner.sink(), :size)

    assert {:ok, _} = Nous.run(agent(), "no scope")

    unregistered = RunScope.new_trace_id()

    assert {:ok, _} =
             RunScope.with_scope(%{trace_id: unregistered, role: :agent}, fn ->
               Nous.run(agent(), "unregistered scope")
             end)

    assert :ets.info(TableOwner.sink(), :size) == size
    assert sink_rows(unregistered) == []
  end

  # ── tool calls ─────────────────────────────────────────────────────────────

  test "parallel and timed tool calls appear with matching tool_call_id" do
    fast = tool("fast", fn _ctx, %{"x" => x} -> "fast-#{x}" end)
    slow = tool("slow", fn _ctx, _ -> Process.sleep(1_000) end, timeout: 20, retries: 0)

    script(fn messages ->
      if tool_messages(messages) == 0 do
        calls([
          call("c_a", "fast", %{"x" => "a"}),
          call("c_b", "fast", %{"x" => "b"}),
          call("c_slow", "slow")
        ])
      else
        text("done")
      end
    end)

    agent = agent(tools: [fast, slow], parallel_tool_calls: true)

    assert {:ok, %{outcome: {:ok, _}, trace: trace}} =
             Collector.run_sample(fn -> Nous.run(agent, "go") end)

    calls = Trace.tool_calls(trace, include: :all) |> Map.new(&{&1.id, &1})
    assert %{outcome: :executed, result: "fast-a", name: "fast"} = calls["c_a"]
    assert %{outcome: :executed, result: "fast-b"} = calls["c_b"]
    assert %{outcome: :timeout, error: %Nous.Errors.ToolTimeout{}} = calls["c_slow"]

    starts = for e <- named(trace, @tool_start), do: e.metadata.tool_call_id
    stops = for e <- named(trace, @tool_stop), do: e.metadata.tool_call_id
    assert Enum.sort(starts) == ["c_a", "c_b", "c_slow"]
    assert Enum.sort(stops) == ["c_a", "c_b", "c_slow"]

    executed =
      for %Event{name: [:nous, :tool, :execute, :start], metadata: meta} <- trace.events,
          do: {meta.tool_name, meta.tool_call_id}

    assert Enum.sort(executed) == [{"fast", "c_a"}, {"fast", "c_b"}, {"slow", "c_slow"}]
  end

  test "sub-agent events land in the parent's trace with parent ids" do
    worker = agent(name: "worker")

    script(fn messages ->
      cond do
        user_prompt(messages) == "child-task" ->
          text("child ok")

        tool_messages(messages) > 0 ->
          text("parent done")

        true ->
          calls([
            call("c_delegate", "delegate_task", %{"task" => "child-task", "template" => "worker"})
          ])
      end
    end)

    parent = agent(name: "parent", plugins: [Nous.Plugins.SubAgent])

    assert {:ok, %{outcome: {:ok, _}, trace: trace}} =
             Collector.run_sample(fn ->
               Nous.run(parent, "go", deps: %{sub_agent_templates: %{"worker" => worker}})
             end)

    starts = for e <- named(trace, @run_start), do: e.metadata
    [root] = Enum.filter(starts, &(&1.agent_name == "parent"))
    [child] = Enum.filter(starts, &(&1.agent_name == "worker"))

    assert root.parent_agent_run_id == nil
    assert child.parent_agent_run_id == root.agent_run_id
    assert child.parent_tool_call_id == "c_delegate"
    assert child.sub_agent_template == "worker"

    child_requests =
      for %Event{metadata: %{agent_run_id: id} = meta} <- named(trace, @model_start),
          id == child.agent_run_id,
          do: meta

    assert [%{messages: messages}] = child_requests
    assert user_prompt(messages) == "child-task"

    assert [%{id: "c_delegate", outcome: :executed}] = Trace.tool_calls(trace)

    assert [%{agent_run_id: child_run}] =
             Trace.runs(trace) |> Enum.filter(&(&1.agent_run_id == child.agent_run_id))

    assert child_run == child.agent_run_id
  end

  # ── failures ───────────────────────────────────────────────────────────────

  test "a killed sample returns :killed and keeps its partial trace" do
    me = self()

    stuck =
      tool(
        "stuck",
        fn _ctx, _ ->
          send(me, :tool_entered)
          Process.sleep(10_000)
        end,
        timeout: nil
      )

    script(fn _ -> calls([call("c_stuck", "stuck")]) end)

    assert {:ok, %{outcome: :killed, trace: trace, duration_ms: duration_ms}} =
             Collector.run_sample(fn -> Nous.run(agent(tools: [stuck]), "go") end, timeout: 300)

    assert_received :tool_entered
    assert duration_ms >= 300 and duration_ms < 5_000

    names = Enum.map(trace.events, & &1.name)
    assert @run_start in names
    assert @model_start in names
    refute @run_stop in names
    refute @run_exception in names

    # The start had no stop: the collector synthesized one at the end.
    assert [%Event{metadata: %{tool_call_id: "c_stuck"}}] = named(trace, @tool_start)

    assert %Event{name: @tool_stop, measurements: %{}, metadata: stop} = List.last(trace.events)
    assert %{tool_call_id: "c_stuck", tool_name: "stuck", outcome: :incomplete} = stop

    # ...which Trace.tool_calls/2 does not count twice.
    assert [%{id: "c_stuck", outcome: :incomplete}] = Trace.tool_calls(trace, include: :all)
    assert sink_rows(trace.trace_id) == []
  end

  test "a failed run's trace carries the reason and the last request messages" do
    capture_requests()
    echo = tool("echo", fn _ctx, _ -> "echoed" end)

    script(fn messages ->
      if tool_messages(messages) == 0,
        do: calls([call("c1", "echo")]),
        else: {:error, :provider_down}
    end)

    assert {:ok, %{outcome: {:error, :provider_down}, trace: trace}} =
             Collector.run_sample(fn -> Nous.run(agent(tools: [echo]), "please echo") end)

    assert [%Event{metadata: %{reason: :provider_down, kind: :error}}] =
             named(trace, @run_exception)

    requests = for e <- named(trace, @model_start), do: e.metadata.messages
    assert requests == emitted_requests(trace.trace_id)
    assert [_first, last] = requests
    assert user_prompt(last) == "please echo"
    assert [%Message{role: :tool}] = Enum.filter(last, &(&1.role == :tool))
  end

  test "a raise inside the sample is an {:exit, reason} error" do
    assert {:ok, %{outcome: {:error, {:exit, {%RuntimeError{message: "boom"}, _}}}}} =
             Collector.run_sample(fn -> raise "boom" end)
  end

  # ── caps ───────────────────────────────────────────────────────────────────

  test "the event cap truncates the trace and counts what was dropped" do
    script(fn _ -> text("ok") end)

    assert {:ok, %{outcome: {:ok, _}, trace: full}} =
             Collector.run_sample(fn -> Nous.run(agent(), "hi") end)

    assert {:ok, %{outcome: {:ok, _}, trace: capped}} =
             Collector.run_sample(fn -> Nous.run(agent(), "hi") end, max_events: 3)

    refute full.truncated?
    assert capped.truncated?
    assert length(capped.events) == 3
    assert capped.dropped == length(full.events) - 3

    assert Enum.map(capped.events, & &1.name) ==
             full.events |> Enum.take(3) |> Enum.map(& &1.name)
  end

  test "the byte cap stops at the first event whose content does not fit" do
    script(fn _ -> text("ok") end)

    assert {:ok, %{trace: trace}} =
             Collector.run_sample(fn -> Nous.run(agent(), String.duplicate("x", 500)) end,
               max_bytes: 200
             )

    assert trace.truncated?
    assert trace.dropped > 0
    assert [@run_start | _] = Enum.map(trace.events, & &1.name)
    # The request messages are the first content past the cap; nothing after
    # them is stored either.
    assert named(trace, @model_start) == []
    assert named(trace, @run_stop) == []
  end

  # ── request-message deltas ─────────────────────────────────────────────────

  test "a 5-iteration tool loop stores request deltas and finalizes full messages" do
    capture_requests()
    me = self()
    counter = tool("count", fn _ctx, _ -> "counted" end)

    script(fn messages ->
      n = tool_messages(messages)
      if n < 5, do: calls([call("c#{n}", "count")]), else: text("done")
    end)

    assert {:ok, %{outcome: {:ok, _}, trace: trace}} =
             Collector.run_sample(fn ->
               result = Nous.run(agent(tools: [counter]), "loop")
               # Still inside the sample: the sink holds the stored form.
               send(me, {:stored, sink_rows(RunScope.current().trace_id)})
               result
             end)

    assert_received {:stored, rows}

    stored =
      for {_key, @model_start, _m, meta, extra} <- rows,
          do: {Map.has_key?(meta, :messages), extra}

    assert [{true, nil} | deltas] = stored
    assert length(deltas) == 5
    assert Enum.all?(deltas, &match?({false, {:delta, [_ | _]}}, &1))

    requests = for e <- named(trace, @model_start), do: e.metadata.messages
    assert length(requests) == 6
    assert requests == emitted_requests(trace.trace_id)
  end

  test "a request that does not extend the previous one is stored in full" do
    trace_id = RunScope.new_trace_id()
    :ok = Collector.register(trace_id)

    emit = fn messages ->
      Collector.handle_event(
        @model_start,
        %{},
        %{trace_id: trace_id, agent_run_id: "r1", messages: messages},
        nil
      )
    end

    a = Message.user("a")
    b = Message.assistant("b")
    c = Message.user("c")
    summary = Message.system("summary")

    emit.([a, b])
    emit.([a, b, c])
    emit.([summary, c])
    emit.([summary, c, b])

    extras = for {_, _, _, _, extra} <- sink_rows(trace_id), do: extra
    assert [nil, {:delta, [^c]}, nil, {:delta, [^b]}] = extras

    trace = Collector.finalize(trace_id)

    assert Enum.map(trace.events, & &1.metadata.messages) == [
             [a, b],
             [a, b, c],
             [summary, c],
             [summary, c, b]
           ]
  end

  # ── dedupe ─────────────────────────────────────────────────────────────────

  test "the DecisionGuard copy of a hook decision is dropped, other hook decisions kept" do
    trace_id = RunScope.new_trace_id()
    :ok = Collector.register(trace_id)

    meta = %{trace_id: trace_id, tool_call_id: "t1"}

    Collector.handle_event(
      [:nous, :hook, :decision],
      %{},
      Map.put(meta, :hook_name, "decision_guard:pre_tool_use"),
      nil
    )

    Collector.handle_event(
      [:nous, :decision_guard, :verdict],
      %{},
      Map.put(meta, :surface, :pre_tool_use),
      nil
    )

    Collector.handle_event(
      [:nous, :hook, :decision],
      %{},
      Map.put(meta, :hook_name, "my_policy"),
      nil
    )

    trace = Collector.finalize(trace_id)

    assert [
             %Event{name: [:nous, :decision_guard, :verdict]},
             %Event{name: [:nous, :hook, :decision], metadata: %{hook_name: "my_policy"}}
           ] = trace.events

    assert trace.dropped == 0
    refute trace.truncated?
  end

  # ── handler ────────────────────────────────────────────────────────────────

  test "a detached handler makes run_sample fail closed without running the sample" do
    on_exit(fn -> Collector.attach() end)
    assert Collector.attached?()

    :ok = :telemetry.detach(Collector.handler_id())
    refute Collector.attached?()

    me = self()

    assert {:error, :trace_handler_detached} =
             Collector.run_sample(fn -> send(me, :ran) end)

    refute_received :ran

    :ok = Collector.attach()
    :ok = Collector.attach()
    assert Collector.attached?()
  end

  test "the handler is total over garbage input" do
    trace_id = RunScope.new_trace_id()
    :ok = Collector.register(trace_id)

    garbage = [
      {nil, nil, nil},
      {:not_a_list, :x, %{trace_id: trace_id}},
      {"string", %{}, %{trace_id: trace_id}},
      {[:nous, :agent, :run, :start], :not_a_map, :not_a_map},
      {[:nous, :agent, :run, :start], %{}, %{trace_id: 123}},
      {[:nous, :agent, :run, :start], %{}, %{trace_id: nil}},
      {[:nous, :agent, :run, :start], [1, 2], %{trace_id: trace_id}},
      {@model_start, %{}, %{trace_id: trace_id, agent_run_id: nil, messages: :nope}},
      {@model_start, %{}, %{trace_id: trace_id, agent_run_id: "r", messages: [1 | 2]}},
      {@model_start, %{}, %{trace_id: trace_id, agent_run_id: "r", messages: [:a, :b]}},
      {@model_start, %{}, %{trace_id: trace_id, agent_run_id: "r", messages: [:a, :b, :c]}},
      {[:nous, :hook, :decision], %{}, %{trace_id: trace_id, hook_name: 42}},
      {@tool_start, %{}, %{trace_id: trace_id, tool_call_id: 7}},
      {@tool_stop, %{}, %{trace_id: trace_id, tool_call_id: nil, outcome: "weird"}}
    ]

    for {name, measurements, metadata} <- garbage do
      assert :ok == Collector.handle_event(name, measurements, metadata, :any_config)
    end

    # A finalized trace no longer accepts events, and nothing raises.
    trace = Collector.finalize(trace_id)
    assert :ok == Collector.handle_event(@run_start, %{}, %{trace_id: trace_id}, nil)
    assert sink_rows(trace_id) == []

    assert Enum.all?(trace.events, &(is_list(&1.name) and is_map(&1.measurements)))
    assert Enum.map(trace.events, & &1.seq) == Enum.to_list(0..(length(trace.events) - 1))
    # The improper list is not a prefix of anything, the [:a, :b] request is.
    assert [:nope, [1 | 2], [:a, :b], [:a, :b, :c]] =
             for(%Event{name: @model_start, metadata: %{messages: m}} <- trace.events, do: m)
  end

  test "invalid options and a trace_id in use are errors" do
    assert {:error, {:invalid_option, :timeout, 0}} =
             Collector.run_sample(fn -> :ok end, timeout: 0)

    assert {:error, {:invalid_option, :role, :boss}} =
             Collector.run_sample(fn -> :ok end, role: :boss)

    assert {:error, {:unknown_options, [:bogus]}} = Collector.run_sample(fn -> :ok end, bogus: 1)

    trace_id = RunScope.new_trace_id()
    :ok = Collector.register(trace_id)
    assert {:error, :trace_id_in_use} = Collector.run_sample(fn -> :ok end, trace_id: trace_id)
    :ok = Collector.unregister(trace_id)
  end

  test "the sample runs under the seeded trace id and role" do
    trace_id = RunScope.new_trace_id()

    assert {:ok, %{outcome: {:ok, scope}, trace: %Trace{trace_id: ^trace_id}}} =
             Collector.run_sample(fn -> {:ok, RunScope.current()} end,
               trace_id: trace_id,
               role: :judge
             )

    assert %{trace_id: ^trace_id, role: :judge} = scope
  end

  test "the table owner sweeps registrations of dead owners and their rows" do
    owner = spawn(fn -> :ok end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, _, _, _}

    trace_id = RunScope.new_trace_id()
    :ok = Collector.register(trace_id, owner: owner)

    Collector.handle_event(
      @model_start,
      %{},
      %{trace_id: trace_id, agent_run_id: "r", messages: [:m]},
      nil
    )

    assert [_] = sink_rows(trace_id)

    :ok = TableOwner.sweep()

    refute :ets.member(TableOwner.registry(), trace_id)
    assert sink_rows(trace_id) == []
    assert :ets.match(TableOwner.requests(), {{trace_id, :_}, :_}) == []
  end
end

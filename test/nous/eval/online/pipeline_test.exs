Code.require_file("online_helpers.exs", __DIR__)

defmodule Nous.Eval.Online.PipelineTest do
  # async: false - the online instance is a named process with a global
  # telemetry handler, and the model stub lives in the application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nous.Eval.OnlineHelpers

  alias Nous.Eval.{Online, Sample, Score, Trace}
  alias Nous.Eval.Online.{Coordinator, OTel, Redactor, Registry, Sampler}
  alias Nous.Eval.Trace.{Collector, Event}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @judge "openai:gpt-4o-mini"

  defmodule CanaryScorer do
    @moduledoc false
    # A skeleton scorer whose explanation quotes the canary, as a judge
    # quoting the sample would.
    @behaviour Nous.Eval.Scorer

    @canary "CANARY-7f3a91c2e4b8d605"

    def id, do: "canary_quote"
    def init(opts), do: {:ok, opts}
    def content, do: :none

    def score(_input, _config) do
      {:ok,
       %Score{
         name: "canary_quote",
         value: :pass,
         passed?: true,
         reason: "quoted #{@canary}",
         details: %{"quote" => @canary}
       }}
    end
  end

  defmodule SelfJudge do
    @moduledoc false
    # A model-graded scorer that calls `Nous.run` itself, without setting a
    # role: online eval must not sample this run.
    @behaviour Nous.Eval.Scorer

    def id, do: "self_judge"
    def kind, do: :model_graded
    def content, do: :none
    def init(opts), do: {:ok, opts}

    def score(_input, _config) do
      {:ok, result} = Nous.run(Nous.new("openai:gpt-4o-mini", name: "judge_agent"), "grade it")

      {:ok,
       %Score{
         name: "self_judge",
         value: :pass,
         passed?: true,
         metadata: %{usage: result.usage, model: "openai:gpt-4o-mini"}
       }}
    end
  end

  defmodule Raises do
    @moduledoc false
    @behaviour Nous.Eval.Scorer
    def id, do: "raises"
    def init(opts), do: {:ok, opts}
    def content, do: :none
    def score(_input, _config), do: raise("scorer bug")
  end

  defmodule Hangs do
    @moduledoc false
    @behaviour Nous.Eval.Scorer
    def id, do: "hangs"
    def init(opts), do: {:ok, opts}
    def content, do: :none

    def score(_input, _config) do
      Process.sleep(:infinity)
    end
  end

  defmodule Passes do
    @moduledoc false
    @behaviour Nous.Eval.Scorer
    def id, do: "passes"
    def init(opts), do: {:ok, opts}
    def content, do: :none
    def score(_input, _config), do: {:ok, %Score{name: "passes", value: 1.0, passed?: true}}
  end

  defmodule FailingStore do
    @moduledoc false
    # A store whose writes fail like a full disk; reports every attempt.
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test)}

    def put_run(test, run) do
      send(test, {:put_attempt, run.id})
      {:error, :enospc}
    end
  end

  setup do
    install_stub()
    attach_online_events()
    :ok
  end

  defp judge_rule,
    do: [name: "quality", scorers: [{Nous.Eval.Scorers.Judge, judge: @judge}, CanaryScorer]]

  defp coordinator(name \\ Online), do: Process.whereis(Coordinator.name(name))

  # ── capture ─────────────────────────────────────────────────────────────────

  describe "capture" do
    test "a sampled run is stored redacted, with its skeleton", %{tmp_dir: root} do
      start_online!(base_opts(root))

      assert {:ok, %{output: "Answer: " <> _}} = run!("TOOL please")
      :ok = Online.drain()

      assert [%{sample: %Sample{} = sample, info: info}] = samples!(root)
      assert sample.outcome == :ok
      assert sample.output == nil
      assert info["redaction"] == "dropped"
      assert sample.usage.requests == 2
      assert is_float(sample.cost)

      names = Enum.map(sample.trace.events, & &1.name)
      assert Enum.count(names, &(&1 == [:nous, :agent, :run, :start])) == 1
      assert Enum.count(names, &(&1 == [:nous, :agent, :run, :stop])) == 1
      assert [%{name: "lookup", outcome: :executed}] = Trace.tool_calls(sample.trace)

      for %Event{metadata: meta} <- sample.trace.events do
        refute Map.has_key?(meta, :messages)
        refute Map.has_key?(meta, :arguments)
        refute Map.has_key?(meta, :result)
        refute Map.has_key?(meta, :response)
      end
    end

    # F14
    test "sub-agent and parallel tool events land in the root's one sample", %{tmp_dir: root} do
      start_online!(base_opts(root))

      assert {:ok, _} = run!("SUB now")
      assert {:ok, _} = run!("PARALLEL now")
      :ok = Online.drain()

      assert [sub, parallel] = samples!(root) |> Enum.map(& &1.sample) |> order_by_tools()

      runs = Trace.runs(sub.trace)
      assert [%{agent_name: "support_bot"} = root_run, %{agent_name: "sub_agent"} = child] = runs
      assert child.parent_agent_run_id == root_run.agent_run_id
      assert [%{name: "delegate", outcome: :executed}] = Trace.tool_calls(sub.trace)

      assert [%{outcome: :executed}, %{outcome: :executed}] = Trace.tool_calls(parallel.trace)
    end

    # F6
    test "a trace an offline eval collects is not captured online", %{tmp_dir: root} do
      start_online!(base_opts(root))
      :ok = Collector.attach()

      assert {:ok, %{trace: %Trace{events: [_ | _]}}} =
               Collector.run_sample(fn -> run!("hello") end)

      :ok = Online.drain()
      assert samples!(root) == []
      assert %{seen_roots: 1, sampled: 1, captured: 0} = window!()
    end

    # F5
    test "online never samples the runs of its own scorers", %{tmp_dir: root} do
      start_online!(
        base_opts(root,
          rules: [[name: "self", scorers: [{SelfJudge, model: "openai:gpt-4o-mini"}]]],
          budget: [max_cost: 10.0, per: :hour]
        )
      )

      for i <- 1..3, do: assert({:ok, _} = run!("hello #{i}"))
      :ok = Online.drain()

      samples = samples!(root)
      assert length(samples) == 3

      for %{sample: sample} <- samples do
        assert [%{agent_name: "support_bot"}] = Trace.runs(sample.trace)
        assert [%Score{name: "self/self_judge"}] = sample.scores
      end

      assert %{seen_roots: 3, captured: 3, stored: 3} = window!()
    end

    # F7
    test "a raising or non-boolean filter means not captured, never a failed request",
         %{tmp_dir: root} do
      start_online!(base_opts(root, filter: fn meta -> if meta.agent_name, do: raise("bug") end))

      assert {:ok, _} = run!("hello")
      assert {:ok, _} = run!("hello", agent: agent("other"))
      :ok = Online.drain()

      assert samples!(root) == []
      assert handler_attached?()
      assert %{seen_roots: 2, filter_error: 2, captured: 0} = window!()
    end

    test "the agents allowlist and the rate gate capture", %{tmp_dir: root} do
      start_online!(base_opts(root, agents: ["support_bot"]))

      assert {:ok, _} = run!("hello", agent: agent("other_bot"))
      assert {:ok, _} = run!("hello")
      :ok = Online.drain()

      assert [%{sample: sample}] = samples!(root)
      assert [%{agent_name: "support_bot"}] = Trace.runs(sample.trace)
    end

    test "sample_by: :session captures every turn of a sampled session", %{tmp_dir: root} do
      sessions = for i <- 1..40, do: "session-#{i}"
      {kept, dropped} = Enum.split_with(sessions, &Online.sampled?(&1, 0.5))
      assert kept != [] and dropped != []

      start_online!(base_opts(root, sample_rate: 0.5, sample_by: :session))

      for session <- Enum.take(kept, 2) ++ Enum.take(dropped, 2), _turn <- 1..3 do
        assert {:ok, _} = run!("turn", deps: %{session_id: session})
      end

      :ok = Online.drain()
      groups = samples!(root) |> Enum.map(& &1.info["group"]) |> Enum.frequencies()
      assert map_size(groups) == 2
      assert Enum.all?(Map.values(groups), &(&1 == 3))
    end

    test "a sampling salt decides which sessions are captured", %{tmp_dir: root} do
      salt = "pipeline-salt-0123456789"
      sessions = for i <- 1..80, do: "session-#{i}"

      # Sessions the salt flips either way: the unsalted decision, which a
      # client can compute, predicts none of them. Two flipped in, one out:
      # salted capture finds two sessions, unsalted would find one.
      salted? = &Sampler.sampled?(&1, 0.5, salt)
      flipped_in = Enum.filter(sessions, &(salted?.(&1) and not Online.sampled?(&1, 0.5)))
      flipped_out = Enum.filter(sessions, &(Online.sampled?(&1, 0.5) and not salted?.(&1)))
      assert length(flipped_in) >= 2 and flipped_out != []

      start_online!(base_opts(root, sample_rate: 0.5, sample_by: :session, sampling_salt: salt))

      for session <- Enum.take(flipped_in, 2) ++ Enum.take(flipped_out, 1), _turn <- 1..2 do
        assert {:ok, _} = run!("turn", deps: %{session_id: session})
      end

      :ok = Online.drain()
      groups = samples!(root) |> Enum.map(& &1.info["group"]) |> Enum.frequencies()
      assert map_size(groups) == 2
      assert Enum.all?(Map.values(groups), &(&1 == 2))
    end
  end

  defp order_by_tools(samples) do
    Enum.sort_by(samples, fn s -> s.trace |> Trace.tool_calls() |> length() end)
  end

  # ── the canary ──────────────────────────────────────────────────────────────

  # The canary is in the prompt, the tool arguments, the tool result, the
  # model response, a provider error, the session id and a scorer's
  # explanation. Under every redaction path it must reach none of: the
  # store, the logs of the online pipeline, the online telemetry, the
  # exported spans.
  @modes %{
    map_text: [redact: &__MODULE__.scrub_fun/1],
    drop_content: [redact: :drop_content],
    raising: [redact: &__MODULE__.raising_fun/1],
    keys_changed: [redact: &__MODULE__.extra_key_fun/1],
    not_json: [redact: &__MODULE__.pid_fun/1]
  }

  def scrub_fun(content), do: Redactor.map_text(content, &String.replace(&1, canary(), "[R]"))
  def raising_fun(content), do: raise(ArgumentError, "cannot redact " <> inspect(content))

  def extra_key_fun(content),
    do: %{content | fields: Map.put(content.fields, {0, "smuggled"}, canary())}

  def pid_fun(content),
    do: %{content | fields: Map.new(content.fields, fn {k, _v} -> {k, self()} end)}

  for {mode, mode_opts} <- @modes do
    @mode mode
    @mode_opts mode_opts

    # F2, F4, F17, F26
    test "the canary never leaves the request path (#{mode})", %{tmp_dir: root} do
      pid = self()

      rules =
        if @mode == :map_text,
          do: [judge_rule()],
          else: [[name: "quote", scorers: [CanaryScorer]]]

      start_online!(
        base_opts(
          root,
          @mode_opts ++
            [
              rules: rules,
              budget: [max_cost: 10.0, per: :hour],
              exporter: fn sample ->
                send(pid, {:exported, sample.trace_id, OTel.spans(sample, export_content: true)})
              end
            ]
        )
      )

      # The app's own traffic (and its own logs) first, with the online
      # coordinator held: the online pipeline then runs inside the capture.
      :sys.suspend(coordinator())

      capture_log(fn ->
        assert {:ok, _} = run!("TOOL " <> canary())
        assert {:error, _} = run!("FAIL " <> canary())
        assert {:ok, _} = run!("PARALLEL " <> canary())
        assert {:ok, _} = run!("hello " <> canary(), deps: %{session_id: "s-" <> canary()})
      end)

      log =
        capture_log(fn ->
          :sys.resume(coordinator())
          :ok = Online.drain()
          :ok = Online.tick()
        end)

      exported =
        for _ <- 1..4 do
          assert_receive {:exported, _tid, spans}, 2_000
          spans
        end

      events = collect_events()
      bytes = all_bytes(root)

      refute bytes =~ canary()
      refute log =~ canary()
      refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ canary()
      refute inspect(exported, limit: :infinity, printable_limit: :infinity) =~ canary()

      samples = samples!(root)
      assert length(samples) == 4
      assert_mode(@mode, samples, bytes, exported)

      if @mode in [:raising, :keys_changed, :not_json] do
        assert Enum.any?(events, &match?({[:nous, :eval, :online, :redaction_failed], _, _}, &1))
      end
    end
  end

  defp collect_events(acc \\ []) do
    receive do
      {:online_event, name, measurements, metadata} ->
        collect_events([{name, measurements, metadata} | acc])
    after
      0 -> acc
    end
  end

  defp assert_mode(:map_text, samples, bytes, exported) do
    # Content survives, scrubbed: messages, tool arguments, results, the
    # error reason and the judge's critique all carry the replacement.
    assert bytes =~ "[R]"
    assert Enum.all?(samples, &(&1.info["redaction"] == "redacted"))

    ok = Enum.find(samples, &(Trace.tool_calls(&1.sample.trace) |> length() == 1))

    assert [%{arguments: %{"query" => "find [R]"}, result: result}] =
             Trace.tool_calls(ok.sample.trace)

    assert result =~ "[R]"
    assert ok.sample.output =~ "[R]"

    judge = Enum.find(ok.sample.scores, &(&1.name == "quality/judge"))
    assert judge.details.critique == "quotes [R]"

    attrs = exported |> List.flatten() |> Enum.flat_map(&Map.keys(&1.attributes))
    assert "gen_ai.input.messages" in attrs
  end

  defp assert_mode(:drop_content, samples, _bytes, exported) do
    assert Enum.all?(samples, &(&1.info["redaction"] == "dropped"))

    for %{sample: sample} <- samples do
      assert [%Score{reason: nil, details: details}] = sample.scores
      assert details == %{}
    end

    attrs = exported |> List.flatten() |> Enum.flat_map(&Map.keys(&1.attributes))
    refute Enum.any?(attrs, &String.ends_with?(&1, [".messages", ".arguments", ".result"]))
  end

  defp assert_mode(mode, samples, _bytes, _exported) do
    kind =
      %{raising: "raised", keys_changed: "keys_changed", not_json: "not_json"}
      |> Map.fetch!(mode)

    for %{sample: sample, info: info} <- samples do
      assert info["redaction"] == "failed"
      assert info["redaction_failure"] == kind
      assert info["explanations"] == "failed"
      # The skeleton is kept: the run is still measurable.
      assert [%{agent_name: "support_bot"} | _] = Trace.runs(sample.trace)
    end
  end

  # ── redactor time limit ─────────────────────────────────────────────────────

  # F3
  test "a hanging redactor is killed and the sample stored without content", %{tmp_dir: root} do
    start_online!(
      base_opts(root,
        redact: fn _content -> Process.sleep(:infinity) end,
        redact_timeout: 100,
        max_concurrency: 1
      )
    )

    assert {:ok, _} = run!("hello")
    :ok = Online.drain()

    assert [%{info: %{"redaction" => "failed", "redaction_failure" => "timeout"}}] =
             samples!(root)

    assert Task.Supervisor.children(Coordinator.scorer_sup(Online)) == []
    assert Task.Supervisor.children(Coordinator.task_sup(Online)) == []
  end

  # ── scorers ─────────────────────────────────────────────────────────────────

  # F10
  test "a crashing and a hanging scorer leave records next to a passing one", %{tmp_dir: root} do
    start_online!(
      base_opts(root, rules: [[name: "r", scorers: [Raises, Hangs, Passes]]], score_timeout: 200)
    )

    assert {:ok, _} = run!("hello")
    :ok = Online.drain()

    assert [%{sample: sample}] = samples!(root)
    assert [%Score{name: "r/passes", value: 1.0}] = sample.scores

    kinds = Map.new(sample.scorer_errors, &{&1.scorer, &1.kind})
    assert kinds == %{"r/raises" => :raised, "r/hangs" => :timeout}
    # The exception text could quote the sample: it is an explanation, so
    # it is dropped with the content.
    assert Enum.all?(sample.scorer_errors, &(&1.reason == nil))
    assert sample.verdict == :error

    statuses =
      for _ <- 1..3 do
        assert_receive {:online_event, [:nous, :eval, :online, :score, :stop], %{duration: d},
                        %{scorer: scorer, status: status, rule: "r"}}

        assert is_integer(d)
        {scorer, status}
      end

    assert Map.new(statuses) == %{"raises" => :error, "hangs" => :timeout, "passes" => :ok}
  end

  test "a rule samples within captured traces and `when` sees the redacted sample",
       %{tmp_dir: root} do
    start_online!(
      base_opts(root,
        rules: [
          [name: "all", scorers: [Passes]],
          [name: "never", sample_rate: 0.0, scorers: [Passes]],
          [name: "errors", when: &(&1.outcome == :error), scorers: [Passes]]
        ]
      )
    )

    assert {:ok, _} = run!("hello")
    assert {:error, _} = run!("FAIL")
    :ok = Online.drain()

    rules = samples!(root) |> Enum.map(&{&1.sample.outcome, &1.info["rules"]}) |> Map.new()
    assert rules == %{ok: ["all"], error: ["all", "errors"]}
  end

  # ── budget ──────────────────────────────────────────────────────────────────

  # F11
  test "parallel judges cannot overshoot the budget: reservation before the call",
       %{tmp_dir: root} do
    # One judge call: two requests at the reserve tokens (16k in, 2k out) of
    # gpt-4o-mini = 0.0072 USD; the stub bills exactly that.
    reservation = 2 * (16_000 * 0.15 + 2_000 * 0.6) / 1_000_000

    start_online!(
      base_opts(root,
        redact: &scrub_fun/1,
        rules: [[name: "q", scorers: [{Nous.Eval.Scorers.Judge, judge: @judge}]]],
        # Budget windows are aligned to monotonic time: a window of ~30k
        # years never rolls over mid-test, where `:hour` would at an edge.
        budget: [max_cost: reservation * 3 * 1.000001, per: 1_000_000_000_000_000],
        max_concurrency: 8
      )
    )

    tasks = for i <- 1..8, do: Task.async(fn -> run!("hello #{i}") end)
    Enum.each(tasks, &Task.await/1)
    :ok = Online.drain()

    samples = Enum.map(samples!(root), & &1.sample)
    judged = Enum.filter(samples, &match?([%Score{name: "q/judge"}], &1.scores))
    starved = Enum.filter(samples, &(&1.skipped == [{"q/judge", "budget_exhausted"}]))

    assert length(judged) == 3
    assert length(starved) == 5

    assert %{skipped_budget: 5, scored: 3} = window!()
    assert_received {:online_event, [:nous, :eval, :online, :budget_exhausted], _, %{rule: "q"}}
  end

  test "a new budget window admits the judge again", %{tmp_dir: root} do
    reservation = 2 * (16_000 * 0.15 + 2_000 * 0.6) / 1_000_000

    start_online!(
      base_opts(root,
        redact: &scrub_fun/1,
        rules: [[name: "q", scorers: [{Nous.Eval.Scorers.Judge, judge: @judge}]]],
        budget: [max_cost: reservation * 1.000001, per: 300],
        max_concurrency: 1
      )
    )

    judged = fn ->
      :ok = Online.drain()
      samples!(root) |> Enum.count(&match?([%Score{}], &1.sample.scores))
    end

    assert {:ok, _} = run!("one")
    assert judged.() == 1
    Process.sleep(350)
    assert {:ok, _} = run!("two")
    assert judged.() == 2
  end

  # ── backpressure ────────────────────────────────────────────────────────────

  # F9 (admission)
  test "a burst above max_in_flight is shed at admission and every request completes",
       %{tmp_dir: root} do
    start_online!(base_opts(root, max_in_flight: 2))

    tasks = for i <- 1..20, do: Task.async(fn -> run!("GATE #{i}") end)

    gated =
      for _ <- 1..20 do
        assert_receive {:gated, pid}, 5_000
        pid
      end

    %{table: table} = Registry.shared(Online)
    assert :ets.info(table, :size) == 2

    Enum.each(gated, &send(&1, :go))
    assert Enum.all?(tasks, &match?({:ok, _}, Task.await(&1)))
    :ok = Online.drain()

    assert length(samples!(root)) == 2
    assert %{captured: 2, dropped_admission: 18} = window!()

    assert_received {:online_event, [:nous, :eval, :online, :dropped], %{count: 18},
                     %{reason: :admission}}
  end

  # F9 (queue)
  test "closed traces above max_queue are discarded without blocking", %{tmp_dir: root} do
    test = self()

    start_online!(
      base_opts(root,
        max_queue: 2,
        max_concurrency: 1,
        redact: fn content ->
          send(test, {:redacting, self()})
          receive do: (:go -> content)
        end,
        redact_timeout: 10_000
      )
    )

    for i <- 1..10, do: assert({:ok, _} = run!("hello #{i}"))

    assert_receive {:redacting, first}, 2_000
    {:message_queue_len, len} = Process.info(coordinator(), :message_queue_len)
    assert len <= 2

    send(first, :go)

    for _ <- 1..2 do
      assert_receive {:redacting, next}, 2_000
      send(next, :go)
    end

    :ok = Online.drain()
    assert length(samples!(root)) == 3
    assert %{captured: 10, dropped_queue: 7, stored: 3} = window!()
    %{table: table} = Registry.shared(Online)
    assert :ets.info(table, :size) == 0
  end

  # F13
  test "a run that never stops is finalized as abandoned by the sweep", %{tmp_dir: root} do
    start_online!(base_opts(root, max_trace_age: 50))

    task = Task.async(fn -> run!("GATE") end)
    assert_receive {:gated, _pid}, 2_000
    Task.shutdown(task, :brutal_kill)

    Process.sleep(80)
    :ok = Online.tick()
    :ok = Online.drain()

    assert [%{sample: sample, info: info}] = samples!(root)
    assert sample.outcome == :killed
    assert info["abandoned"] == true
    assert [%{status: :incomplete}] = Trace.runs(sample.trace)

    %{table: table} = Registry.shared(Online)
    assert :ets.info(table, :size) == 0
  end

  test "a backlog older than max_trace_age is processed, not counted lost",
       %{tmp_dir: root} do
    test = self()

    start_online!(
      base_opts(root,
        max_trace_age: 50,
        max_concurrency: 1,
        redact: fn content ->
          send(test, {:redacting, self()})
          receive do: (:go -> content)
        end,
        redact_timeout: 10_000
      )
    )

    for i <- 1..3, do: assert({:ok, _} = run!("hello #{i}"))
    assert_receive {:redacting, first}, 2_000

    # Two closed traces wait behind the blocked job, older than max_trace_age.
    Process.sleep(80)
    flush_online_events()
    assert %{lost: 0} = window!()

    send(first, :go)

    for _ <- 1..2 do
      assert_receive {:redacting, next}, 2_000
      send(next, :go)
    end

    :ok = Online.drain()
    assert length(samples!(root)) == 3
    assert %{lost: 0, stored: 3} = window!()
  end

  test "traces queued in a coordinator that went away are swept as lost", %{tmp_dir: root} do
    test = self()

    start_online!(
      base_opts(root,
        max_trace_age: 50,
        max_concurrency: 1,
        redact: fn content ->
          send(test, {:redacting, self()})
          receive do: (:go -> content)
        end,
        redact_timeout: 10_000
      )
    )

    for i <- 1..3, do: assert({:ok, _} = run!("hello #{i}"))
    # The first job runs (blocked); the other two are queued in the coordinator.
    assert_receive {:redacting, _first}, 2_000

    # Both calls return only once the old process is gone and the new one
    # has finished init/1, which releases the rows queued to the old one.
    :ok = Supervisor.terminate_child(Online, Coordinator)
    {:ok, _restarted} = Supervisor.restart_child(Online, Coordinator)

    Process.sleep(80)
    flush_online_events()
    assert %{lost: 2} = window!()

    %{table: table} = Registry.shared(Online)
    assert :ets.info(table, :size) == 0
  end

  # ── handler resilience ──────────────────────────────────────────────────────

  # F8
  test "malformed events never detach the handler; a detached handler is re-attached",
       %{tmp_dir: root} do
    start_online!(base_opts(root))

    for meta <- [%{}, %{trace_id: 42}, %{trace_id: "x", agent_run_id: :atom}, %{role: "agent"}] do
      :telemetry.execute([:nous, :agent, :run, :start], %{}, meta)
      :telemetry.execute([:nous, :agent, :run, :stop], %{}, meta)
      :telemetry.execute([:nous, :agent, :run, :exception], %{}, Map.put(meta, :trace_id, nil))
    end

    assert handler_attached?()

    :telemetry.detach({Online, Online})
    refute handler_attached?()
    :ok = Online.tick()
    assert handler_attached?()
    assert_received {:online_event, [:nous, :eval, :online, :handler_reattached], %{count: 1}, _}

    assert {:ok, _} = run!("hello")
    :ok = Online.drain()
    assert [_] = samples!(root)
  end

  # F24
  test "stopping the instance detaches its handler; runs go on", %{tmp_dir: root} do
    start_online!(base_opts(root))
    assert handler_attached?()

    :ok = stop_supervised(Online)
    refute handler_attached?()
    assert {:ok, _} = run!("hello")
  end

  # F25
  test "the request path makes no call: runs complete with the coordinator dead",
       %{tmp_dir: root} do
    start_online!(base_opts(root))
    pid = coordinator()
    ref = Process.monitor(pid)
    :sys.suspend(pid)

    # A suspended coordinator would block any call; runs still return.
    for i <- 1..5, do: assert({:ok, _} = run!("hello #{i}"))

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    for i <- 1..5, do: assert({:ok, _} = run!("after #{i}"))
  end

  test "the hot path for a run that is not sampled is cheap", %{tmp_dir: root} do
    start_online!(base_opts(root, sample_rate: 0.0))
    shared = Registry.shared(Online)

    meta = %{
      trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
      agent_run_id: "00f067aa0ba902b7",
      role: :agent
    }

    {micros, :ok} =
      :timer.tc(fn ->
        for _ <- 1..10_000 do
          Nous.Eval.Online.Handler.handle_event([:nous, :agent, :run, :start], %{}, meta, shared)
        end

        :ok
      end)

    # Not a benchmark gate: a generous bound that catches an accidental
    # call or scan (a few µs per run on any machine).
    assert micros / 10_000 < 50
  end

  # ── store ───────────────────────────────────────────────────────────────────

  # F18
  test "a failing store is retried, then the batch is dropped and counted", %{tmp_dir: root} do
    start_online!(
      base_opts(root,
        store: {FailingStore, test: self()},
        retention: :infinity,
        store_backoff: 10
      )
    )

    assert {:ok, _} = run!("hello")
    :ok = Online.drain()

    for _ <- 1..3, do: assert_receive({:put_attempt, _id}, 1_000)
    refute_receive {:put_attempt, _id}, 100

    assert %{dropped_store: 1, stored: 0} = window!()

    assert_received {:online_event, [:nous, :eval, :online, :dropped], %{count: 1},
                     %{reason: :store}}

    assert {:ok, _} = run!("again")
    :ok = Online.drain()
    assert_receive {:put_attempt, _id}, 1_000
  end

  # F19
  test "two instances on one root: each trace is captured once, every record parses",
       %{tmp_dir: root} do
    start_online!(base_opts(root, name: :online_a, instance: "a"))
    start_online!(base_opts(root, name: :online_b, instance: "b"))

    tasks = for i <- 1..20, do: Task.async(fn -> run!("hello #{i}") end)
    Enum.each(tasks, &Task.await/1)
    :ok = Online.drain(:online_a)
    :ok = Online.drain(:online_b)

    a = samples!(root, instance: "a")
    b = samples!(root, instance: "b")
    ids = Enum.map(a ++ b, & &1.sample.trace_id)
    assert length(ids) == 20
    assert length(Enum.uniq(ids)) == 20

    for path <- Path.wildcard(Path.join(root, "runs/*.json")) do
      assert {:ok, %Nous.Eval.Run{}} = path |> File.read!() |> Nous.Eval.Codec.decode_run_json()
    end

    for line <- root |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.flat_map(&File.stream!/1) do
      assert {:ok, _} = JSON.decode(line)
    end
  end

  # F23
  test "retention deletes expired online runs and nothing else", %{tmp_dir: root} do
    store = store!(root)
    {module, state} = store
    old = DateTime.add(DateTime.utc_now(), -10, :day)

    {:ok, state} =
      module.put_run(state, %Nous.Eval.Run{
        id: "online-old",
        task: "online:default",
        started_at: old
      })

    {:ok, _state} =
      module.put_run(state, %Nous.Eval.Run{id: "offline-old", task: "MyApp.Eval", started_at: old})

    dataset = Path.join(root, "promoted.jsonl")
    File.write!(dataset, ~s({"id":"kept"}\n))

    start_online!(base_opts(root))
    assert {:ok, 0} = Online.prune()
    assert {:ok, _} = run!("hello")
    :ok = Online.drain()

    {_, fresh} = store!(root)
    assert {:error, :not_found} = module.get_run(fresh, "online-old")
    assert {:ok, _} = module.get_run(fresh, "offline-old")
    assert [_] = samples!(root)
    assert File.read!(dataset) == ~s({"id":"kept"}\n)
  end

  test "retention: :infinity never prunes", %{tmp_dir: root} do
    start_online!(base_opts(root, retention: :infinity))
    assert {:ok, 0} = Online.prune()
  end

  # ── smoke (5.9) ─────────────────────────────────────────────────────────────

  test "smoke: 100 requests at rate 0.1 store ~10 redacted, scored traces", %{tmp_dir: root} do
    start_online!(
      base_opts(root,
        sample_rate: 0.1,
        redact: &scrub_fun/1,
        rules: [
          [
            name: "quality",
            scorers: [Passes, Nous.Eval.Scorers.MaxLatency |> then(&{&1, max_ms: 60_000})]
          ]
        ]
      )
    )

    # Seeded trace ids make the sampled count reproducible.
    ids = for i <- 1..100, do: :crypto.hash(:md5, "smoke-#{i}") |> Base.encode16(case: :lower)
    expected = Enum.count(ids, &Online.sampled?(&1, 0.1))

    for {tid, i} <- Enum.with_index(ids) do
      Nous.Telemetry.RunScope.with_scope(%{trace_id: tid}, fn ->
        assert {:ok, _} = run!("TOOL request #{i} " <> canary())
      end)
    end

    :ok = Online.drain()
    samples = samples!(root)
    bytes = all_bytes(root)
    counts = window!()

    assert length(samples) == expected
    assert Enum.all?(samples, &(&1.info["redaction"] == "redacted"))
    assert Enum.all?(samples, &(length(&1.sample.scores) == 2))
    refute bytes =~ canary()

    if System.get_env("NOUS_ONLINE_SMOKE") do
      IO.puts("""

      online smoke: requests=100 rate=0.1 expected_sampled=#{expected}
        window: seen_roots=#{counts.seen_roots} captured=#{counts.captured} stored=#{counts.stored} scored=#{counts.scored} redaction_failed=#{counts.redaction_failed}
        stored samples=#{length(samples)} redacted=#{Enum.count(samples, &(&1.info["redaction"] == "redacted"))} with_scores=#{Enum.count(samples, &(&1.sample.scores != []))}
        verdicts=#{inspect(Enum.frequencies(Enum.map(samples, & &1.sample.verdict)))}
        canary hits in store=#{length(String.split(bytes, canary())) - 1} "[R]" replacements=#{length(String.split(bytes, "[R]")) - 1}
      """)
    end
  end
end

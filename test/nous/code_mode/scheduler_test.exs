defmodule Nous.CodeMode.SchedulerTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.CodeMode.Scheduler
  alias Nous.Session.Event
  alias Nous.Session.Log
  alias Nous.Tool

  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Tool modules. `concurrency_safe?/1` is read off `tool.module`, so these have
  # to be real, loaded modules — which is also the honest shape: a tool declares
  # its own concurrency safety, the scheduler never guesses on its behalf.
  # ---------------------------------------------------------------------------

  defmodule Safe do
    @moduledoc false
    def concurrency_safe?(_args), do: true
  end

  defmodule NoDeclaration do
    @moduledoc false
    # Deliberately exports nothing. Absent attribute => exclusive.
    def unrelated, do: :ok
  end

  defmodule Raising do
    @moduledoc false
    def concurrency_safe?(_args), do: raise("cannot decide")
  end

  defmodule Throwing do
    @moduledoc false
    def concurrency_safe?(_args), do: throw(:nope)
  end

  defmodule Exiting do
    @moduledoc false
    def concurrency_safe?(_args), do: exit(:nope)
  end

  defmodule Truthy do
    @moduledoc false
    # Truthy but not `true`. Only `true` means parallel.
    def concurrency_safe?(_args), do: :yes
  end

  defmodule PerArgs do
    @moduledoc false
    def concurrency_safe?(args), do: args["safe"] == true
  end

  defmodule Internal do
    @moduledoc false
    defstruct [:secret, :stacktrace]
  end

  # ---------------------------------------------------------------------------

  describe "commit ordering" do
    test "commits in submission order even when later sub-calls finish first" do
      test_pid = self()

      dispatch = fn tool, args, _run_ctx ->
        Process.sleep(args["ms"])
        send(test_pid, {:finished, tool.name})
        {:ok, tool.name}
      end

      sched = start_scheduler(dispatch: dispatch, max_parallel: 3)

      tickets =
        for {name, ms} <- [{"first", 150}, {"second", 80}, {"third", 0}] do
          submit!(sched, tool(name), %{"ms" => ms})
        end

      # The lane's own delivery order: three sends from one process to this one,
      # so mailbox order IS commit order.
      assert commit_order(tickets) == ["first", "second", "third"]

      # Vacuous unless the work really did race to a different finish order.
      assert finish_order(3) == ["third", "second", "first"]
    end

    test "a sub-call that finishes last still commits last" do
      dispatch = fn tool, args, _run_ctx ->
        Process.sleep(args["ms"])
        {:ok, tool.name}
      end

      sched = start_scheduler(dispatch: dispatch, max_parallel: 4)

      tickets =
        for {name, ms} <- [{"a", 0}, {"b", 0}, {"c", 120}, {"d", 0}] do
          submit!(sched, tool(name), %{"ms" => ms})
        end

      assert commit_order(tickets) == ["a", "b", "c", "d"]
    end
  end

  describe "max_parallel" do
    test "the observed maximum in-flight count is exactly max_parallel" do
      inflight = new_inflight()
      sched = start_scheduler(dispatch: counting_dispatch(inflight, 60), max_parallel: 3)

      tickets = for i <- 1..6, do: submit!(sched, tool("t#{i}"), %{})
      Enum.each(tickets, fn ticket -> assert {:ok, :done} = Scheduler.await(sched, ticket) end)

      # Exactly 3, not `<= 3`: a one-sided assertion also passes for a serial
      # implementation, which would show 1.
      assert observed_max(inflight) == 3
    end

    test "defaults to 10" do
      inflight = new_inflight()
      sched = start_scheduler(dispatch: counting_dispatch(inflight, 60))

      tickets = for i <- 1..12, do: submit!(sched, tool("t#{i}"), %{})
      Enum.each(tickets, fn ticket -> assert {:ok, :done} = Scheduler.await(sched, ticket) end)

      assert observed_max(inflight) == 10
    end
  end

  describe "the exclusive barrier" do
    test "exclusive sub-calls never overlap: observed maximum in-flight is exactly 1" do
      inflight = new_inflight()
      sched = start_scheduler(dispatch: counting_dispatch(inflight, 40), max_parallel: 5)

      tickets = for i <- 1..4, do: submit!(sched, tool("t#{i}", NoDeclaration), %{})
      Enum.each(tickets, fn ticket -> assert {:ok, :done} = Scheduler.await(sched, ticket) end)

      assert observed_max(inflight) == 1
    end

    test "an exclusive sub-call drains the pool it lands in" do
      inflight = new_inflight()
      sched = start_scheduler(dispatch: counting_dispatch(inflight, 50), max_parallel: 4)

      # Two concurrency-safe calls, then an exclusive one, then two more safe
      # ones. A fail-open scheduler would run four of these at once.
      tickets =
        for {name, module} <- [
              {"safe-1", Safe},
              {"safe-2", Safe},
              {"exclusive", NoDeclaration},
              {"safe-3", Safe},
              {"safe-4", Safe}
            ] do
          submit!(sched, tool(name, module), %{})
        end

      assert commit_order(tickets) == ["safe-1", "safe-2", "exclusive", "safe-3", "safe-4"]

      # Exactly 2: the safe pairs overlap each other (so this is not a serial
      # lane), and the exclusive call overlapped nothing.
      assert observed_max(inflight) == 2
    end

    test "a queued concurrent call neither starts nor commits inside the barrier" do
      test_pid = self()

      dispatch = fn tool, _args, _run_ctx ->
        send(test_pid, {:started, tool.name})

        receive do
          {:release, name} when name == tool.name -> {:ok, tool.name}
        end
      end

      sched = start_scheduler(dispatch: dispatch, max_parallel: 5)

      exclusive = submit!(sched, tool("exclusive", NoDeclaration), %{})
      queued = submit!(sched, tool("queued", Safe), %{})

      assert_receive {:started, "exclusive"}, 1_000

      # The barrier is set and held while the exclusive call runs: the pool has
      # exactly one task and the concurrency-safe call is still queued, despite
      # max_parallel being 5.
      state = :sys.get_state(sched)
      assert state.exclusive == 0
      assert map_size(state.inflight) == 1
      assert :queue.len(state.pending) == 1

      # Nothing else even started, so nothing else could have committed. The
      # barrier is released in the lane's commit step, and commits are
      # head-of-line in submission order, so a later call committing inside the
      # window is unreachable by construction, not by luck.
      refute_received {:started, "queued"}
      refute_received {:sub_call, _ref, _outcome}

      send_release(sched, "exclusive")
      assert {:ok, "exclusive"} = Scheduler.await(sched, exclusive)

      assert_receive {:started, "queued"}, 1_000
      send_release(sched, "queued")
      assert {:ok, "queued"} = Scheduler.await(sched, queued)

      # Released at commit, not left dangling.
      state = :sys.get_state(sched)
      assert state.exclusive == nil
      assert state.cursor == 2
      assert state.inflight == %{}
    end
  end

  describe "concurrency_safe? resolution" do
    test "a declared-safe tool is parallel; everything else is exclusive" do
      assert Scheduler.concurrency_mode(tool("t", Safe), %{}) == :parallel

      for module <- [NoDeclaration, Raising, Throwing, Exiting, Truthy, NotEvenAModule, nil] do
        assert Scheduler.concurrency_mode(tool("t", module), %{}) == :exclusive,
               "expected #{inspect(module)} to be treated as exclusive"
      end
    end

    test "the predicate sees the call's arguments" do
      assert Scheduler.concurrency_mode(tool("t", PerArgs), %{"safe" => true}) == :parallel
      assert Scheduler.concurrency_mode(tool("t", PerArgs), %{"safe" => false}) == :exclusive
      assert Scheduler.concurrency_mode(tool("t", PerArgs), %{}) == :exclusive
    end

    test "the predicate sees the same normalized arguments the tool receives" do
      test_pid = self()

      dispatch = fn _tool, args, _run_ctx ->
        send(test_pid, {:args, args})
        {:ok, :done}
      end

      sched = start_scheduler(dispatch: dispatch, max_parallel: 4)

      # Atom-keyed input: the predicate would see `%{}` and refuse if it were
      # classified on the raw term instead of the dispatched snapshot.
      assert {:ok, :done} = Scheduler.call(sched, tool("t", PerArgs), %{safe: true}, nil)
      assert_receive {:args, %{"safe" => true}}

      assert [%{mode: :parallel}] = Enum.map(tool_call_events(sched), & &1.data)
    end

    test "a tool with no declaration is scheduled exclusively, not merely classified so" do
      inflight = new_inflight()
      sched = start_scheduler(dispatch: counting_dispatch(inflight, 40), max_parallel: 4)

      tickets = for i <- 1..3, do: submit!(sched, tool("t#{i}", NoDeclaration), %{})
      Enum.each(tickets, fn ticket -> assert {:ok, :done} = Scheduler.await(sched, ticket) end)

      assert observed_max(inflight) == 1
    end

    test "a raising predicate is scheduled exclusively and does not fail the call" do
      inflight = new_inflight()
      sched = start_scheduler(dispatch: counting_dispatch(inflight, 40), max_parallel: 4)

      tickets = for i <- 1..3, do: submit!(sched, tool("t#{i}", Raising), %{})
      Enum.each(tickets, fn ticket -> assert {:ok, :done} = Scheduler.await(sched, ticket) end)

      assert observed_max(inflight) == 1
    end
  end

  describe "argument snapshots" do
    test "a tool that mutates its arguments cannot desync the audit record" do
      test_pid = self()
      counter = :counters.new(1, [])

      # A tool that really does mutate: it rewrites the arguments it was handed —
      # the shape an approval `{:edit, args}` decision or a pre-tool hook
      # produces below the scheduler — and mutates shared state on the way
      # through. Neither may reach back into the audit record.
      dispatch = fn _tool, args, _run_ctx ->
        :counters.add(counter, 1, 1)

        edited =
          args
          |> Map.put("path", "/etc/shadow")
          |> Map.put("calls", :counters.get(counter, 1))

        send(test_pid, {:dispatched, args, edited})
        {:ok, edited}
      end

      sched = start_scheduler(dispatch: dispatch, call_id: "outer")

      assert {:ok, %{"path" => "/etc/shadow"}} =
               Scheduler.call(sched, tool("write"), %{"path" => "/tmp/ok", "calls" => 0}, nil)

      assert_receive {:dispatched, dispatched, edited}
      assert dispatched == %{"path" => "/tmp/ok", "calls" => 0}
      assert edited != dispatched

      # The audit record is what was dispatched, not what the tool made of it
      # and not what it returned.
      assert [event] = tool_call_events(sched)
      assert event.data.arguments == dispatched
      refute event.data.arguments["path"] == "/etc/shadow"

      # And the record is per-submission, not one shared or stale term: a second
      # call — after the mutation really happened — logs its own arguments.
      assert {:ok, _} =
               Scheduler.call(sched, tool("write"), %{"path" => "/tmp/two", "calls" => 0}, nil)

      assert Enum.map(tool_call_events(sched), & &1.data.arguments["path"]) ==
               ["/tmp/ok", "/tmp/two"]

      assert :counters.get(counter, 1) == 2
    end

    # This is also the proof that materialization is EAGER: the handle is already
    # a string by the time the tool sees it, so the snapshot cannot have been
    # deferred to log time.
    test "a live BEAM handle never reaches the tool or the log" do
      test_pid = self()

      dispatch = fn _tool, args, _run_ctx ->
        send(test_pid, {:dispatched, args})
        {:ok, :done}
      end

      sched = start_scheduler(dispatch: dispatch)
      args = %{"pid" => self(), "fun" => fn -> :boom end, :atom_key => :value, "n" => [1, 2]}

      assert {:ok, :done} = Scheduler.call(sched, tool("t"), args, nil)
      assert_receive {:dispatched, dispatched}

      assert dispatched["pid"] =~ "#PID<"
      assert dispatched["fun"] =~ "#Function<"
      assert dispatched["atom_key"] == "value"
      assert dispatched["n"] == [1, 2]

      # The event was appended, not dropped: an unserializable payload would
      # have been refused by Nous.Session.Log.
      assert [event] = tool_call_events(sched)
      assert event.data.arguments == dispatched
    end
  end

  describe "session events" do
    test "each sub-dispatch appears exactly once and messages are unchanged" do
      ctx =
        Context.new()
        |> Context.add_message(Nous.Message.new!(%{role: :user, content: "write a program"}))

      sched = start_scheduler(context: ctx, call_id: "call_42", max_parallel: 4)

      tickets = for i <- 1..5, do: submit!(sched, tool("t#{i}"), %{"i" => i})
      Enum.each(tickets, fn ticket -> assert {:ok, :done} = Scheduler.await(sched, ticket) end)

      out = Scheduler.context(sched)
      events = tool_call_events(sched)

      assert length(events) == 5
      assert Enum.map(events, & &1.data.name) == ["t1", "t2", "t3", "t4", "t5"]
      assert Enum.map(events, & &1.data.seq) == [0, 1, 2, 3, 4]
      assert Enum.map(events, & &1.data.arguments) == for(i <- 1..5, do: %{"i" => i})

      assert Enum.map(events, & &1.data.id) == [
               "call_42:code:0",
               "call_42:code:1",
               "call_42:code:2",
               "call_42:code:3",
               "call_42:code:4"
             ]

      # The whole point: bookkeeping events project to no message.
      assert out.messages == ctx.messages
      assert Enum.map(out.messages, & &1.content) == ["write a program"]
      assert Enum.count(Log.events(out.log), &Event.surface?/1) == 1
    end

    test "a failed sub-dispatch is still logged exactly once" do
      sched = start_scheduler(dispatch: fn _t, _a, _c -> {:error, "no"} end)

      assert {:error, _} = Scheduler.call(sched, tool("boom"), %{}, nil)

      assert [event] = tool_call_events(sched)
      assert event.data.name == "boom"
      assert event.data.mode == :parallel
    end

    test "without a call_id the correlation id still identifies the sub-call" do
      sched = start_scheduler()

      assert {:ok, :done} = Scheduler.call(sched, tool("t"), %{}, nil)
      assert [%{data: %{id: "code:0"}}] = tool_call_events(sched)
    end
  end

  describe "failed sub-calls" do
    test "surface the tool name and message and nothing else" do
      sched = start_scheduler(dispatch: fn _t, _a, _c -> {:error, "disk is full"} end)

      assert {:error, error} = Scheduler.call(sched, tool("write_file"), %{}, nil)
      assert error == %{"tool" => "write_file", "message" => "disk is full"}
      assert_only_name_and_message(error)
    end

    test "a raise surfaces its message, never its stacktrace" do
      sched = start_scheduler(dispatch: fn _t, _a, _c -> raise "kaboom" end)

      assert {:error, error} = Scheduler.call(sched, tool("explode"), %{}, nil)
      assert error == %{"tool" => "explode", "message" => "kaboom"}
      assert_only_name_and_message(error)
      refute error["message"] =~ "scheduler"
      refute error["message"] =~ "test/nous"
    end

    test "an exception struct's internals never reach the program" do
      reason = %Nous.Errors.ToolError{
        message: "the tool declined",
        tool_name: "query",
        attempt: 3,
        original_error: %RuntimeError{message: "PGPASSWORD=hunter2"}
      }

      sched = start_scheduler(dispatch: fn _t, _a, _c -> {:error, reason} end)

      assert {:error, error} = Scheduler.call(sched, tool("query"), %{}, nil)
      assert error == %{"tool" => "query", "message" => "the tool declined"}
      assert_only_name_and_message(error)
      refute inspect(error) =~ "hunter2"
      refute inspect(error) =~ "ToolError"
      refute inspect(error) =~ "original_error"
      refute inspect(error) =~ "attempt"
    end

    test "a non-exception internal struct is opaque to the program" do
      reason = %Internal{secret: "PGPASSWORD=hunter2", stacktrace: [{Foo, :bar, 1, []}]}
      sched = start_scheduler(dispatch: fn _t, _a, _c -> {:error, reason} end)

      assert {:error, error} = Scheduler.call(sched, tool("query"), %{}, nil)
      assert error == %{"tool" => "query", "message" => "tool call failed"}
      assert_only_name_and_message(error)
      refute inspect(error) =~ "hunter2"
      refute inspect(error) =~ "Internal"
      refute inspect(error) =~ "stacktrace"
    end

    test "an internal error tuple is opaque to the program" do
      reason = {:http, 500, %{body: "PGPASSWORD=hunter2"}}
      sched = start_scheduler(dispatch: fn _t, _a, _c -> {:error, reason} end)

      assert {:error, error} = Scheduler.call(sched, tool("fetch"), %{}, nil)
      assert error == %{"tool" => "fetch", "message" => "tool call failed"}
      refute inspect(error) =~ "hunter2"
    end

    test "an over-long message is clamped rather than handed to the program whole" do
      sched =
        start_scheduler(dispatch: fn _t, _a, _c -> {:error, String.duplicate("x", 5_000)} end)

      assert {:error, error} = Scheduler.call(sched, tool("chatty"), %{}, nil)
      assert String.length(error["message"]) < 5_000
      assert String.ends_with?(error["message"], "… (truncated)")
    end

    test "a killed sub-call fails its own call and leaves the lane usable" do
      sched =
        start_scheduler(
          dispatch: fn tool, _args, _run_ctx ->
            if tool.name == "suicide", do: Process.exit(self(), :kill)
            {:ok, :survived}
          end
        )

      assert {:error, error} = Scheduler.call(sched, tool("suicide"), %{}, nil)
      assert error == %{"tool" => "suicide", "message" => "tool call did not complete"}
      assert_only_name_and_message(error)

      # The lane survived a task dying under it, and the cursor advanced.
      assert {:ok, :survived} = Scheduler.call(sched, tool("after"), %{}, nil)
      assert :sys.get_state(sched).cursor == 2
    end

    test "a dispatch that breaks its own contract is opaque, not passed through" do
      sched = start_scheduler(dispatch: fn _t, _a, _c -> "PGPASSWORD=hunter2" end)

      assert {:error, error} = Scheduler.call(sched, tool("weird"), %{}, nil)
      assert error == %{"tool" => "weird", "message" => "tool call failed"}
    end
  end

  describe "caller chain" do
    test "sub-call tasks inherit the starting process's $callers" do
      test_pid = self()
      sched = start_scheduler(dispatch: fn _t, _a, _c -> {:ok, Process.get(:"$callers")} end)

      assert {:ok, callers} = Scheduler.call(sched, tool("t"), %{}, nil)
      assert test_pid in callers
      assert sched in callers
    end
  end

  describe "the dispatch seam" do
    test "dispatch_fun/1 is the 3-arity function the transport hands to bindings" do
      test_pid = self()

      sched =
        start_scheduler(
          dispatch: fn tool, args, run_ctx ->
            send(test_pid, {:dispatched, tool.name, args, run_ctx})
            {:ok, "ran"}
          end
        )

      fun = Scheduler.dispatch_fun(sched)
      assert is_function(fun, 3)
      assert {:ok, "ran"} = fun.(tool("search"), %{"q" => "elixir"}, :the_run_ctx)
      assert_receive {:dispatched, "search", %{"q" => "elixir"}, :the_run_ctx}
    end

    test "run_ctx is threaded per call, not captured once" do
      test_pid = self()

      sched =
        start_scheduler(
          dispatch: fn _tool, _args, run_ctx ->
            send(test_pid, {:run_ctx, run_ctx})
            {:ok, :done}
          end
        )

      assert {:ok, :done} = Scheduler.call(sched, tool("t"), %{}, :first)
      assert {:ok, :done} = Scheduler.call(sched, tool("t"), %{}, :second)
      assert_receive {:run_ctx, :first}
      assert_receive {:run_ctx, :second}
    end
  end

  describe "teardown" do
    test "stop/2 releases queued and in-flight callers with an error, not an exit" do
      test_pid = self()

      dispatch = fn tool, _args, _run_ctx ->
        send(test_pid, {:started, tool.name})

        receive do
          :never -> {:ok, :unreachable}
        end
      end

      sched = start_scheduler(dispatch: dispatch, max_parallel: 1)

      running = submit!(sched, tool("running"), %{})
      queued = submit!(sched, tool("queued"), %{})

      assert_receive {:started, "running"}, 1_000
      refute_received {:started, "queued"}

      :ok = Scheduler.stop(sched)

      assert {:error, %{"tool" => "running", "message" => message}} =
               Scheduler.await(sched, running)

      assert message =~ "code run is over"

      assert {:error, %{"tool" => "queued", "message" => ^message}} =
               Scheduler.await(sched, queued)
    end

    test "submitting to a dead scheduler is an error, not an exit" do
      sched = start_scheduler()
      :ok = Scheduler.stop(sched)

      assert {:error, %{"tool" => "t", "message" => message}} =
               Scheduler.submit(sched, tool("t"), %{}, nil)

      assert message =~ "code run is over"
      assert :ok = Scheduler.stop(sched)
    end

    test "await returns an error when the lane dies mid-call" do
      # Bounded rather than :infinity so a killed lane leaves nothing sleeping
      # for the rest of the suite.
      sched = start_scheduler(dispatch: fn _t, _a, _c -> Process.sleep(1_000) end)
      Process.unlink(sched)

      ticket = submit!(sched, tool("hangs"), %{})
      Process.exit(sched, :kill)

      assert {:error, %{"tool" => "hangs"}} = Scheduler.await(sched, ticket, 1_000)
    end
  end

  describe "configuration" do
    test "rejects a missing or malformed dispatch as seam misuse" do
      assert {:error, {:contract, message}} = Scheduler.start_link([])
      assert message =~ ":dispatch"

      assert {:error, {:contract, _}} = Scheduler.start_link(dispatch: fn -> :ok end)
    end

    test "rejects a non-positive max_parallel" do
      dispatch = fn _t, _a, _c -> {:ok, :done} end

      assert {:error, {:contract, message}} =
               Scheduler.start_link(dispatch: dispatch, max_parallel: 0)

      assert message =~ ":max_parallel"

      assert {:error, {:contract, _}} =
               Scheduler.start_link(dispatch: dispatch, max_parallel: :infinity)
    end

    test "rejects a context that is not a Nous.Agent.Context" do
      dispatch = fn _t, _a, _c -> {:ok, :done} end

      assert {:error, {:contract, message}} =
               Scheduler.start_link(dispatch: dispatch, context: %{})

      assert message =~ ":context"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_scheduler(opts \\ []) do
    opts = Keyword.put_new(opts, :dispatch, fn _tool, _args, _run_ctx -> {:ok, :done} end)
    assert {:ok, sched} = Scheduler.start_link(opts)
    sched
  end

  defp tool(name, module \\ Safe) do
    %Tool{name: name, function: fn _ctx, _args -> :ok end, module: module}
  end

  defp submit!(sched, tool, args, run_ctx \\ nil) do
    assert {:ok, ticket} = Scheduler.submit(sched, tool, args, run_ctx)
    ticket
  end

  # In-flight counter with a running maximum, the technique from
  # test/nous/agent_runner_parallel_tools_test.exs: wall-clock windows are the
  # wrong instrument for proving concurrency on shared CI hardware, so record the
  # maximum and assert it exactly.
  defp new_inflight, do: :atomics.new(2, signed: false)

  defp counting_dispatch(inflight, sleep_ms) do
    fn _tool, _args, _run_ctx ->
      record_max(inflight, :atomics.add_get(inflight, 1, 1))
      Process.sleep(sleep_ms)
      :atomics.sub(inflight, 1, 1)
      {:ok, :done}
    end
  end

  defp record_max(inflight, current) do
    observed = :atomics.get(inflight, 2)

    if current > observed do
      case :atomics.compare_exchange(inflight, 2, observed, current) do
        :ok -> :ok
        _raced -> record_max(inflight, current)
      end
    else
      :ok
    end
  end

  defp observed_max(inflight), do: :atomics.get(inflight, 2)

  # Mailbox order of the lane's commit deliveries, mapped back to tool names.
  defp commit_order(tickets) do
    names = Map.new(tickets)

    Enum.map(tickets, fn _ ->
      receive do
        {:sub_call, ref, _outcome} -> Map.fetch!(names, ref)
      after
        5_000 -> flunk("a sub-call never committed")
      end
    end)
  end

  defp finish_order(count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:finished, name} -> name
      after
        5_000 -> flunk("a sub-call never finished")
      end
    end)
  end

  defp send_release(sched, name) do
    for {_ref, {_entry, pid}} <- :sys.get_state(sched).inflight, do: send(pid, {:release, name})
  end

  defp tool_call_events(sched) do
    sched
    |> Scheduler.context()
    |> Map.fetch!(:log)
    |> Log.events()
    |> Enum.filter(&(&1.type == :tool_call))
  end

  defp assert_only_name_and_message(error) do
    refute is_struct(error)
    assert Enum.sort(Map.keys(error)) == ["message", "tool"]
    assert Enum.all?(Map.values(error), &is_binary/1)
  end
end

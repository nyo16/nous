defmodule Nous.Tools.RunCodeTest do
  # Sync: the "no provider configured" and timeout tests read/write
  # application-wide code-runtime settings.
  use ExUnit.Case, async: false

  alias Nous.CodeRuntime.{Failure, Request, Result}
  alias Nous.Tool.ContextUpdate
  alias Nous.{Permissions, RunContext, Tool, ToolExecutor}
  alias Nous.Tools.RunCode

  @sink :run_code_test_sink

  # A provider driven entirely by its config, so each test states the substrate
  # behaviour it is about:
  #
  #   result: %Result{}  — deliver this
  #   result: :never     — accept the run and never answer (deadline path)
  #   result: fun        — run `fun.(binding.functions)` the way a real program
  #                        reaches Elixir, then deliver (or not) whatever it
  #                        returns. This is the ONLY window in which a binding is
  #                        live: `run_code` starts the sub-call lane for the run
  #                        and stops it on the way out, so a binding called after
  #                        `run/3` returned is a call made after the program is
  #                        over.
  #   start: {:error, _} — refuse the request at the seam
  #   start: :garbage    — return something the seam does not allow
  defmodule StubProvider do
    @moduledoc false
    @behaviour Nous.CodeRuntime

    @impl true
    def language(_config), do: "javascript"

    @impl true
    def isolation(_config), do: "none — in-process test double"

    @impl true
    def start_run(%Request{} = request, config) do
      notify(config, {:started, request})

      case Keyword.get(config, :start, :ok) do
        :ok -> deliver(request, Keyword.get(config, :result, Result.ok("default")))
        other -> other
      end
    end

    @impl true
    def cancel(ref, reason) do
      if pid = Process.whereis(:run_code_test_sink) do
        send(pid, {:cancelled, ref, reason})
      end

      :ok
    end

    defp deliver(_request, :never), do: {:ok, make_ref()}

    defp deliver(request, program) when is_function(program, 1) do
      [binding] = request.bindings
      deliver(request, program.(binding.functions))
    end

    # A program that ran, made sub-calls, and then had its request refused.
    defp deliver(_request, {:error, _reason} = refusal), do: refusal

    defp deliver(request, %Result{} = result) do
      ref = make_ref()
      send(request.owner, {:code_run, ref, result})
      {:ok, ref}
    end

    defp notify(config, message) do
      case Keyword.get(config, :notify) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  # `concurrency_safe?/1` is read off `tool.module`, so a tool has to be backed
  # by a real, loaded module to be scheduled in parallel at all — the lane is
  # exclusive-by-default and would otherwise show a maximum of 1.
  defmodule Safe do
    @moduledoc false
    def concurrency_safe?(_args), do: true
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:nous, :code_runtime)
      Application.delete_env(:nous, :code_run_timeout_ms)
    end)

    {:ok, ctx: RunContext.new(%{}, approval_gated?: true)}
  end

  defp args(overrides \\ %{}) do
    Map.merge(%{"code" => "return 1;", "description" => "add one"}, overrides)
  end

  defp tool(name, fun, module \\ nil) do
    %Tool{
      name: name,
      description: "The #{name} tool.",
      function: fun,
      module: module,
      takes_ctx: true,
      timeout: nil,
      parameters: %{"type" => "object", "properties" => %{}, "required" => []}
    }
  end

  describe "the description is not decoration" do
    test "an empty description is rejected before anything runs", %{ctx: ctx} do
      runtime = {StubProvider, notify: self()}

      assert {:error, message} =
               RunCode.run(ctx, args(%{"description" => ""}), runtime: runtime)

      assert message =~ "non-empty `description`"
      assert message =~ "audit log"
      refute_received {:started, _request}
    end

    test "a whitespace-only description is rejected too", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, args(%{"description" => "   \n\t"}),
                 runtime: {StubProvider, notify: self()}
               )

      assert message =~ "non-empty `description`"
      refute_received {:started, _request}
    end

    test "a missing description is rejected", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, %{"code" => "return 1;"}, runtime: {StubProvider, []})

      assert message =~ "`description`"
    end

    test "a missing or non-string program is rejected", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, %{"description" => "d"}, runtime: {StubProvider, []})

      assert message =~ "`code` parameter"

      assert {:error, _} =
               RunCode.run(ctx, args(%{"code" => 42}), runtime: {StubProvider, []})
    end

    test "the schema requires both parameters, so the executor rejects them too", %{ctx: ctx} do
      run_code = Tool.from_module(RunCode)

      assert {:error, error} = ToolExecutor.execute(run_code, %{"code" => "x"}, ctx)
      assert Exception.message(error) =~ "description"
    end
  end

  describe "with no provider configured" do
    test "it returns a clear, actionable error and does not raise", %{ctx: ctx} do
      Application.delete_env(:nous, :code_runtime)

      assert {:error, message} = RunCode.execute(ctx, args())

      assert message =~ "no code runtime is configured"
      assert message =~ "config :nous, :code_runtime"
      assert message =~ "Nous.CodeRuntime"
    end

    test "a misconfigured provider is named rather than crashing", %{ctx: ctx} do
      Application.put_env(:nous, :code_runtime, Enum)

      assert {:error, message} = RunCode.execute(ctx, args())
      assert message =~ "does not implement Nous.CodeRuntime"
    end

    test "the configured provider is used when execute/2 gets no opts", %{ctx: ctx} do
      Application.put_env(:nous, :code_runtime, {StubProvider, result: Result.ok("via config")})

      assert {:ok, %{result: "via config"}} = RunCode.execute(ctx, args())
    end
  end

  describe "results" do
    test "a successful run returns logs and the value", %{ctx: ctx} do
      result = Result.ok(%{"count" => 3}, ["step 1", "step 2"])

      assert {:ok, output} = RunCode.run(ctx, args(), runtime: {StubProvider, result: result})
      assert output == %{logs: ["step 1", "step 2"], result: %{"count" => 3}}
    end

    test "a failed run is data, not a tool error, and keeps the logs" do
      ctx = RunContext.new(%{})
      result = Result.failed(:exception, "ReferenceError: x is not defined", ["got this far"])

      assert {:ok, output} = RunCode.run(ctx, args(), runtime: {StubProvider, result: result})

      assert output == %{
               logs: ["got this far"],
               error: %{kind: "exception", message: "ReferenceError: x is not defined"}
             }
    end

    test "every failure kind survives the round trip", %{ctx: ctx} do
      for kind <- Failure.kinds() do
        result = Result.failed(kind, "the #{kind} case")

        assert {:ok, %{error: %{kind: rendered}}} =
                 RunCode.run(ctx, args(), runtime: {StubProvider, result: result})

        assert rendered == Atom.to_string(kind)
      end
    end

    test "a run that never answers is cancelled and reported as a timeout", %{ctx: ctx} do
      Process.register(self(), @sink)
      Application.put_env(:nous, :code_run_timeout_ms, 50)

      assert {:ok, output} = RunCode.run(ctx, args(), runtime: {StubProvider, result: :never})

      assert %{logs: [], error: %{kind: "timeout", message: message}} = output
      assert message =~ "50ms"

      # Giving up on the receive is not the same as stopping the work.
      assert_received {:cancelled, _ref, :timeout}
    end

    test "a seam refusal is a tool error, because nothing ran", %{ctx: ctx} do
      runtime = {StubProvider, start: {:error, {:contract, "disposed runtime"}}}

      assert {:error, message} = RunCode.run(ctx, args(), runtime: runtime)
      assert message =~ "the code runtime refused the request: disposed runtime"
    end

    test "a provider that breaks the contract is reported, not obeyed", %{ctx: ctx} do
      assert {:error, message} =
               RunCode.run(ctx, args(), runtime: {StubProvider, start: :whatever})

      assert message =~ "returned :whatever from start_run/2"
    end

    test "an invalid :runtime option is refused", %{ctx: ctx} do
      assert {:error, message} = RunCode.run(ctx, args(), runtime: "not a provider")
      assert message =~ "invalid :runtime option"
    end
  end

  describe "the request handed to the provider" do
    test "carries the program, this process as owner, and permission-derived bindings", %{
      ctx: ctx
    } do
      test_pid = self()

      tools = [
        tool("granted", fn _ctx, _args -> {:ok, "granted ran"} end),
        tool("denied", fn _ctx, _args -> {:ok, "denied ran"} end)
      ]

      policy = Permissions.build_policy(deny: ["denied"])

      # The bindings are exercised INSIDE the run, because that is the only time
      # they are live. This block used to run after `run/3` returned, which meant
      # it would have passed just as happily against a run that never started.
      program = fn functions ->
        send(test_pid, {:binding_names, Enum.sort(Map.keys(functions))})
        send(test_pid, {:granted, functions["granted"].(%{})})
        send(test_pid, {:denied, functions["denied"].(%{})})
        Result.ok("done")
      end

      assert {:ok, _output, _update} =
               RunCode.run(ctx, args(%{"code" => "program text"}),
                 runtime: {StubProvider, notify: test_pid, result: program},
                 tools: tools,
                 policy: policy
               )

      assert_received {:started, %Request{} = request}
      assert request.program == "program text"
      assert request.owner == self()

      assert_received {:binding_names, ["denied", "granted"]}
      assert_received {:granted, {:ok, "granted ran"}}
      assert_received {:denied, {:error, %{"tool" => "denied"}}}
    end

    test "a run with no tools still gets a binding, just an empty one", %{ctx: ctx} do
      assert {:ok, _output} =
               RunCode.run(ctx, args(), runtime: {StubProvider, notify: self()})

      assert_received {:started, %Request{bindings: [binding]}}
      assert binding.functions == %{}
    end

    test "the :dispatch option replaces what the lane calls, not the lane", %{ctx: ctx} do
      test_pid = self()
      tools = [tool("alpha", fn _ctx, _args -> {:ok, :unused} end)]

      dispatch = fn tool, _args, _ctx ->
        send(test_pid, {:dispatched, tool.name})
        {:ok, "scheduled"}
      end

      program = fn functions ->
        send(test_pid, {:returned, functions["alpha"].(%{})})
        Result.ok("done")
      end

      assert {:ok, _output, update} =
               RunCode.run(ctx, args(),
                 runtime: {StubProvider, notify: test_pid, result: program},
                 tools: tools,
                 dispatch: dispatch
               )

      assert_received {:dispatched, "alpha"}
      assert_received {:returned, {:ok, "scheduled"}}

      # The supplied dispatch ran the call and the lane still audited it. An
      # implementation that handed `:dispatch` straight to the bindings, skipping
      # the scheduler, would produce no event here.
      assert Enum.map(ContextUpdate.log_events(update), fn {_type, data} -> data.name end) ==
               ["alpha"]
    end
  end

  describe "sub-calls go through the run's scheduler" do
    test "each sub-call becomes one :log_event operation, in submission order", %{ctx: ctx} do
      tools = [
        tool("alpha", fn _ctx, _args -> {:ok, "a"} end, Safe),
        tool("beta", fn _ctx, _args -> {:ok, "b"} end, Safe)
      ]

      # Six calls over two tools, with repeats, so "submission order" is
      # distinguishable from "sorted", "deduplicated" and "reversed".
      order = ["beta", "alpha", "beta", "beta", "alpha", "beta"]

      program = fn functions ->
        Result.ok(Enum.map(order, fn name -> functions[name].(%{"n" => name}) end))
      end

      assert {:ok, output, %ContextUpdate{} = update} =
               RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)

      assert output.result ==
               [{:ok, "b"}, {:ok, "a"}, {:ok, "b"}, {:ok, "b"}, {:ok, "a"}, {:ok, "b"}]

      events = ContextUpdate.log_events(update)

      # Counted, not merely non-empty: one event per sub-call, nothing dropped
      # and nothing logged twice.
      assert length(events) == 6
      assert Enum.map(events, fn {type, _data} -> type end) == List.duplicate(:tool_call, 6)
      assert Enum.map(events, fn {_type, data} -> data.name end) == order
      assert Enum.map(events, fn {_type, data} -> data.seq end) == [0, 1, 2, 3, 4, 5]

      assert Enum.map(events, fn {_type, data} -> data.arguments end) ==
               for(n <- order, do: %{"n" => n})

      # Distinct correlation ids, all naming the same parent run, so two
      # run_code calls in one turn cannot collide in the audit log.
      ids = Enum.map(events, fn {_type, data} -> data.id end)
      assert length(Enum.uniq(ids)) == 6
      assert Enum.all?(ids, &String.starts_with?(&1, "run_code-"))

      # Session events only. A run_code update must not smuggle deps writes into
      # the runner: sub-call deps updates are dropped by design (see
      # `Nous.CodeMode.direct_dispatch/3`).
      assert Enum.all?(ContextUpdate.operations(update), &match?({:log_event, _, _}, &1))
    end

    test "a program that calls nothing yields no :log_event operations", %{ctx: ctx} do
      tools = [tool("alpha", fn _ctx, _args -> {:ok, "a"} end, Safe)]
      program = fn _functions -> Result.ok("touched nothing") end

      # A two-tuple, not a three-tuple carrying an empty update: an update with
      # no operations is noise on the library's busiest path.
      assert {:ok, output} =
               RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)

      assert output.result == "touched nothing"
    end

    test "a refusal after real sub-calls names the audit trail it is dropping", %{ctx: ctx} do
      tools = [tool("alpha", fn _ctx, _args -> {:ok, "a"} end, Safe)]

      program = fn functions ->
        functions["alpha"].(%{})
        {:error, {:contract, "disposed runtime"}}
      end

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, message} =
                   RunCode.run(ctx, args(),
                     runtime: {StubProvider, result: program},
                     tools: tools
                   )

          assert message =~ "the code runtime refused the request"
        end)

      # `{:error, _}` has no third slot to carry events in, so the drop is named
      # rather than silent.
      assert logs =~ "run_code failed after 1 sub-dispatch(es) (alpha)"
    end

    test "the scheduler is gone once a successful run returns", %{ctx: ctx} do
      tools = [reporting_tool("alpha", self())]
      program = fn functions -> Result.ok(functions["alpha"].(%{})) end

      assert {:ok, _output, _update} =
               RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)

      assert_received {:scheduler, sched}
      assert is_pid(sched)
      refute Process.alive?(sched)
    end

    test "an untrappable kill of the run's process takes the scheduler with it", %{ctx: ctx} do
      tools = [reporting_tool("alpha", self())]

      # `ToolExecutor` runs a tool that declares a `:timeout` inside a spawned
      # process and kills it with `Process.exit(pid, :kill)` on the deadline.
      # That is untrappable, so no `after` clause runs — the link `start_link`
      # made is the only thing between it and a leaked lane per timed-out turn.
      program = fn functions ->
        functions["alpha"].(%{})
        Process.sleep(:infinity)
      end

      runner =
        spawn(fn ->
          RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)
        end)

      assert_receive {:scheduler, sched}, 1_000
      assert Process.alive?(sched)

      Process.exit(runner, :kill)

      assert await_death(sched) == :dead
    end

    test "the scheduler is gone when the program fails, and its trail survives", %{ctx: ctx} do
      tools = [reporting_tool("alpha", self(), {:error, "disk is full"})]

      program = fn functions ->
        {:error, _} = functions["alpha"].(%{})
        Result.failed(:exception, "the program threw")
      end

      assert {:ok, %{error: %{kind: "exception"}}, update} =
               RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)

      # A failed sub-call is still an audited sub-call.
      assert [{:tool_call, %{name: "alpha"}}] = ContextUpdate.log_events(update)

      assert_received {:scheduler, sched}
      refute Process.alive?(sched)
    end

    test "the scheduler is gone when the run times out", %{ctx: ctx} do
      Application.put_env(:nous, :code_run_timeout_ms, 50)
      tools = [reporting_tool("alpha", self())]

      # One real sub-call, then a provider that accepts the run and never
      # answers: the lane exists, and has work in its trail, when the deadline
      # fires.
      program = fn functions ->
        functions["alpha"].(%{})
        :never
      end

      assert {:ok, %{error: %{kind: "timeout"}}, update} =
               RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)

      assert [{:tool_call, %{name: "alpha"}}] = ContextUpdate.log_events(update)

      assert_received {:scheduler, sched}
      refute Process.alive?(sched)
    end

    test "the scheduler is gone when the provider raises mid-run", %{ctx: ctx} do
      tools = [reporting_tool("alpha", self())]

      program = fn functions ->
        functions["alpha"].(%{})
        raise "the substrate exploded"
      end

      # Nothing catches this, and nothing should: a raising provider is a bug in
      # the provider, not a program failure. The lane must still be gone — which
      # is why teardown is an `after` clause and not a line on the happy path.
      assert_raise RuntimeError, "the substrate exploded", fn ->
        RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: tools)
      end

      assert_received {:scheduler, sched}
      refute Process.alive?(sched)
    end

    test "exactly max_parallel sub-calls are in flight at once", %{ctx: ctx} do
      inflight = :atomics.new(2, signed: false)

      # The counting happens in the TOOL, so what is measured is the whole live
      # path — scheduler lane, CodeMode.direct_dispatch/3, ToolExecutor, tool —
      # rather than a stubbed dispatch standing in for it.
      alpha =
        tool(
          "alpha",
          fn _ctx, _args ->
            record_max(inflight, :atomics.add_get(inflight, 1, 1))
            Process.sleep(80)
            :atomics.sub(inflight, 1, 1)
            {:ok, :done}
          end,
          Safe
        )

      # A binding blocks until its call commits, so a program fans out the only
      # way a real one can: many callers, one lane.
      program = fn functions ->
        parent = self()

        for i <- 1..12 do
          spawn(fn -> send(parent, {:sub_call, i, functions["alpha"].(%{"i" => i})}) end)
        end

        outcomes =
          for _ <- 1..12 do
            receive do
              {:sub_call, _i, outcome} -> outcome
            after
              10_000 -> flunk("a sub-call never returned")
            end
          end

        Result.ok(outcomes)
      end

      assert {:ok, output, update} =
               RunCode.run(ctx, args(), runtime: {StubProvider, result: program}, tools: [alpha])

      assert output.result == List.duplicate({:ok, :done}, 12)
      assert length(ContextUpdate.log_events(update)) == 12

      # Exactly 10 — the scheduler's default ceiling reaching the live path.
      # `<= 10` would also pass for a serial lane, which shows 1.
      assert :atomics.get(inflight, 2) == 10
    end
  end

  describe "as a tool" do
    test "its schema declares both parameters as required" do
      %Tool{parameters: parameters} = Tool.from_module(RunCode)

      assert parameters["type"] == "object"
      assert Enum.sort(parameters["required"]) == ["code", "description"]
      assert parameters["properties"]["code"]["type"] == "string"
      assert parameters["properties"]["description"]["type"] == "string"
    end

    test "it is an execute-category tool, so a policy can gate it" do
      %Tool{} = run_code = Tool.from_module(RunCode)

      assert run_code.category == :execute
      assert Permissions.requires_approval?(Permissions.permissive_policy(), "run_code", :execute)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A tool that names the scheduler that dispatched it. The scheduler is the head
  # of a sub-call task's `$callers` chain, which `Nous.CodeMode.Scheduler`
  # documents and reinstalls precisely so process-scoped overrides survive a
  # sub-call. Reading it there, rather than off the run process's links, keeps
  # this helper independent of the very link the leak tests are about.
  defp reporting_tool(name, test_pid, result \\ {:ok, "a"}) do
    tool(
      name,
      fn _ctx, _args ->
        send(test_pid, {:scheduler, hd(Process.get(:"$callers"))})
        result
      end,
      Safe
    )
  end

  # An exit signal travelling a link is asynchronous, so poll instead of assuming
  # the peer is already gone.
  defp await_death(pid, attempts \\ 200) do
    cond do
      not Process.alive?(pid) -> :dead
      attempts == 0 -> flunk("#{inspect(pid)} outlived the process it was linked to")
      true -> Process.sleep(5) && await_death(pid, attempts - 1)
    end
  end

  # In-flight counter with a running maximum, the technique
  # test/nous/code_mode/scheduler_test.exs and
  # test/nous/agent_runner_parallel_tools_test.exs both use: a wall-clock window
  # is the wrong instrument for proving concurrency on shared hardware, so record
  # the maximum and assert it exactly.
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
end

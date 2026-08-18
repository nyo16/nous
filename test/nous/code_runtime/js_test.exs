defmodule Nous.CodeRuntime.JSTest do
  use ExUnit.Case, async: false

  alias Nous.CodeRuntime
  alias Nous.CodeRuntime.{Binding, Failure, Request, Result}
  alias Nous.CodeRuntime.JS

  @moduletag :code_runtime_js

  # tyrex is optional. Without it there is nothing to test rather than a wall of
  # failures, which is the same compile-time check `Nous.Application` uses to
  # decide whether to start this provider's supervision at all.
  if Code.ensure_loaded?(Tyrex) do
    defp tools do
      %{
        "add" => fn %{"a" => a, "b" => b} -> {:ok, a + b} end,
        "echo" => fn args -> {:ok, args} end,
        "slow" => fn args ->
          started = System.monotonic_time(:millisecond)
          Process.sleep(Map.get(args, "ms", 120))
          {:ok, %{"started" => started, "ended" => System.monotonic_time(:millisecond)}}
        end,
        "boom" => fn _ -> {:error, %{"tool" => "boom", "message" => "the tool said no"}} end,
        "leaky" => fn _ ->
          {:error, %{"tool" => "leaky", "message" => "failed", "secret" => "hunter2"}}
        end,
        "crasher" => fn _ -> raise "internal detail: hunter2" end
      }
    end

    defp config(overrides \\ []) do
      Keyword.merge([timeout_ms: 5_000, max_heap_mb: 128], overrides)
    end

    defp run(program, opts \\ []) do
      functions = Keyword.get(opts, :functions, tools())
      config = config(Keyword.get(opts, :config, []))

      binding = %Binding{global: "tools", functions: functions, error_class: "ToolError"}
      {:ok, request} = Request.new(program, [binding], self())
      {:ok, handle} = JS.start_run(request, config)

      case CodeRuntime.await(handle, Keyword.get(opts, :await, 30_000)) do
        {:ok, %Result{} = result} -> result
        other -> flunk("expected a result, got #{inspect(other)}")
      end
    end

    describe "generated source integrity" do
      test "a hostile tool name cannot break out of the generated JavaScript" do
        # Tool names are model-visible data spliced into generated source, so the
        # quote, backslash and newline below each close the string literal early if
        # the name is interpolated rather than encoded.
        #
        # U+2028/U+2029 are in the fixture but NOT what this test proves: ES2019
        # legalised both inside string literals, so V8 accepts them raw. The prelude
        # escapes them anyway (see its comment); this asserts only that carrying them
        # does no harm.
        hostile = "evil\u2028name\u2029with\"quote'and\\backslash\nnewline"

        result =
          run("return typeof tools[#{inspect(hostile)}];",
            functions: %{hostile => fn _ -> {:ok, "ran"} end}
          )

        # A broken escape is a syntax error, not a wrong answer, so reaching a value
        # at all is the property: the source parsed with that name inside it.
        assert result.error == nil
        assert result.value == "function"
      end

      test "a hostile tool name is callable by its exact name" do
        hostile = ~s|tool"with'quotes|

        result =
          run(~s|return await tools[#{inspect(hostile)}]({});|,
            functions: %{hostile => fn _ -> {:ok, "called"} end}
          )

        assert result.value == "called"
      end
    end

    describe "one round trip" do
      test "a program loops, calling a tool with each previous result" do
        result =
          run("""
            let total = 0;
            for (let i = 1; i <= 5; i++) total = await tools.add({a: total, b: i});
            return total;
          """)

        # 1+2+3+4+5 through five separate tool calls, one model round trip.
        assert result.value == 15
        assert result.error == nil
      end

      test "concurrent sub-calls genuinely overlap" do
        result =
          run("""
            const rs = await Promise.all([
              tools.slow({ms: 150}), tools.slow({ms: 150}), tools.slow({ms: 150})
            ]);
            return {
              starts: rs.map(r => r.started),
              ends: rs.map(r => r.ended)
            };
          """)

        %{"starts" => starts, "ends" => ends} = result.value

        # The overlap has to be proven, not inferred from wall clock: the first
        # call to finish did so after the last call had already started, which
        # is impossible if the bridge serialised them. A wall-clock assertion
        # would pass on a fast serial run and is the bug this excludes.
        assert Enum.min(ends) > Enum.max(starts)
      end

      test "a value the program returns survives as JSON" do
        result = run(~s|return {n: 1, s: "two", b: true, list: [1, 2], nested: {x: null}};|)

        assert result.value == %{
                 "n" => 1,
                 "s" => "two",
                 "b" => true,
                 "list" => [1, 2],
                 "nested" => %{"x" => nil}
               }
      end

      test "a program returning nothing yields nil rather than a missing key" do
        assert run("const x = 1;").value == nil
      end
    end

    describe "deadline" do
      test "a runaway loop is terminated, not merely abandoned" do
        started = System.monotonic_time(:millisecond)
        result = run("while (true) {}", config: [timeout_ms: 700])
        elapsed = System.monotonic_time(:millisecond) - started

        assert %Failure{kind: :timeout} = result.error

        # Bounded overshoot, and an upper bound is the whole point: a provider
        # that returned at the deadline while leaving the isolate spinning would
        # pass a lower-bound assertion.
        assert elapsed < 2_500, "took #{elapsed}ms to stop a runaway under a 700ms deadline"
      end

      test "the deadline covers time spent inside tool calls" do
        # The substrate's own eval timeout does NOT cover this: an allowlisted
        # bridge call runs inline on the runtime's message loop, so a program
        # looping over a slow tool suspends that deadline indefinitely. This is
        # the case that justifies holding the wall clock in a BEAM timer, and a
        # provider that delegated the deadline to the substrate would hang here
        # until the test's own await gave up.
        started = System.monotonic_time(:millisecond)
        result = run("while (true) { await tools.slow({ms: 50}); }", config: [timeout_ms: 900])
        elapsed = System.monotonic_time(:millisecond) - started

        assert %Failure{kind: :timeout} = result.error
        assert elapsed < 3_000, "the deadline did not cover tool time (#{elapsed}ms)"
      end

      test "terminated runs do not leak the runtime's OS thread" do
        # More runaways than this host has dirty CPU schedulers, all killed. If
        # termination abandoned the worker thread instead of reclaiming it, the
        # pool would be exhausted and the final run could not complete.
        for _ <- 1..(:erlang.system_info(:dirty_cpu_schedulers) + 2) do
          assert %Failure{kind: :timeout} =
                   run("while (true) {}", config: [timeout_ms: 150]).error
        end

        assert run("return 42;").value == 42
      end

      test "a program that only sleeps is still killed" do
        result =
          run("await new Promise(r => setTimeout(r, 60000)); return 1;",
            config: [timeout_ms: 600]
          )

        assert %Failure{kind: :timeout} = result.error
      end
    end

    describe "budgets" do
      test "a memory bomb ends the run and leaves the VM alive" do
        result =
          run("const a = []; while (true) a.push(new Array(1_000_000).fill(7));",
            config: [max_heap_mb: 64, timeout_ms: 20_000]
          )

        assert %Failure{kind: :abort, message: message} = result.error
        assert message =~ "memory"

        # The next run proves the BEAM and the provider both survived it.
        assert run("return 1 + 1;").value == 2
      end

      test "the output ledger bounds program output and keeps the fitting prefix" do
        result =
          run(
            "for (let i = 0; i < 400; i++) console.log('#{String.duplicate("x", 100)}'); return 'done';",
            config: [max_output_bytes: 2_000]
          )

        assert result.value == "done"
        assert List.last(result.logs) =~ "output truncated"

        # The prefix is retained rather than the tail: the first lines are the
        # ones that explain what the program was doing.
        assert hd(result.logs) == String.duplicate("x", 100)

        kept = result.logs |> Enum.reject(&(&1 =~ "output truncated")) |> Enum.map(&byte_size/1)
        assert Enum.sum(kept) <= 2_000
      end

      test "exceeding the output limit does not fail the program" do
        result =
          run("for (let i = 0; i < 200; i++) console.log('noise'); return 'finished anyway';",
            config: [max_output_bytes: 50]
          )

        assert result.value == "finished anyway"
        assert result.error == nil
      end

      test "invalid budgets are refused when the provider is configured" do
        assert {:error, {:contract, message}} = JS.validate(timeout_ms: 0)
        assert message =~ "timeout_ms"

        assert {:error, {:contract, _}} = JS.validate(max_heap_mb: -1)
        assert {:error, {:contract, _}} = JS.validate(max_output_bytes: "big")
        assert {:error, {:contract, _}} = JS.validate(poll_backoff_ms: [])
        assert {:error, {:contract, _}} = JS.validate(poll_backoff_ms: [0])
        assert {:error, {:contract, _}} = JS.validate(%{timeout_ms: 1})

        assert {:ok, budgets} = JS.validate([])
        assert budgets[:timeout_ms] == 30_000
        assert budgets[:permissions] == :none
      end
    end

    describe "logs" do
      test "every line a fast-finishing program emits is captured" do
        # A program that logs and returns immediately leaves lines in flight,
        # because logging is fire-and-forget. Asserting the exact count is what
        # catches a provider that reports the result before its output arrives -
        # measured at a fraction of 500 lines before the drain existed.
        result = run("for (let i = 0; i < 300; i++) console.log('line ' + i); return 'ok';")

        assert result.value == "ok"
        assert length(result.logs) == 300
        assert hd(result.logs) == "line 0"
        assert List.last(result.logs) == "line 299"
      end

      test "logs survive a killed run" do
        result =
          run(
            """
              console.log("before the hang");
              console.log("still before");
              while (true) {}
            """,
            config: [timeout_ms: 700]
          )

        assert %Failure{kind: :timeout} = result.error
        assert result.logs == ["before the hang", "still before"]
      end

      test "stderr is distinguishable from stdout" do
        result = run(~s|console.log("out"); console.error("err"); return 1;|)
        assert result.logs == ["out", "[stderr] err"]
      end

      test "non-string arguments are formatted rather than dropped" do
        result = run(~s|console.log("n", 1, {a: 1}, [1, 2], null); return 1;|)
        assert result.logs == [~s|n 1 {"a":1} [1,2] null|]
      end
    end

    describe "failures" do
      test "the program's own exception reaches the model in its own words" do
        result = run(~s|throw new Error("model bug");|)

        # `JSON.stringify(new Error(...))` is `{}`, so a provider that shipped
        # the thrown value raw would tell the model only that it failed.
        assert %Failure{kind: :exception, message: message} = result.error
        assert message =~ "model bug"
      end

      test "a thrown non-Error still produces a readable failure" do
        assert %Failure{kind: :exception, message: message} =
                 run(~s|throw "just a string";|).error

        assert message =~ "just a string"
      end

      test "a syntax error is a failure, not a crash" do
        assert %Failure{} = run("this is not javascript(((").error
      end

      test "a tool failure is catchable in the program's own idiom" do
        result =
          run("""
            try {
              await tools.boom({});
              return "no throw";
            } catch (e) {
              return { name: e.name, message: e.message, tool: e.tool, isToolError: e instanceof ToolError };
            }
          """)

        assert result.value == %{
                 "name" => "ToolError",
                 "message" => "the tool said no",
                 "tool" => "boom",
                 "isToolError" => true
               }
      end

      test "an uncaught tool failure fails the program with the tool's message" do
        assert %Failure{kind: :exception, message: message} = run("await tools.boom({});").error
        assert message =~ "the tool said no"
      end

      test "nothing beyond the tool name and message reaches the program" do
        result =
          run("""
            try { await tools.leaky({}); } catch (e) {
              return { keys: Object.keys(e), all: JSON.stringify(Object.getOwnPropertyNames(e).map(k => String(e[k]))) };
            }
          """)

        # A planted secret in the error payload must not be readable by
        # model-authored code, whichever way it enumerates the error.
        refute result.value["all"] =~ "hunter2"
        refute Enum.any?(result.logs, &(&1 =~ "hunter2"))
      end

      # A tool that raises SHOULD log loudly for the operator; capturing keeps
      # the suite's output readable without hiding that it happens.
      @tag :capture_log
      test "a crashing tool becomes a catchable failure, not a lost run" do
        result =
          run("""
            try { await tools.crasher({}); return "no throw"; }
            catch (e) { return e.message; }
          """)

        # The exception's own text carries the raised message, so the generic
        # wording is what must reach the guest.
        assert result.value == "tool call failed"
        refute result.value =~ "hunter2"
      end

      test "calling a tool the program was not given fails that call only" do
        result =
          run(
            """
              try { await tools.add({a: 1, b: 2}); } catch (e) { return "add failed"; }
              return "reached the end";
            """,
            functions: %{"echo" => fn args -> {:ok, args} end}
          )

        # `add` is absent from the bindings, so the prelude never declares it and
        # the call throws in the guest rather than hanging on a ticket that will
        # never be filled.
        assert result.value == "add failed"
      end
    end

    describe "isolation" do
      test "the Elixir gateway is unreachable from model-authored code" do
        result =
          run("""
            const attempt = async (f) => { try { return String(await f()); } catch (e) { return "blocked"; } };
            return {
              apply: typeof Tyrex?.apply,
              denoCore: typeof Deno?.core,
              bootstrap: typeof globalThis.__bootstrap,
              viaFunction: String(new Function("return typeof Deno?.core")()),
              ops: await attempt(() => import("ext:core/ops")),
              nodeFs: await attempt(() => import("node:fs")),
              restore: await attempt(async () => {
                Object.defineProperty(Tyrex, "apply", { value: () => 1 });
                return "REDEFINED";
              })
            };
          """)

        assert result.value == %{
                 "apply" => "undefined",
                 "denoCore" => "undefined",
                 "bootstrap" => "undefined",
                 "viaFunction" => "undefined",
                 "ops" => "blocked",
                 "nodeFs" => "blocked",
                 "restore" => "blocked"
               }
      end

      test "rebinding the gateway's global does not restore it" do
        result =
          run("""
            try { globalThis.Tyrex = { apply: () => "stolen" }; } catch (e) {}
            return { apply: typeof Tyrex?.apply, stolen: typeof globalThis.Tyrex.stolen };
          """)

        assert result.value == %{"apply" => "undefined", "stolen" => "undefined"}
      end

      test "the filesystem, network and environment are denied" do
        result =
          run("""
            const attempt = async (f) => { try { await f(); return "LEAKED"; } catch (e) { return e.name; } };
            return {
              read: await attempt(() => Deno.readTextFile("/etc/hosts")),
              write: await attempt(() => Deno.writeTextFile("/tmp/nous-escape", "x")),
              net: await attempt(() => fetch("http://127.0.0.1:1/")),
              env: await attempt(async () => Deno.env.get("PATH")),
              run: await attempt(async () => new Deno.Command("sh").output())
            };
          """)

        assert result.value == %{
                 "read" => "NotCapable",
                 "write" => "NotCapable",
                 "net" => "NotCapable",
                 "env" => "NotCapable",
                 "run" => "NotCapable"
               }

        refute File.exists?("/tmp/nous-escape")
      end

      test "the bridge exposes exactly one function to the guest" do
        # The allowlist IS the isolation boundary for Elixir access. Anything
        # added here is reachable by model-authored code with no further review.
        assert JS.Bridge.allowlist() == [{JS.Bridge, :call, 1}]
      end

      test "a bridge call with no run bound is refused rather than served" do
        assert %{"error" => %{"kind" => "substrate"}} =
                 JS.Bridge.call(%{"op" => "submit", "tool" => "add", "args" => %{}})
      end

      test "no state survives from one run to the next" do
        assert run(
                 "globalThis.LEAK = 'from the first run'; Array.prototype.push = null; return 1;"
               ).value ==
                 1

        result = run("return { leak: typeof globalThis.LEAK, push: typeof [].push };")
        assert result.value == %{"leak" => "undefined", "push" => "function"}
      end
    end

    describe "seam" do
      test "cancel stops a running program and reports it" do
        binding = %Binding{global: "tools", functions: tools(), error_class: "ToolError"}
        {:ok, request} = Request.new("while (true) {}", [binding], self())
        {:ok, {session, _} = handle} = JS.start_run(request, config(timeout_ms: 30_000))

        # Let it get going, so this is a cancellation of a live program rather
        # than a race against startup.
        Process.sleep(150)
        assert Process.alive?(session)
        ref = Process.monitor(session)
        :ok = JS.cancel(handle, :caller_gave_up)

        assert {:ok, %Result{error: %Failure{kind: :abort, message: message}}} =
                 CodeRuntime.await(handle, 10_000)

        assert message =~ "caller_gave_up"

        # The result is sent before the session finishes exiting, so the
        # contract is that it terminates - not that it is already gone the
        # instant the answer arrives. Asserting the latter is a race that
        # passes or fails on scheduling.
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      end

      test "the run reports through the handle start_run returned" do
        # `CodeRuntime.await/2` pins the ref in a selective receive. A session
        # that answered with any other term would leave every caller waiting out
        # its timeout while the run had in fact succeeded.
        binding = %Binding{global: "tools", functions: %{}, error_class: "ToolError"}
        {:ok, request} = Request.new("return 7;", [binding], self())
        {:ok, handle} = JS.start_run(request, config())

        assert_receive {:code_run, ^handle, %Result{value: 7}}, 10_000
      end

      test "seam misuse is a contract error, never a raise" do
        assert {:error, {:contract, message}} = JS.start_run(:not_a_request, config())
        assert message =~ "Request"
      end

      test "the session process does not outlive its run" do
        binding = %Binding{global: "tools", functions: %{}, error_class: "ToolError"}
        {:ok, request} = Request.new("return 1;", [binding], self())
        {:ok, {session, _} = handle} = JS.start_run(request, config())

        assert {:ok, %Result{value: 1}} = CodeRuntime.await(handle, 10_000)

        # One session per run, and a run per model turn: a session that lingered
        # would be a leak per turn, and it holds a V8 isolate.
        ref = Process.monitor(session)
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      end

      test "the provider describes itself without overclaiming" do
        assert JS.language([]) == "javascript"

        isolation = JS.isolation(config())
        assert isolation =~ "V8 isolate"
        assert isolation =~ "Not an OS sandbox"
      end

      test "concurrent runs do not see each other's tools or logs" do
        parent = self()

        tasks =
          for i <- 1..4 do
            Task.async(fn ->
              functions = %{"whoami" => fn _ -> {:ok, i} end}
              send(parent, {:started, i})

              run(
                """
                  const me = await tools.whoami({});
                  console.log("run " + me);
                  return me;
                """,
                functions: functions
              )
            end)
          end

        results = Task.await_many(tasks, 30_000)

        # Each run's binding closes over its own `i`; a shared runtime or a
        # registry keyed by anything the guest controls would cross them.
        assert Enum.map(results, & &1.value) |> Enum.sort() == [1, 2, 3, 4]

        for %Result{value: i, logs: logs} <- results do
          assert logs == ["run #{i}"]
        end
      end
    end
  end
end

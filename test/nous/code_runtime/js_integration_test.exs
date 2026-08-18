defmodule Nous.CodeRuntime.JSIntegrationTest do
  @moduledoc """
  Plan 04 end to end with nothing stubbed.

  The provider suite exercises `Nous.CodeRuntime.JS` directly and the `run_code`
  suite exercises the transport against a stub provider. Neither proves they
  compose, and the composition is where the interesting failures live: a real
  program, in a real isolate, dispatching real `%Nous.Tool{}`s through the real
  scheduler, with the sub-dispatches landing in a real session log.
  """

  use ExUnit.Case, async: false

  alias Nous.Agent.Context
  alias Nous.CodeMode
  alias Nous.Permissions
  alias Nous.RunContext
  alias Nous.Session.Log
  alias Nous.Tool
  alias Nous.Tool.ContextUpdate
  alias Nous.Tools.RunCode

  @moduletag :code_runtime_js

  if Code.ensure_loaded?(Tyrex) do
    setup do
      Application.put_env(
        :nous,
        :code_runtime,
        {Nous.CodeRuntime.JS, timeout_ms: 10_000, max_heap_mb: 128}
      )

      on_exit(fn ->
        Application.delete_env(:nous, :code_runtime)
        Application.delete_env(:nous, :code_run_timeout_ms)
      end)

      {:ok, ctx: RunContext.new(%{}, approval_gated?: true)}
    end

    defp tool(name, fun) do
      %Tool{
        name: name,
        description: "The #{name} tool.",
        function: fun,
        takes_ctx: true,
        timeout: nil,
        parameters: %{
          "type" => "object",
          "properties" => %{"n" => %{"type" => "integer"}},
          "required" => []
        }
      }
    end

    defp args(code) do
      %{"code" => code, "description" => "an integration program"}
    end

    test "a program drives real tools and reports what it computed", %{ctx: ctx} do
      tools = [
        tool("double", fn _ctx, %{"n" => n} -> {:ok, n * 2} end),
        tool("stringify", fn _ctx, %{"n" => n} -> {:ok, "n=#{n}"} end)
      ]

      program = """
        const doubled = [];
        for (const n of [1, 2, 3]) doubled.push(await tools.double({n}));
        console.log("doubled " + doubled.join(","));
        const labels = await Promise.all(doubled.map(n => tools.stringify({n})));
        return { doubled, labels };
      """

      assert {:ok, output, %ContextUpdate{} = update} =
               RunCode.run(ctx, args(program), tools: tools, policy: nil)

      assert output.result == %{
               "doubled" => [2, 4, 6],
               "labels" => ["n=2", "n=4", "n=6"]
             }

      assert output.logs == ["doubled 2,4,6"]

      # Six sub-calls: three sequential `double`s and three parallel
      # `stringify`s. Counting them is what proves the transport logged every
      # dispatch rather than the first or the last.
      events = ContextUpdate.log_events(update)
      assert length(events) == 6
      assert Enum.map(events, fn {_type, data} -> data.name end) |> Enum.sort() == ~w(
               double double double stringify stringify stringify
             )

      assert Enum.all?(events, fn {type, _data} -> type == :tool_call end)
    end

    test "sub-dispatches reach the session log and stay out of model history", %{ctx: ctx} do
      tools = [tool("double", fn _ctx, %{"n" => n} -> {:ok, n * 2} end)]

      assert {:ok, _output, update} =
               RunCode.run(ctx, args("return await tools.double({n: 21});"),
                 tools: tools,
                 policy: nil
               )

      before = Context.new(system_prompt: "you are helpful")
      after_ctx = ContextUpdate.apply(update, before)

      # The whole point of a bookkeeping event: the operator can audit that the
      # program called `double`, and the model's transcript is untouched by it.
      assert after_ctx.messages == before.messages

      logged =
        after_ctx.log
        |> Log.events()
        |> Enum.filter(&(&1.type == :tool_call))
        |> Enum.map(& &1.data.name)

      assert logged == ["double"]
    end

    test "a denied tool fails inside the program without stopping it", %{ctx: ctx} do
      tools = [
        tool("allowed", fn _ctx, _args -> {:ok, "ran"} end),
        tool("forbidden", fn _ctx, _args -> {:ok, "should never run"} end)
      ]

      policy = Permissions.build_policy(mode: :permissive, deny: ["forbidden"])

      program = """
        const out = { allowed: await tools.allowed({}) };
        try { out.forbidden = await tools.forbidden({}); }
        catch (e) { out.forbidden = "denied: " + e.message; }
        return out;
      """

      assert {:ok, output, update} =
               RunCode.run(ctx, args(program), tools: tools, policy: policy)

      assert output.result["allowed"] == "ran"
      assert output.result["forbidden"] =~ "denied"

      # A denied tool is a stub in the guest, so it never dispatches: the audit
      # trail must show the one call that really happened, not two.
      assert ContextUpdate.log_events(update) |> Enum.map(fn {_t, d} -> d.name end) == ["allowed"]
    end

    test "the program's own failure comes back readable, with its logs", %{ctx: ctx} do
      program = """
        console.log("about to fail");
        throw new Error("deliberate");
      """

      # No sub-calls, so no audit trail and deliberately no empty
      # `%ContextUpdate{}`: the two-tuple is the documented shape.
      assert {:ok, output} = RunCode.run(ctx, args(program), tools: [], policy: nil)

      assert output.logs == ["about to fail"]
      assert output.error.kind == "exception"
      assert output.error.message =~ "deliberate"
    end

    test "a runaway program is killed and reported through the tool", %{ctx: ctx} do
      Application.put_env(
        :nous,
        :code_runtime,
        {Nous.CodeRuntime.JS, timeout_ms: 700, max_heap_mb: 128}
      )

      assert {:ok, output} = RunCode.run(ctx, args("while (true) {}"), tools: [], policy: nil)

      assert output.error.kind == "timeout"
    end

    test "the SDK the model reads names the same tools the program can call", %{ctx: ctx} do
      tools = [
        tool("alpha", fn _ctx, _args -> {:ok, 1} end),
        tool("beta", fn _ctx, _args -> {:ok, 2} end)
      ]

      run_code = CodeMode.run_code_tool(tools, tools, [])
      sdk = run_code.description

      assert sdk =~ "alpha"
      assert sdk =~ "beta"

      # The declaration and the binding have to agree, or the model writes calls
      # that cannot resolve. Proving it by calling exactly what the SDK declares.
      assert {:ok, output, _update} =
               RunCode.run(
                 ctx,
                 args("return [await tools.alpha({}), await tools.beta({})];"),
                 tools: tools,
                 policy: nil
               )

      assert output.result == [1, 2]
    end

    describe "the approval gate survives the trip through a program" do
      test "an approval-required tool still consults the handler" do
        test_pid = self()

        ctx =
          RunContext.new(%{},
            approval_gated?: true,
            approval_handler: fn call ->
              send(test_pid, {:asked, call.name, call.arguments})
              :approve
            end
          )

        tools = [
          %Tool{
            tool("dangerous", fn _ctx, _args -> {:ok, "did the dangerous thing"} end)
            | requires_approval: true
          }
        ]

        assert {:ok, output, _update} =
                 RunCode.run(ctx, args(~s|return await tools.dangerous({n: 1});|),
                   tools: tools,
                   policy: nil
                 )

        assert output.result == "did the dangerous thing"

        # Code Mode must not be a way around the approval handler. The program is
        # a transport, not an authority: the handler sees the real tool name and
        # the real arguments, exactly as it would for a model-direct call.
        assert_receive {:asked, "dangerous", %{"n" => 1}}
      end

      test "a rejected sub-call fails inside the program and never runs" do
        test_pid = self()

        ctx =
          RunContext.new(%{},
            approval_gated?: true,
            approval_handler: fn _call ->
              send(test_pid, :consulted)
              :reject
            end
          )

        tools = [
          %Tool{
            tool("dangerous", fn _ctx, _args ->
              send(test_pid, :SHOULD_NOT_RUN)
              {:ok, "ran anyway"}
            end)
            | requires_approval: true
          }
        ]

        program = """
          try { await tools.dangerous({n: 1}); return "not rejected"; }
          catch (e) { return "rejected: " + e.message; }
        """

        assert {:ok, output, _update} =
                 RunCode.run(ctx, args(program), tools: tools, policy: nil)

        assert output.result =~ "rejected"
        assert_receive :consulted
        refute_receive :SHOULD_NOT_RUN, 200
      end

      test "with no handler, an approval-required tool is refused rather than run" do
        test_pid = self()

        # No `:approval_handler`, and the gate is what the runner would hand us.
        ctx = RunContext.new(%{}, approval_gated?: true)

        tools = [
          %Tool{
            tool("dangerous", fn _ctx, _args ->
              send(test_pid, :SHOULD_NOT_RUN)
              {:ok, "ran unattended"}
            end)
            | requires_approval: true
          }
        ]

        program = """
          try { await tools.dangerous({n: 1}); return "ran"; }
          catch (e) { return "refused"; }
        """

        assert {:ok, output, _update} =
                 RunCode.run(ctx, args(program), tools: tools, policy: nil)

        # Default-deny. Before the gate was reopened, inheriting the runner's
        # `approval_gated?: true` made this run the tool unattended - the exact
        # thing `requires_approval` exists to prevent.
        assert output.result == "refused"
        refute_receive :SHOULD_NOT_RUN, 200
      end
    end

    test "no runtime configured degrades rather than advertising a broken tool" do
      Application.delete_env(:nous, :code_runtime)

      tools = [tool("alpha", fn _ctx, _args -> {:ok, 1} end)]
      visible = CodeMode.visible_tools(:both, tools, tools, [])

      refute Enum.any?(visible, &(&1.name == CodeMode.run_code_name()))
    end
  end
end

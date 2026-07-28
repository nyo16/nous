defmodule Nous.ToolExecutorApprovalTest do
  use ExUnit.Case, async: true

  alias Nous.{Tool, ToolExecutor, RunContext}
  alias Nous.Agent.Context
  alias Nous.Plugins.HumanInTheLoop
  alias Nous.Workflow.{Node, State}
  alias Nous.Workflow.Engine.Executor

  import ExUnit.CaptureLog

  # These tests pin the structural half of AGENTS.md invariant 2: "tools
  # requiring approval are rejected without an :approval_handler". Enforcement
  # used to live only in Nous.AgentRunner, so Nous.LLM, Workflow :tool_step and
  # any direct ToolExecutor.execute/3 call reached Bash/FileWrite/FileEdit with
  # no gate at all. The gate now lives in ToolExecutor, which every path shares.

  # Records every invocation so a test can prove a tool did NOT run.
  defp probe_tool(opts) do
    test_pid = self()

    fun = fn _ctx, args ->
      send(test_pid, {:tool_ran, args})
      {:ok, "executed"}
    end

    Tool.from_function(
      fun,
      Keyword.merge(
        [name: "probe", description: "records invocations", parameters: %{}],
        opts
      )
    )
  end

  defp refute_tool_ran do
    refute_receive {:tool_ran, _}, 50
  end

  describe "ungated context (the default)" do
    test "a tool that does not require approval runs" do
      tool = probe_tool(requires_approval: false)

      assert {:ok, "executed"} = ToolExecutor.execute(tool, %{}, RunContext.new(%{}))
      assert_receive {:tool_ran, _}
    end

    test "a tool requiring approval is REJECTED and never invoked" do
      tool = probe_tool(requires_approval: true)

      log =
        capture_log(fn ->
          assert {:error, error} = ToolExecutor.execute(tool, %{}, RunContext.new(%{}))
          assert error.tool_name == "probe"
          assert error.message =~ "requires approval"
        end)

      assert log =~ "no :approval_handler"
      refute_tool_ran()
    end
  end

  describe "context carrying an approval handler" do
    test ":approve lets the tool run" do
      tool = probe_tool(requires_approval: true)
      ctx = RunContext.new(%{}, approval_handler: fn _call -> :approve end)

      assert {:ok, "executed"} = ToolExecutor.execute(tool, %{"a" => 1}, ctx)
      assert_receive {:tool_ran, %{"a" => 1}}
    end

    test ":reject blocks execution" do
      tool = probe_tool(requires_approval: true)
      ctx = RunContext.new(%{}, approval_handler: fn _call -> :reject end)

      assert {:error, error} = ToolExecutor.execute(tool, %{}, ctx)
      assert error.message =~ "rejected by the approval handler"
      refute_tool_ran()
    end

    test "{:edit, args} substitutes the arguments the tool receives" do
      tool = probe_tool(requires_approval: true)
      ctx = RunContext.new(%{}, approval_handler: fn _call -> {:edit, %{"a" => 99}} end)

      assert {:ok, "executed"} = ToolExecutor.execute(tool, %{"a" => 1}, ctx)
      assert_receive {:tool_ran, %{"a" => 99}}
    end

    test "an unrecognised handler return fails closed and warns" do
      tool = probe_tool(requires_approval: true)
      ctx = RunContext.new(%{}, approval_handler: fn _call -> :maybe end)

      log =
        capture_log(fn ->
          assert {:error, _} = ToolExecutor.execute(tool, %{}, ctx)
        end)

      assert log =~ "expected :approve"
      refute_tool_ran()
    end

    test "the handler receives the same payload shape the runner passes" do
      tool = probe_tool(requires_approval: true)
      test_pid = self()

      ctx =
        RunContext.new(%{},
          approval_handler: fn call ->
            send(test_pid, {:handler_call, call})
            :approve
          end
        )

      ToolExecutor.execute(tool, %{"q" => "x"}, ctx)

      assert_receive {:handler_call, call}
      assert call.name == "probe"
      assert call.arguments == %{"q" => "x"}
      assert call.tool.name == "probe"
      # No provider tool-call id exists outside the runner loop.
      assert call.id == nil
    end

    test "a handler is not consulted for a tool that does not require approval" do
      tool = probe_tool(requires_approval: false)
      test_pid = self()

      ctx =
        RunContext.new(%{},
          approval_handler: fn _call ->
            send(test_pid, :handler_consulted)
            :reject
          end
        )

      assert {:ok, "executed"} = ToolExecutor.execute(tool, %{}, ctx)
      refute_receive :handler_consulted, 50
    end
  end

  describe "approval_gated? contexts (callers that already gated)" do
    test "an already-gated context runs the tool without re-prompting" do
      tool = probe_tool(requires_approval: true)
      test_pid = self()

      ctx =
        RunContext.new(%{},
          approval_gated?: true,
          approval_handler: fn _call ->
            send(test_pid, :handler_consulted)
            :reject
          end
        )

      assert {:ok, "executed"} = ToolExecutor.execute(tool, %{}, ctx)
      # Double-prompting the operator would be a regression, not a hardening.
      refute_receive :handler_consulted, 50
    end

    test "an already-gated context runs the tool even with no handler at all" do
      tool = probe_tool(requires_approval: true)

      assert {:ok, "executed"} =
               ToolExecutor.execute(tool, %{}, RunContext.new(%{}, approval_gated?: true))
    end
  end

  describe "Agent.Context.to_run_context/1" do
    test "marks the runner's context gated and carries the handler through" do
      handler = fn _call -> :approve end
      run_ctx = Context.to_run_context(Context.new(approval_handler: handler))

      assert run_ctx.approval_gated? == true
      assert run_ctx.approval_handler == handler
    end

    test "a bare RunContext defaults to ungated with no handler" do
      ctx = RunContext.new(%{})

      assert ctx.approval_gated? == false
      assert ctx.approval_handler == nil
    end
  end

  describe "Workflow :tool_step" do
    defp tool_node(tool) do
      Node.new(%{
        id: "step",
        type: :tool_step,
        label: "step",
        config: %{tool: tool, args: %{}}
      })
    end

    test "rejects an approval-gated tool when the workflow supplies no handler" do
      tool = probe_tool(requires_approval: true)

      capture_log(fn ->
        assert {:error, _} = Executor.execute(tool_node(tool), State.new())
      end)

      refute_tool_ran()
    end

    test "runs an approval-gated tool when the workflow metadata supplies a handler" do
      tool = probe_tool(requires_approval: true)
      state = %{State.new() | metadata: %{approval_handler: fn _call -> :approve end}}

      assert {:ok, "executed", _state} = Executor.execute(tool_node(tool), state)
      assert_receive {:tool_ran, _}
    end

    test "runs a tool that does not require approval" do
      tool = probe_tool(requires_approval: false)

      assert {:ok, "executed", _state} = Executor.execute(tool_node(tool), State.new())
      assert_receive {:tool_ran, _}
    end
  end

  describe "HumanInTheLoop no longer narrows the gate" do
    # Regression for the fail-open bug: configuring HITL with a :tools list used
    # to wrap the handler so that any approval-gated tool OUTSIDE that list took
    # an `else -> :approve` branch. Installing the approval plugin therefore
    # turned Bash/FileWrite/FileEdit from default-deny into silent auto-approve.
    setup do
      test_pid = self()

      ctx =
        Context.new(
          deps: %{
            hitl_config: %{
              tools: ["send_email"],
              handler: fn call ->
                send(test_pid, {:asked, call.name})
                :reject
              end
            }
          }
        )

      %{handler: HumanInTheLoop.init(Nous.Agent.new("openai:test-model"), ctx).approval_handler}
    end

    test "a tool outside :tools still reaches the handler", %{handler: handler} do
      assert :reject = handler.(%{name: "bash", id: nil, arguments: %{}, tool: nil})
      assert_receive {:asked, "bash"}
    end

    test "a tool inside :tools still reaches the handler", %{handler: handler} do
      assert :reject = handler.(%{name: "send_email", id: nil, arguments: %{}, tool: nil})
      assert_receive {:asked, "send_email"}
    end

    test "an approval-gated tool outside :tools is not auto-approved end-to-end",
         %{handler: handler} do
      tool = probe_tool(requires_approval: true)
      ctx = RunContext.new(%{}, approval_handler: handler)

      assert {:error, _} = ToolExecutor.execute(tool, %{}, ctx)
      refute_tool_ran()
    end
  end
end

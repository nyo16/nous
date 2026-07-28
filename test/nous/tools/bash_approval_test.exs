defmodule Nous.Tools.BashApprovalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nous.{RunContext, Tool, ToolExecutor}

  # test/nous/tool_executor_approval_test.exs pins the approval gate with a
  # synthetic probe tool: it proves the ToolExecutor clause fires. This file
  # pins the same invariant around the *real* Nous.Tools.Bash — the tool an
  # injected prompt actually reaches — and proves the refusal with a filesystem
  # side effect that must NOT happen. The command would `touch` a marker; if
  # the gate ever stops applying to the shipped tool (a metadata regression, a
  # from_module regression, or an entry point that skips check_approval/3), the
  # marker appears and these tests fail.
  #
  # `:tmp_dir` gives each test a unique async-safe directory, so the marker
  # cannot collide with a sibling test or leak into /tmp.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "bash_ran_marker")

    %{
      tool: Tool.from_module(Nous.Tools.Bash),
      marker: marker,
      args: %{"command" => "touch '#{marker}'"}
    }
  end

  describe "the real Bash tool through ToolExecutor" do
    test "is refused on an ungated context and the command never runs", ctx do
      log =
        capture_log(fn ->
          assert {:error, error} = ToolExecutor.execute(ctx.tool, ctx.args, RunContext.new(%{}))
          assert error.tool_name == "bash"
          assert error.message =~ "requires approval"
        end)

      assert log =~ "no :approval_handler"
      refute File.exists?(ctx.marker)
    end

    test "an approving handler lets the same command run", ctx do
      # The control for the test above: without this, a refusal test would stay
      # green even if `touch` could never create the marker in the first place.
      run_ctx = RunContext.new(%{}, approval_handler: fn %{name: "bash"} -> :approve end)

      assert {:ok, _output} = ToolExecutor.execute(ctx.tool, ctx.args, run_ctx)
      assert File.exists?(ctx.marker)
    end

    test "a rejecting handler blocks the command", ctx do
      run_ctx = RunContext.new(%{}, approval_handler: fn _call -> :reject end)

      assert {:error, error} = ToolExecutor.execute(ctx.tool, ctx.args, run_ctx)
      assert error.message =~ "rejected by the approval handler"
      refute File.exists?(ctx.marker)
    end

    test "the handler is handed the real tool's name and arguments", ctx do
      test_pid = self()

      run_ctx =
        RunContext.new(%{},
          approval_handler: fn call ->
            send(test_pid, {:asked, call.name, call.arguments})
            :reject
          end
        )

      assert {:error, _} = ToolExecutor.execute(ctx.tool, ctx.args, run_ctx)
      assert_receive {:asked, "bash", %{"command" => command}}
      assert command =~ "touch"
      refute File.exists?(ctx.marker)
    end
  end
end

defmodule Nous.CodeMode.SchedulerDeadlineTest do
  # The lane's backstop is the run's own patience, `config :nous,
  # :code_run_timeout_ms`, which every scheduler in the VM reads — so this
  # cannot share a wall clock with async modules the way
  # `Nous.CodeMode.SchedulerTest` does.
  use ExUnit.Case, async: false

  alias Nous.CodeMode.Scheduler
  alias Nous.Tool

  @moduletag :capture_log

  # A predicate that never returns wedges the lane itself: `concurrency_safe?/1`
  # runs inside the scheduler's own process, at submit time.
  defmodule Stuck do
    @moduledoc false
    def concurrency_safe?(_args), do: receive(do: (:never -> true))
  end

  defmodule Safe do
    @moduledoc false
    def concurrency_safe?(_args), do: true
  end

  setup do
    Application.put_env(:nous, :code_run_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:nous, :code_run_timeout_ms) end)
    :ok
  end

  test "a sub-call whose dispatch never returns yields a timeout error, not a hang" do
    dispatch = fn _tool, _args, _run_ctx -> receive(do: (:never -> {:ok, :unreachable})) end
    {:ok, sched} = Scheduler.start_link(dispatch: dispatch)

    assert {:error, %{"tool" => "hangs", "message" => message}} =
             Scheduler.call(sched, tool("hangs", Safe), %{}, nil)

    assert message =~ "timed out"

    # The lane itself is fine: it answers, and tears down normally.
    assert :ok = Scheduler.stop(sched)
    refute Process.alive?(sched)
  end

  test "a lane that stops answering yields an error on submit and is killed on stop" do
    {:ok, sched} = Scheduler.start_link(dispatch: fn _t, _a, _c -> {:ok, :done} end)

    assert {:error, %{"tool" => "stuck", "message" => message}} =
             Scheduler.submit(sched, tool("stuck", Stuck), %{}, nil)

    assert message =~ "did not answer"

    # Every later submission hits the same wedged lane, and none of them hangs.
    assert {:error, %{"tool" => "after"}} = Scheduler.submit(sched, tool("after", Safe), %{}, nil)

    # stop/2 cannot reach terminate/2 either; it must not leave the lane behind,
    # and must not take this (linked) process down with it.
    assert :ok = Scheduler.stop(sched)
    refute Process.alive?(sched)
  end

  defp tool(name, module) do
    %Tool{name: name, function: fn _ctx, _args -> :ok end, module: module}
  end
end

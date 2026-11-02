defmodule Nous.Eval.Online.HandlerTest do
  use ExUnit.Case, async: true

  alias Nous.Eval.Online.Handler

  defp row(table, tid, state), do: :ets.insert(table, {tid, "rid", 0, state, 0})
  defp state_of(table, tid), do: :ets.lookup_element(table, tid, 4)

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    pid
  end

  test "a restarted coordinator releases only rows held by an earlier one" do
    table = :ets.new(__MODULE__, [:set, :public])
    earlier = dead_pid()

    row(table, "queued-earlier", {:queued, earlier})
    # Queued to the new coordinator while its init/1 runs: its name is
    # already registered, so a handler can reach it.
    row(table, "queued-self", {:queued, self()})
    row(table, "running-earlier", :running)
    row(table, "open", :open)

    assert Handler.release_stale(table, self()) == 1

    assert state_of(table, "queued-earlier") == :closed
    assert state_of(table, "queued-self") == {:queued, self()}
    assert state_of(table, "running-earlier") == :closed
    assert state_of(table, "open") == :open
  end
end

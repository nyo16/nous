defmodule Nous.DecisionModel.Backend.LlamaCppLookupTest do
  @moduledoc """
  Name resolution and child spec of `Nous.DecisionModel.Backend.LlamaCpp`,
  which need no model file, so they run in the default suite.
  """
  # async: false: the first test aims a decide call at Nous.TaskSupervisor.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nous.DecisionModel
  alias Nous.DecisionModel.Backend.LlamaCpp
  alias Nous.Errors.DecisionModelError

  if Code.ensure_loaded?(LlamaCppEx.Decision) do
    describe "name resolution" do
      test ~s("llamacpp:Elixir.Nous.TaskSupervisor" cannot reach the task supervisor) do
        supervisor = Process.whereis(Nous.TaskSupervisor)
        ref = Process.monitor(supervisor)
        dm = DecisionModel.parse("llamacpp:Elixir.Nous.TaskSupervisor")

        assert {:error, %DecisionModelError{reason: :unavailable, backend: LlamaCpp}} =
                 DecisionModel.decide(dm, "s", a: [type: :noul])

        assert {:noproc, _} = catch_exit(DecisionModel.max_state_tokens(dm))
        assert {:noproc, _} = catch_exit(DecisionModel.count_tokens(dm, "s"))

        refute_received {:DOWN, ^ref, :process, _, _}
        assert Process.whereis(Nous.TaskSupervisor) == supervisor
        Process.demonitor(ref, [:flush])
      end

      test "a registered process this module did not start is never called, by name or server:" do
        test_pid = self()
        probe = spawn_link(fn -> probe(test_pid) end)
        name = :"nous_test_probe_#{System.unique_integer([:positive])}"
        Process.register(probe, name)

        for dm <- [
              DecisionModel.parse("llamacpp:#{name}"),
              DecisionModel.parse("llamacpp:ignored", server: name),
              DecisionModel.parse("llamacpp:ignored", server: probe)
            ] do
          assert {:error, %DecisionModelError{reason: :unavailable}} =
                   quietly(fn ->
                     DecisionModel.decide(dm, "s", [a: [type: :noul]], timeout: 500)
                   end)

          quietly(fn -> DecisionModel.max_state_tokens(dm) end)
          quietly(fn -> DecisionModel.count_tokens(dm, "s") end)
        end

        # The probe handles its mailbox in order, so once it answers the sync,
        # anything it was sent before has been forwarded here.
        send(probe, {:sync, self()})
        assert_receive :synced
        refute_received {:probe_received, _}
      end
    end

    test "child_spec/1 gives a model-sized shutdown, overridable" do
      assert %{shutdown: 30_000} = LlamaCpp.child_spec(name: :x, source: {:path, "/m.gguf"})

      assert %{shutdown: 60_000} =
               LlamaCpp.child_spec(name: :x, source: {:path, "/m.gguf"}, shutdown: 60_000)
    end
  end

  # Forwards every message to the test and answers calls, so a call that
  # reaches it neither hangs nor goes unnoticed.
  defp probe(test_pid) do
    receive do
      {:sync, from} ->
        send(from, :synced)

      {:"$gen_call", from, message} ->
        send(test_pid, {:probe_received, message})
        GenServer.reply(from, {:error, :probe})

      other ->
        send(test_pid, {:probe_received, other})
    end

    probe(test_pid)
  end

  defp quietly(fun) do
    fun.()
  catch
    :exit, reason -> {:exit, reason}
  end
end

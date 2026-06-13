defmodule Nous.Teams.SupervisorTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.Supervisor, as: TeamSupervisor

  defp team_id, do: "sup_test_#{System.unique_integer([:positive])}"

  defp start_team(opts) do
    tid = Keyword.fetch!(opts, :team_id)
    start_supervised!({TeamSupervisor, opts}, id: {:team_sup, tid})
  end

  describe "child supervision" do
    test "starts core children (agent sup, shared state, coordinator) without a rate limiter when no budget" do
      tid = team_id()
      pid = start_team(team_id: tid)

      assert length(Supervisor.which_children(pid)) == 3

      # SharedState, Coordinator, and the agent DynamicSupervisor are registered
      # under their team-scoped names.
      assert is_pid(Process.whereis(:"team_shared_state_#{tid}"))
      assert is_pid(Process.whereis(:"team_coordinator_#{tid}"))
      assert is_pid(Process.whereis(:"team_agent_sup_#{tid}"))

      # No rate limiter without a budget.
      assert Process.whereis(:"team_rate_limiter_#{tid}") == nil
    end

    test "starts the rate limiter when a budget is given" do
      tid = team_id()
      pid = start_team(team_id: tid, budget: 10.0, tpm: 1000)

      assert length(Supervisor.which_children(pid)) == 4
      assert is_pid(Process.whereis(:"team_rate_limiter_#{tid}"))
    end
  end

  describe "restart strategy" do
    test "one_for_all: a SharedState crash takes the Coordinator down with it" do
      tid = team_id()
      start_team(team_id: tid)

      shared_state = Process.whereis(:"team_shared_state_#{tid}")
      coordinator = Process.whereis(:"team_coordinator_#{tid}")
      ref = Process.monitor(coordinator)

      # Kill a sibling; one_for_all must terminate the Coordinator too.
      Process.exit(shared_state, :kill)

      assert_receive {:DOWN, ^ref, :process, ^coordinator, _reason}, 1000
    end
  end
end

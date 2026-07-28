defmodule Nous.Teams.SharedStateTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.SharedState

  # Bounded poll for a condition that becomes true once a timer fires. Fixed
  # sleeps sized just over a TTL flake on a loaded runner, because the timer
  # itself is scheduled late.
  defp eventually(fun, timeout_ms \\ 2_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        true
      else
        Process.sleep(interval_ms)
        false
      end
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > deadline end)
  end

  setup do
    team_id = "state_test_#{System.unique_integer([:positive])}"
    # Generous claim TTL: no test in this file should be able to outrun it.
    # Expiry is exercised by "claims auto-expire after TTL" below, which starts
    # its own short-TTL server. A short TTL here silently raced every other
    # get_claims/1 assertion — the P-2 read test could spend >200ms warming the
    # table cache before it even reached its assertion, and did fail that way
    # under load.
    {:ok, pid} = start_supervised({SharedState, team_id: team_id, claim_ttl: :timer.minutes(1)})
    %{pid: pid, team_id: team_id}
  end

  describe "discoveries" do
    test "share_discovery stores and retrieves discoveries", %{pid: pid} do
      :ok =
        SharedState.share_discovery(pid, "alice", %{topic: "Bug", content: "Found null check"})

      discoveries = SharedState.get_discoveries(pid)
      assert length(discoveries) == 1

      [d] = discoveries
      assert d.agent == "alice"
      assert d.topic == "Bug"
      assert d.content == "Found null check"
      assert %DateTime{} = d.timestamp
    end

    test "multiple discoveries are accumulated", %{pid: pid} do
      :ok = SharedState.share_discovery(pid, "alice", %{topic: "A", content: "First"})
      :ok = SharedState.share_discovery(pid, "bob", %{topic: "B", content: "Second"})

      discoveries = SharedState.get_discoveries(pid)
      assert length(discoveries) == 2
      assert Enum.map(discoveries, & &1.agent) == ["alice", "bob"]
    end

    test "get_discoveries returns empty list initially", %{pid: pid} do
      assert SharedState.get_discoveries(pid) == []
    end

    test "accepts string keys in discovery map", %{pid: pid} do
      :ok = SharedState.share_discovery(pid, "alice", %{"topic" => "Test", "content" => "Data"})

      [d] = SharedState.get_discoveries(pid)
      assert d.topic == "Test"
      assert d.content == "Data"
    end
  end

  describe "region claims" do
    test "claim_region succeeds when no conflict", %{pid: pid} do
      assert :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
    end

    test "claim_region detects conflict with overlapping range", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      assert {:error, :conflict} = SharedState.claim_region(pid, "bob", "lib/parser.ex", 15, 25)
    end

    test "same agent can re-claim same file", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      assert :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 5, 30)
    end

    test "different files don't conflict", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      assert :ok = SharedState.claim_region(pid, "bob", "lib/lexer.ex", 10, 20)
    end

    test "non-overlapping ranges on same file don't conflict", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      assert :ok = SharedState.claim_region(pid, "bob", "lib/parser.ex", 21, 30)
    end

    test "release_region allows others to claim", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      :ok = SharedState.release_region(pid, "alice", "lib/parser.ex")
      assert :ok = SharedState.claim_region(pid, "bob", "lib/parser.ex", 10, 20)
    end

    test "get_claims returns all current claims", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)
      :ok = SharedState.claim_region(pid, "bob", "lib/lexer.ex", 1, 5)

      claims = SharedState.get_claims(pid)
      assert length(claims) == 2

      agents = Enum.map(claims, & &1.agent) |> Enum.sort()
      assert agents == ["alice", "bob"]
    end

    test "claims auto-expire after TTL" do
      team_id = "claim_ttl_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!({SharedState, team_id: team_id, claim_ttl: 200},
          id: :"claim_ttl_#{team_id}"
        )

      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)

      # Poll rather than sleeping a fixed margin over the TTL: a loaded runner
      # can fire the expiry timer late, and a bare Process.sleep(300) would then
      # fail for a reason that has nothing to do with the behaviour under test.
      assert eventually(fn ->
               SharedState.claim_region(pid, "bob", "lib/parser.ex", 10, 20) == :ok
             end)
    end
  end

  describe "concurrent claims (Phase 3 row-per-entry)" do
    test "many agents racing for the same region: exactly one wins", %{pid: pid} do
      results =
        1..25
        |> Task.async_stream(
          fn i -> SharedState.claim_region(pid, "agent_#{i}", "lib/hot.ex", 10, 20) end,
          max_concurrency: 25,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # claim_region is a GenServer.call (serialized), so conflict detection is
      # deterministic under concurrency: the first to be processed wins, the
      # rest (different agents, overlapping range) conflict.
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :conflict})) == 24

      # Only the winner's claim exists on that file.
      assert [%{file: "lib/hot.ex", start_line: 10, end_line: 20}] = SharedState.get_claims(pid)
    end

    test "non-overlapping concurrent claims on the same file all succeed", %{pid: pid} do
      results =
        0..9
        |> Task.async_stream(
          fn i ->
            SharedState.claim_region(pid, "agent_#{i}", "lib/wide.ex", i * 10, i * 10 + 5)
          end,
          max_concurrency: 10,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert length(SharedState.get_claims(pid)) == 10
    end
  end

  describe "concurrent reads (P-2)" do
    test "reads run in the caller, not the owner's mailbox", %{pid: pid} do
      :ok = SharedState.share_discovery(pid, "alice", %{topic: "A", content: "First"})
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)

      # Warm the caller-side table cache (one call), then freeze the owner.
      _ = SharedState.get_discoveries(pid)
      _ = SharedState.get_claims(pid)

      :sys.suspend(pid)

      try do
        # A suspended GenServer answers no calls at all, so these returning at
        # all proves the reads run in this process against the :protected
        # table instead of serializing behind handle_call.
        assert [%{topic: "A"}] = SharedState.get_discoveries(pid)
        assert [%{file: "lib/parser.ex"}] = SharedState.get_claims(pid)
      after
        :sys.resume(pid)
      end
    end

    test "50 processes read concurrently and all see the same ordered set", %{pid: pid} do
      for i <- 1..20 do
        :ok = SharedState.share_discovery(pid, "agent_#{i}", %{topic: "t#{i}", content: "c#{i}"})
      end

      expected = Enum.map(1..20, &"t#{&1}")

      results =
        1..50
        |> Task.async_stream(fn _ -> SharedState.get_discoveries(pid) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, discoveries} -> Enum.map(discoveries, & &1.topic) end)

      assert length(results) == 50
      assert Enum.all?(results, &(&1 == expected))
    end

    test "a cached table id is not reused after the owner is replaced" do
      team_id = "ss_restart_#{System.unique_integer([:positive])}"
      name = :"ss_restart_#{team_id}"

      {:ok, first} = SharedState.start_link(team_id: team_id, name: name)
      Process.unlink(first)

      :ok = SharedState.share_discovery(name, "alice", %{topic: "A", content: "First"})
      assert [%{topic: "A"}] = SharedState.get_discoveries(name)

      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 1_000

      # This process still holds the dead table id. The next read must notice
      # the owner changed and re-resolve rather than raise or serve rows from
      # whatever table inherited the identifier.
      {:ok, second} = SharedState.start_link(team_id: team_id, name: name)
      Process.unlink(second)

      assert SharedState.get_discoveries(name) == []

      :ok = SharedState.share_discovery(name, "bob", %{topic: "B", content: "Second"})
      assert [%{topic: "B"}] = SharedState.get_discoveries(name)

      Process.exit(second, :kill)
    end
  end

  describe "discovery pruning (P-2)" do
    test "discoveries expire after :discovery_ttl" do
      team_id = "disc_ttl_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!({SharedState, team_id: team_id, discovery_ttl: 200},
          id: :"disc_ttl_#{team_id}"
        )

      :ok = SharedState.share_discovery(pid, "alice", %{topic: "A", content: "First"})
      assert length(SharedState.get_discoveries(pid)) == 1

      # Poll: a loaded runner schedules the expiry timer late, so a fixed
      # sleep sized just over the TTL fails for reasons unrelated to pruning.
      assert eventually(fn -> SharedState.get_discoveries(pid) == [] end)
    end

    test "discovery_ttl: :infinity opts out of pruning" do
      team_id = "disc_inf_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!({SharedState, team_id: team_id, discovery_ttl: :infinity},
          id: :"disc_inf_#{team_id}"
        )

      :ok = SharedState.share_discovery(pid, "alice", %{topic: "A", content: "First"})
      Process.sleep(300)

      assert [%{topic: "A"}] = SharedState.get_discoveries(pid)
    end
  end
end

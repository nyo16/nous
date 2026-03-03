defmodule Nous.Teams.SharedStateTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.SharedState

  setup do
    team_id = "state_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({SharedState, team_id: team_id, claim_ttl: 200})
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

    test "claims auto-expire after TTL", %{pid: pid} do
      :ok = SharedState.claim_region(pid, "alice", "lib/parser.ex", 10, 20)

      # Wait for expiry (TTL is 200ms in setup)
      Process.sleep(300)

      # Bob should be able to claim the same region now
      assert :ok = SharedState.claim_region(pid, "bob", "lib/parser.ex", 10, 20)
    end
  end
end

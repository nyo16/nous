defmodule Nous.Teams.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.RateLimiter

  setup do
    team_id = "rl_test_#{System.unique_integer([:positive])}"
    %{team_id: team_id}
  end

  describe "basic operation" do
    test "acquire succeeds with no limits and returns a reservation ref", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id})
      assert {:ok, ref} = RateLimiter.acquire(pid, "alice", 1000)
      assert is_reference(ref)
    end

    test "get_status returns infinity budget when no budget set", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id})
      status = RateLimiter.get_status(pid)

      assert status.budget_remaining == :infinity
      assert status.agents == %{}
    end
  end

  describe "budget enforcement" do
    test "acquire fails when team budget exceeded", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, budget: 1.0})

      # Record usage that exceeds budget
      RateLimiter.record_usage(pid, "alice", %{tokens: 1000, cost: 1.5, requests: 1})

      # Allow cast to process
      Process.sleep(10)

      assert {:error, :budget_exceeded} = RateLimiter.acquire(pid, "alice", 100)
    end

    test "acquire fails when per-agent budget exceeded", %{team_id: team_id} do
      {:ok, pid} =
        start_supervised({RateLimiter, team_id: team_id, budget: 100.0, per_agent_budget: 1.0})

      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 1.5, requests: 1})
      Process.sleep(10)

      assert {:error, :budget_exceeded} = RateLimiter.acquire(pid, "alice", 100)
    end

    test "different agents have separate per-agent budgets", %{team_id: team_id} do
      {:ok, pid} =
        start_supervised({RateLimiter, team_id: team_id, budget: 100.0, per_agent_budget: 2.0})

      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 1.5, requests: 1})
      Process.sleep(10)

      # Alice is under per-agent budget, bob has no usage
      assert {:ok, _ref_a} = RateLimiter.acquire(pid, "alice", 100)
      assert {:ok, _ref_b} = RateLimiter.acquire(pid, "bob", 100)
    end
  end

  describe "record_usage and get_status" do
    test "record_usage tracks per-agent usage", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, budget: 100.0})

      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 0.5, requests: 1})
      RateLimiter.record_usage(pid, "bob", %{tokens: 300, cost: 0.3, requests: 2})
      Process.sleep(10)

      status = RateLimiter.get_status(pid)
      assert_in_delta status.budget_remaining, 99.2, 0.01

      assert status.agents["alice"].tokens == 500
      assert status.agents["alice"].cost == 0.5
      assert status.agents["bob"].tokens == 300
      assert status.agents["bob"].requests == 2
    end

    test "record_usage accumulates for same agent", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, budget: 100.0})

      RateLimiter.record_usage(pid, "alice", %{tokens: 100, cost: 0.1, requests: 1})
      RateLimiter.record_usage(pid, "alice", %{tokens: 200, cost: 0.2, requests: 1})
      Process.sleep(10)

      status = RateLimiter.get_status(pid)
      assert status.agents["alice"].tokens == 300
      assert_in_delta status.agents["alice"].cost, 0.3, 0.01
      assert status.agents["alice"].requests == 2
    end
  end

  describe "rate limiting" do
    test "acquire fails when RPM exceeded", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, rpm: 2})

      # Record 2 requests within the window
      RateLimiter.record_usage(pid, "alice", %{tokens: 100, cost: 0.0, requests: 1})
      RateLimiter.record_usage(pid, "alice", %{tokens: 100, cost: 0.0, requests: 1})
      Process.sleep(10)

      assert {:error, :rate_limited} = RateLimiter.acquire(pid, "alice", 100)
    end

    test "acquire fails when TPM exceeded", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, tpm: 500})

      RateLimiter.record_usage(pid, "alice", %{tokens: 400, cost: 0.0, requests: 1})
      Process.sleep(10)

      # Trying to acquire 200 tokens when 400 already used, limit is 500
      assert {:error, :rate_limited} = RateLimiter.acquire(pid, "alice", 200)
    end

    test "acquire succeeds within rate limits", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, rpm: 10, tpm: 10_000})

      RateLimiter.record_usage(pid, "alice", %{tokens: 100, cost: 0.0, requests: 1})
      Process.sleep(10)

      assert {:ok, _ref} = RateLimiter.acquire(pid, "alice", 100)
    end
  end

  # ===========================================================================
  # M-9: Reservation-based atomicity tests
  # ===========================================================================

  describe "reservation atomicity (M-9)" do
    test "concurrent acquires near the budget cap are race-safe", %{team_id: team_id} do
      # 5 concurrent acquires of 1 USD each against a 3 USD budget. Without
      # reservations, all 5 would see "budget remaining" before any cost
      # was recorded (cost is unknown until response). Tokens DO get
      # reserved up-front, so reserving 5 tokens against tpm:5 should
      # cap concurrent acquires at 5 — but the budget angle here uses
      # cost which acquire doesn't pre-deduct. To exercise the fix we
      # use TPM (which IS reserved): tpm: 5 with 5 parallel acquires of
      # 1 token each = exactly the cap; a 6th must fail.
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, tpm: 5})

      results =
        1..6
        |> Enum.map(fn _ ->
          Task.async(fn -> RateLimiter.acquire(pid, "alice", 1) end)
        end)
        |> Task.await_many()

      successes = Enum.count(results, &match?({:ok, _ref}, &1))
      rate_limited = Enum.count(results, &match?({:error, :rate_limited}, &1))

      # Exactly 5 of 6 succeed; the 6th is rate-limited. Without atomic
      # reservations all 6 could have succeeded.
      assert successes == 5
      assert rate_limited == 1
    end

    test "release/2 refunds a reservation", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, tpm: 100})

      {:ok, ref} = RateLimiter.acquire(pid, "alice", 80)

      # Acquiring 30 more should fail: 80 reserved + 30 = 110 > 100.
      assert {:error, :rate_limited} = RateLimiter.acquire(pid, "alice", 30)

      RateLimiter.release(pid, ref)
      Process.sleep(10)

      # After release, acquire should succeed.
      assert {:ok, _ref} = RateLimiter.acquire(pid, "alice", 30)
    end

    test "record_usage with :reservation reconciles to actual tokens", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, tpm: 200})

      {:ok, ref} = RateLimiter.acquire(pid, "alice", 150)

      # Reconcile to actual = 50 (much less than 150 estimate)
      RateLimiter.record_usage(pid, "alice", %{
        tokens: 50,
        cost: 0.001,
        requests: 1,
        reservation: ref
      })

      Process.sleep(10)

      # 50 tokens used + remaining headroom = 150. Acquire 100 should fit.
      assert {:ok, _ref} = RateLimiter.acquire(pid, "alice", 100)
    end

    test "record_usage without :reservation is post-hoc (legacy)", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id, budget: 100.0})

      # No acquire — just record. This is the legacy pattern; it must
      # keep working for callers that don't go through acquire.
      RateLimiter.record_usage(pid, "alice", %{tokens: 500, cost: 0.5, requests: 1})
      Process.sleep(10)

      status = RateLimiter.get_status(pid)
      assert status.agents["alice"].tokens == 500
      assert_in_delta status.agents["alice"].cost, 0.5, 0.01
      assert status.open_reservations == 0
    end

    test "open_reservations exposed via get_status", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id})

      {:ok, _ref1} = RateLimiter.acquire(pid, "alice", 100)
      {:ok, _ref2} = RateLimiter.acquire(pid, "bob", 100)

      assert RateLimiter.get_status(pid).open_reservations == 2
    end

    test "expired reservations are auto-refunded with a warning", %{team_id: team_id} do
      # Tiny TTL so the test doesn't wait long.
      {:ok, pid} =
        start_supervised({RateLimiter, team_id: team_id, tpm: 100, reservation_ttl_ms: 50})

      {:ok, _ref} = RateLimiter.acquire(pid, "alice", 80)

      # Wait past TTL.
      Process.sleep(120)

      # Triggering any operation runs prune_reservations and refunds.
      _ = RateLimiter.get_status(pid)

      # Now we have 100 budget free again.
      assert {:ok, _ref} = RateLimiter.acquire(pid, "alice", 80)
    end
  end
end

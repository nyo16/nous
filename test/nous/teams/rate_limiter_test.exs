defmodule Nous.Teams.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Nous.Teams.RateLimiter

  setup do
    team_id = "rl_test_#{System.unique_integer([:positive])}"
    %{team_id: team_id}
  end

  describe "basic operation" do
    test "acquire succeeds with no limits", %{team_id: team_id} do
      {:ok, pid} = start_supervised({RateLimiter, team_id: team_id})
      assert :ok = RateLimiter.acquire(pid, "alice", 1000)
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
      assert :ok = RateLimiter.acquire(pid, "alice", 100)
      assert :ok = RateLimiter.acquire(pid, "bob", 100)
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

      assert :ok = RateLimiter.acquire(pid, "alice", 100)
    end
  end
end

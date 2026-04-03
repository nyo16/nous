defmodule Nous.Session.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Nous.Session.{Config, Guardrails}

  describe "check_limits/4" do
    test "returns :ok when within limits" do
      config = %Config{max_turns: 10, max_budget_tokens: 100_000}
      assert :ok = Guardrails.check_limits(config, 5, 1000, 2000)
    end

    test "returns error when max turns reached" do
      config = %Config{max_turns: 10}
      assert {:error, :max_turns_reached} = Guardrails.check_limits(config, 10, 0, 0)
    end

    test "returns error when max turns exceeded" do
      config = %Config{max_turns: 10}
      assert {:error, :max_turns_reached} = Guardrails.check_limits(config, 15, 0, 0)
    end

    test "returns error when budget reached" do
      config = %Config{max_budget_tokens: 1000}
      assert {:error, :max_budget_reached} = Guardrails.check_limits(config, 0, 500, 500)
    end

    test "returns error when budget exceeded" do
      config = %Config{max_budget_tokens: 1000}
      assert {:error, :max_budget_reached} = Guardrails.check_limits(config, 0, 800, 400)
    end

    test "turns checked before budget" do
      config = %Config{max_turns: 5, max_budget_tokens: 100}
      assert {:error, :max_turns_reached} = Guardrails.check_limits(config, 5, 200, 200)
    end
  end

  describe "should_compact?/2" do
    test "true when over threshold" do
      config = %Config{compact_after_turns: 20}
      assert Guardrails.should_compact?(config, 25)
    end

    test "false when under threshold" do
      config = %Config{compact_after_turns: 20}
      refute Guardrails.should_compact?(config, 15)
    end

    test "false when at exact threshold" do
      config = %Config{compact_after_turns: 20}
      refute Guardrails.should_compact?(config, 20)
    end
  end

  describe "remaining/4" do
    test "calculates remaining budget" do
      config = %Config{max_turns: 10, max_budget_tokens: 100_000}
      assert {7, 85_000} = Guardrails.remaining(config, 3, 5000, 10_000)
    end

    test "floors at zero" do
      config = %Config{max_turns: 5, max_budget_tokens: 1000}
      assert {0, 0} = Guardrails.remaining(config, 10, 800, 500)
    end
  end

  describe "summary/4" do
    test "returns complete summary" do
      config = %Config{max_turns: 10, max_budget_tokens: 100_000, compact_after_turns: 8}
      summary = Guardrails.summary(config, 5, 10_000, 20_000)

      assert summary.turns == %{current: 5, max: 10, remaining: 5}
      assert summary.tokens == %{used: 30_000, max: 100_000, remaining: 70_000}
      refute summary.needs_compaction
    end

    test "shows compaction needed" do
      config = %Config{compact_after_turns: 5}
      summary = Guardrails.summary(config, 10, 0, 0)
      assert summary.needs_compaction
    end
  end
end

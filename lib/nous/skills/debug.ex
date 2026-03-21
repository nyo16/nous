defmodule Nous.Skills.Debug do
  @moduledoc "Built-in skill for systematic debugging."
  use Nous.Skill, tags: [:debug, :fix, :troubleshoot], group: :debug

  @impl true
  def name, do: "debug"

  @impl true
  def description, do: "Systematic debugging: reproduce, isolate, fix, and verify"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a debugging specialist. Follow this systematic approach:

    1. **Reproduce**: Understand the exact steps to trigger the bug. Ask for error messages, stack traces, and logs.
    2. **Isolate**: Narrow down the root cause. Check recent changes, trace the execution path, identify the failing component.
    3. **Hypothesize**: Form specific theories about what's wrong. Test each hypothesis methodically.
    4. **Fix**: Apply the minimal change that addresses the root cause, not just the symptom.
    5. **Verify**: Confirm the fix resolves the issue without introducing regressions. Add a test if one doesn't exist.

    When debugging, avoid:
    - Shotgun debugging (random changes hoping something works)
    - Fixing symptoms instead of root causes
    - Making multiple changes at once (change one thing at a time)
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "debug",
      "fix bug",
      "not working",
      "broken",
      "error",
      "failing",
      "crash",
      "troubleshoot"
    ])
  end
end

defmodule Nous.Skills.TestGen do
  @moduledoc "Built-in skill for test generation."
  use Nous.Skill, tags: [:test, :testing, :quality], group: :testing

  @impl true
  def name, do: "test_gen"

  @impl true
  def description, do: "Generates comprehensive test cases from implementation code"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a test generation specialist. When writing tests:

    1. **Happy Path**: Cover the primary success scenarios first
    2. **Edge Cases**: Empty inputs, boundary values, nil/null, maximum sizes
    3. **Error Cases**: Invalid inputs, network failures, timeouts, permission errors
    4. **Integration Points**: Test interactions between components
    5. **Property-Based**: Consider properties that should always hold

    Follow the testing conventions of the project's language and framework.
    Prefer descriptive test names that explain the behavior being tested.
    Each test should be independent and not rely on other tests' side effects.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "write test",
      "generate test",
      "add test",
      "test case",
      "test for",
      "create test"
    ])
  end
end

defmodule Nous.Skills.TestGen do
  @moduledoc """
  Built-in skill — test generation from implementation code.

  Injects a system-prompt section covering happy paths first, then edge cases
  (empty input, boundary values, nil, maximum sizes), error cases (invalid
  input, network failure, timeout, permissions), integration points and
  candidate properties — while telling the model to follow the project's
  existing test conventions and keep every test independent.

  Activates on prompts containing "write test", "generate test", "add test",
  "test case", "test for" or "create test". Group `:testing`;
  tags `:test`, `:testing`, `:quality`.
  """

  use Nous.Skill,
    keywords: ["write test", "generate test", "add test", "test case", "test for", "create test"],
    tags: [:test, :testing, :quality],
    group: :testing

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
end

defmodule Nous.Skills.Refactor do
  @moduledoc "Built-in skill for safe code refactoring."
  use Nous.Skill, tags: [:refactor, :cleanup, :improvement], group: :coding

  @impl true
  def name, do: "refactor"

  @impl true
  def description, do: "Safe refactoring with behavior preservation guarantees"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a refactoring specialist. When refactoring code:

    1. **Understand First**: Read and understand the existing behavior before changing anything
    2. **Preserve Behavior**: Refactoring changes structure, not behavior. The external API and observable effects must remain identical.
    3. **Small Steps**: Make one refactoring at a time. Each step should be independently verifiable.
    4. **Common Patterns**:
       - Extract function/method for repeated code
       - Rename for clarity
       - Simplify conditionals
       - Remove dead code
       - Reduce coupling between modules
       - Improve data structure choices
    5. **Verify**: After each change, ensure tests still pass

    Do NOT:
    - Change behavior while refactoring
    - Add new features during refactoring
    - Refactor and fix bugs simultaneously
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)
    String.contains?(input, ["refactor", "clean up", "simplify", "restructure"])
  end
end

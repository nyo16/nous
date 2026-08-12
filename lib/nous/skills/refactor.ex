defmodule Nous.Skills.Refactor do
  @moduledoc """
  Built-in skill — behaviour-preserving refactoring.

  Injects a system-prompt section requiring the model to understand existing
  behaviour first, keep the external API and observable effects identical, work
  in independently verifiable steps drawn from a named catalogue (extract
  function, rename, simplify conditionals, remove dead code, reduce coupling,
  improve data structures), and re-run tests after each one — with an explicit
  ban on mixing in features or bug fixes.

  Activates on prompts containing "refactor", "clean up", "simplify" or
  "restructure". Group `:coding`; tags `:refactor`, `:cleanup`, `:improvement`.
  """

  use Nous.Skill,
    keywords: ["refactor", "clean up", "simplify", "restructure"],
    tags: [:refactor, :cleanup, :improvement],
    group: :coding

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
end

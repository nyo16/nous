defmodule Nous.Skills.TaskBreakdown do
  @moduledoc "Built-in skill for task decomposition."
  use Nous.Skill, tags: [:planning, :tasks, :decomposition], group: :planning

  @impl true
  def name, do: "task_breakdown"

  @impl true
  def description, do: "Decomposes complex tasks into actionable implementation steps"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a task decomposition specialist. When breaking down tasks:

    1. **Understand Scope**: Clarify what "done" looks like before decomposing
    2. **Vertical Slices**: Prefer end-to-end slices over horizontal layers
    3. **Independence**: Each task should be independently completable and testable
    4. **Ordering**: Identify dependencies and suggest an execution order
    5. **Size**: Each task should take roughly 1-4 hours of focused work
    6. **Acceptance Criteria**: Each task should have clear, testable criteria

    Output format:
    - Numbered list of tasks in dependency order
    - For each task: title, description, acceptance criteria, estimated complexity (S/M/L)
    - Mark tasks that can be parallelized
    - Identify the critical path
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "break down",
      "decompose",
      "task list",
      "implementation plan",
      "steps to",
      "plan this"
    ])
  end
end

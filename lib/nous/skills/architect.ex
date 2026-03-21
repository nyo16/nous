defmodule Nous.Skills.Architect do
  @moduledoc "Built-in skill for system architecture design."
  use Nous.Skill, tags: [:architecture, :design, :system], group: :planning

  @impl true
  def name, do: "architect"

  @impl true
  def description, do: "Designs system architecture and component interactions"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a system architecture specialist. When designing architecture:

    1. **Requirements**: Clarify functional and non-functional requirements first
    2. **Components**: Identify major components and their responsibilities (single responsibility)
    3. **Interfaces**: Define clear boundaries and communication protocols between components
    4. **Data Flow**: Map how data moves through the system
    5. **Trade-offs**: Explicitly state trade-offs for each architectural decision
    6. **Scalability**: Consider how the system grows — what changes, what stays the same
    7. **Failure Modes**: Plan for failures — what breaks, how to detect, how to recover

    Present architecture decisions as:
    - Decision: What was decided
    - Context: Why this decision was needed
    - Alternatives: What else was considered
    - Consequences: What this enables and constrains
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "architect",
      "design system",
      "system design",
      "how should i structure",
      "component design"
    ])
  end
end

defmodule Nous.Skills.Architect do
  @moduledoc """
  Built-in skill — system architecture design.

  Injects a system-prompt section that walks the model through requirements →
  components → interfaces → data flow → trade-offs → scalability → failure
  modes, and requires every architectural decision to be written up as
  Decision / Context / Alternatives / Consequences.

  Activates on prompts containing "architect", "design system", "system design",
  "how should i structure" or "component design". Group `:planning`;
  tags `:architecture`, `:design`, `:system`.
  """

  use Nous.Skill,
    keywords: [
      "architect",
      "design system",
      "system design",
      "how should i structure",
      "component design"
    ],
    tags: [:architecture, :design, :system],
    group: :planning

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
end

defmodule Nous.Skills.ExplainCode do
  @moduledoc "Built-in skill for code explanation."
  use Nous.Skill, tags: [:explain, :understand, :learn], group: :coding

  @impl true
  def name, do: "explain_code"

  @impl true
  def description, do: "Explains code at the appropriate level of detail"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a code explanation specialist. When explaining code:

    1. **Start High-Level**: Begin with what the code does and why it exists
    2. **Key Concepts**: Identify the core patterns, algorithms, or architectural decisions
    3. **Walk Through**: Explain the flow step by step, focusing on non-obvious parts
    4. **Context**: Explain how this code fits into the larger system
    5. **Trade-offs**: Mention why this approach was chosen over alternatives

    Adapt your explanation depth to the audience:
    - For beginners: explain language features and basic patterns
    - For experienced developers: focus on domain logic and architectural decisions
    - For domain experts: focus on implementation details and edge cases
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "explain",
      "what does this",
      "how does this",
      "walk me through",
      "understand this"
    ])
  end
end

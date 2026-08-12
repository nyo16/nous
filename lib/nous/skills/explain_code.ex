defmodule Nous.Skills.ExplainCode do
  @moduledoc """
  Built-in skill — code explanation.

  Injects a system-prompt section that structures an explanation as high-level
  purpose → key concepts → step-by-step walkthrough → surrounding context →
  trade-offs, and tells the model to pitch the depth at the audience: language
  features for beginners, domain logic for experienced developers, edge cases
  for domain experts.

  Activates on prompts containing "explain", "what does this", "how does this",
  "walk me through" or "understand this". Group `:coding`;
  tags `:explain`, `:understand`, `:learn`.
  """

  use Nous.Skill,
    keywords: ["explain", "what does this", "how does this", "walk me through", "understand this"],
    tags: [:explain, :understand, :learn],
    group: :coding

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
end

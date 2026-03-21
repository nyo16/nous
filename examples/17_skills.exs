# Example 17: Skills — Reusable Instruction/Capability Packages
#
# Skills inject domain knowledge, tools, and prompt fragments into agents.
# They can be defined as modules, markdown files, or loaded by group.
#
# Run with: mix run examples/17_skills.exs
# Requires: OPENAI_API_KEY environment variable (for full agent run)

alias Nous.{Agent, Skill}
alias Nous.Skill.{Loader, Registry}

# =============================================================================
# Example 1: Module-based skill
# =============================================================================

IO.puts("=== Example 1: Module-Based Skill ===\n")

defmodule ElixirExpert do
  use Nous.Skill, tags: [:elixir, :functional], group: :coding

  @impl true
  def name, do: "elixir_expert"

  @impl true
  def description, do: "Provides Elixir-specific coding guidance"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are an Elixir expert. When writing Elixir code:
    - Prefer pattern matching over conditionals
    - Use the pipe operator for data transformations
    - Leverage OTP for concurrent and fault-tolerant systems
    - Write documentation with @doc and @moduledoc
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)
    String.contains?(input, ["elixir", "genserver", "otp", "phoenix"])
  end
end

skill = Skill.from_module(ElixirExpert)
IO.puts("Skill: #{skill.name}")
IO.puts("Description: #{skill.description}")
IO.puts("Tags: #{inspect(skill.tags)}")
IO.puts("Group: #{skill.group}")
IO.puts("Activation: #{inspect(skill.activation)}")

IO.puts("\nMatches 'write elixir code': #{ElixirExpert.match?("write elixir code")}")
IO.puts("Matches 'write python code': #{ElixirExpert.match?("write python code")}")

# =============================================================================
# Example 2: File-based skill — loading from markdown files
# =============================================================================

IO.puts("\n=== Example 2: File-Based Skill ===\n")

# --- 2a: Load a single skill from a .md file ---
IO.puts("--- 2a: Load a single file ---\n")

{:ok, file_skill} = Loader.load_file("examples/skills/api_design.md")
IO.puts("Loaded skill: #{file_skill.name}")
IO.puts("Description: #{file_skill.description}")
IO.puts("Tags: #{inspect(file_skill.tags)}")
IO.puts("Group: #{file_skill.group}")
IO.puts("Activation: #{file_skill.activation}")
IO.puts("Priority: #{file_skill.priority}")
IO.puts("Source: #{file_skill.source}")
IO.puts("Instructions preview: #{String.slice(file_skill.instructions, 0..60)}...")

# --- 2b: Load all skills from a directory ---
IO.puts("\n--- 2b: Load a directory ---\n")

dir_skills = Loader.load_directory("examples/skills/")
IO.puts("Loaded #{length(dir_skills)} skills from examples/skills/:")

for s <- dir_skills do
  IO.puts("  #{s.name} (group: #{s.group}, activation: #{s.activation})")
end

# --- 2c: Parse a skill from an inline markdown string ---
IO.puts("\n--- 2c: Parse from inline string ---\n")

markdown_content = """
---
name: quick_tips
description: Quick coding tips
tags: [tips]
group: coding
---

Always write tests before shipping.
"""

{:ok, inline_skill} = Loader.parse_skill(markdown_content, "quick_tips.md")
IO.puts("Parsed skill: #{inline_skill.name} — #{inline_skill.description}")

# =============================================================================
# Example 3: Skill Registry — groups, activation, matching
# =============================================================================

IO.puts("\n=== Example 3: Skill Registry ===\n")

# Create skills
review_skill = %Skill{
  name: "code_quality",
  description: "Code quality analysis",
  tags: [:quality],
  group: :review,
  activation: :manual,
  source: :inline,
  instructions: "Review code for quality issues",
  status: :loaded
}

test_skill = %Skill{
  name: "unit_testing",
  description: "Unit test generation",
  tags: [:test],
  group: :testing,
  activation: {:on_match, &String.contains?(&1, "test")},
  source: :inline,
  instructions: "Generate comprehensive unit tests",
  status: :loaded
}

# Build registry — mix module, file-based, and inline skills
registry =
  Registry.new()
  |> Registry.register(skill)
  |> Registry.register(file_skill)
  |> Registry.register(review_skill)
  |> Registry.register(test_skill)

# You can also register an entire directory at once:
# |> Registry.register_directory("priv/skills/")

IO.puts("Registry has #{length(Registry.list(registry))} skills:")

for name <- Registry.list(registry) do
  s = Registry.get(registry, name)
  IO.puts("  #{name} (group: #{s.group}, activation: #{inspect(s.activation)})")
end

# Activate by group
IO.puts("\nActivating :review group...")
{_results, registry} = Registry.activate_group(registry, :review, nil, nil)
active = Registry.active_skills(registry)
IO.puts("Active skills: #{Enum.map_join(active, ", ", & &1.name)}")

# Match against input
IO.puts("\nMatching 'write a test for this function':")
matched = Registry.match(registry, "write a test for this function")

for s <- matched do
  IO.puts("  Matched: #{s.name}")
end

IO.puts("\nMatching 'write elixir genserver':")
matched = Registry.match(registry, "write elixir genserver")

for s <- matched do
  IO.puts("  Matched: #{s.name}")
end

# =============================================================================
# Example 4: Built-in skills
# =============================================================================

IO.puts("\n=== Example 4: Built-in Skills ===\n")

builtin_skills = [
  Nous.Skills.CodeReview,
  Nous.Skills.TestGen,
  Nous.Skills.Debug,
  Nous.Skills.Refactor,
  Nous.Skills.ExplainCode,
  Nous.Skills.CommitMessage,
  Nous.Skills.DocGen,
  Nous.Skills.SecurityScan,
  Nous.Skills.Architect,
  Nous.Skills.TaskBreakdown
]

IO.puts("Built-in skills:")

for mod <- builtin_skills do
  s = Skill.from_module(mod)
  IO.puts("  #{s.name} (group: #{s.group}) — #{s.description}")
end

# =============================================================================
# Example 5: Agent with skills
# =============================================================================

IO.puts("\n=== Example 5: Agent with Skills ===\n")

# Mix all skill sources: modules, inline structs, groups, and file directories
agent =
  Agent.new("openai:gpt-4o-mini",
    instructions: "You are a helpful coding assistant.",
    skills: [
      ElixirExpert,
      review_skill,
      {:group, :testing}
    ],
    # Load .md skill files from directories (scanned recursively)
    skill_dirs: ["examples/skills/"]
  )

IO.puts("Agent created with #{length(agent.skills)} skill spec(s)")
IO.puts("Skills list: #{inspect(agent.skills, pretty: true)}")
IO.puts("Plugins auto-included: #{inspect(agent.plugins)}")

IO.puts("\n=== Done ===")

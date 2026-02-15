#!/usr/bin/env elixir

# Nous AI - Sub-Agents
# Delegate work to specialized sub-agents: one at a time or in parallel
#
# The SubAgent plugin provides two tools:
#   - `delegate_task`  — single sub-agent for focused work
#   - `spawn_agents`   — multiple sub-agents running concurrently
#
# The parent agent decides when and how to delegate via tool calls.
# Each sub-agent runs in its own isolated context.

IO.puts("=== Nous AI - Sub-Agents Demo ===\n")

# ============================================================================
# Example 1: Parallel research with template-based agents
# ============================================================================
#
# Define specialized agent templates as Agent structs. The parent agent
# picks which template to use for each task.

IO.puts("--- Example 1: Parallel research with templates ---")

templates = %{
  "researcher" =>
    Nous.Agent.new("lmstudio:qwen3",
      instructions: """
      You are a focused research specialist. When given a research question:
      1. Provide a clear, factual answer with specific technical details
      2. Include concrete examples (code snippets, configuration, API calls)
      3. Note any important caveats or limitations
      4. Keep your response under 200 words — be dense with information, not verbose

      Do NOT ask follow-up questions. Answer directly with what you know.
      """
    ),
  "analyst" =>
    Nous.Agent.new("lmstudio:qwen3",
      instructions: """
      You are a technical analyst who evaluates trade-offs. When given a topic:
      1. List 2-3 concrete pros with specific scenarios where they matter
      2. List 2-3 concrete cons with specific scenarios where they hurt
      3. Give a one-sentence recommendation for when to use this approach
      4. Keep your response under 200 words

      Be opinionated. Do NOT hedge with "it depends" — commit to a clear stance.
      """
    )
}

parent =
  Nous.Agent.new("lmstudio:qwen3",
    instructions: """
    You are a senior technical lead who coordinates research across specialists.

    When a user asks you to compare or research multiple things:
    1. Identify the independent sub-tasks (one per topic/angle)
    2. For each sub-task, write a SELF-CONTAINED prompt — the sub-agent has NO
       context from this conversation, so include all necessary background
    3. Call `spawn_agents` with all tasks at once using the appropriate template
    4. When results come back, synthesize them into a structured comparison
       with a clear recommendation at the end

    You have two templates available:
    - "researcher": factual deep-dives on specific topics
    - "analyst": trade-off analysis with pros/cons and recommendations

    IMPORTANT: Do NOT answer the question yourself. Always delegate to sub-agents
    first, then synthesize their findings.
    """,
    plugins: [Nous.Plugins.SubAgent],
    deps: %{sub_agent_templates: templates}
  )

{:ok, result} =
  Nous.Agent.run(
    parent,
    "Compare Elixir GenServer vs Agent vs ETS for caching. Research each option in parallel.",
    max_iterations: 15
  )

IO.puts("Parent's synthesized answer:")
IO.puts(result.output)
IO.puts("\nTotal tokens: #{result.usage.total_tokens}")
IO.puts("")

# ============================================================================
# Example 2: Inline models (no templates needed)
# ============================================================================

IO.puts("--- Example 2: Inline parallel agents ---")

parent2 =
  Nous.Agent.new("lmstudio:qwen3",
    instructions: """
    You are a content coordinator who produces documents by delegating sections
    to parallel writers.

    When asked to produce a multi-section document:
    1. Break the document into independent sections
    2. For each section, use `spawn_agents` with inline config:
       - Set "model" to "lmstudio:qwen3"
       - Set "instructions" to a writing style guide for that section
       - Set "task" to the specific content to write, including any context
         the writer needs (they have NO knowledge of the overall document)
    3. When all sections come back, assemble them into a cohesive document
       with transitions between sections and a brief introduction

    IMPORTANT: Each sub-agent writes ONE section independently. They cannot
    see each other's work. You handle stitching them together.
    """,
    plugins: [Nous.Plugins.SubAgent],
    deps: %{
      parallel_max_concurrency: 3,
      parallel_timeout: 60_000
    }
  )

{:ok, result2} =
  Nous.Agent.run(
    parent2,
    """
    Create an "Elixir Highlights" document with three sections:
    1. The Actor model and how processes work in Elixir/OTP
    2. Pattern matching and how it shapes Elixir code
    3. The pipe operator and functional composition

    Each section should be one focused paragraph. Write all three in parallel,
    then combine them with a short intro.
    """,
    max_iterations: 15
  )

IO.puts("Combined result:")
IO.puts(result2.output)
IO.puts("\nTotal tokens: #{result2.usage.total_tokens}")
IO.puts("")

# ============================================================================
# Example 3: Direct tool invocation (without LLM deciding)
# ============================================================================

IO.puts("--- Example 3: Direct parallel execution ---")

alias Nous.Agent.Context

ctx =
  Context.new(
    deps: %{
      sub_agent_templates: %{
        "writer" =>
          Nous.Agent.new("lmstudio:qwen3",
            instructions: """
            You are a concise technical writer for an Elixir glossary.
            Answer the question in exactly 2-3 sentences.
            Use plain language — assume the reader knows programming but not Elixir.
            Do NOT use bullet points or headers. Just prose.
            """
          )
      }
    }
  )

result3 =
  Nous.Plugins.SubAgent.spawn_agents(ctx, %{
    "tasks" => [
      %{
        "task" =>
          "Define OTP in Elixir. Explain what it stands for and why it matters for building reliable systems.",
        "template" => "writer"
      },
      %{
        "task" =>
          "Define a supervision tree in Elixir. Explain how it helps applications recover from crashes automatically.",
        "template" => "writer"
      },
      %{
        "task" =>
          "Define GenServer in Elixir. Explain what problem it solves and give one concrete use case.",
        "template" => "writer"
      }
    ]
  })

IO.puts("Parallel results: #{result3.succeeded}/#{result3.total} succeeded\n")

for {r, i} <- Enum.with_index(result3.results) do
  IO.puts("  Task #{i + 1}: #{r.task}")

  if r.success do
    IO.puts("  Answer: #{String.slice(r.output, 0, 120)}...")
    IO.puts("  Tokens: #{r.tokens_used}\n")
  else
    IO.puts("  Error: #{r.error}\n")
  end
end

IO.puts("Done!")

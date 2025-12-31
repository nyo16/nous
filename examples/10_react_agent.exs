#!/usr/bin/env elixir

# Nous AI - ReAct Agent
# Reasoning and Acting pattern for complex problem solving

IO.puts("=== Nous AI - ReAct Agent Demo ===\n")

IO.puts("""
ReAct = Reasoning + Acting

The agent interleaves:
  1. THOUGHT: Think about what to do next
  2. ACTION: Use a tool to get information
  3. OBSERVATION: Process the result
  4. Repeat until solved
""")

# ============================================================================
# Define Tools
# ============================================================================

defmodule DemoTools do
  def search(_ctx, %{"query" => query}) do
    IO.puts("  [Search: #{query}]")

    q = String.downcase(query)
    cond do
      String.contains?(q, "lewis hamilton") && String.contains?(q, "age") ->
        "Lewis Hamilton was born January 7, 1985. As of 2024, he is 39 years old."

      String.contains?(q, "lewis hamilton") && String.contains?(q, "champion") ->
        "Lewis Hamilton has won 7 F1 World Championships (2008, 2014, 2015, 2017, 2018, 2019, 2020)."

      String.contains?(q, "elixir") ->
        "Elixir is a functional programming language created by Jose Valim in 2011."

      String.contains?(q, "phoenix") ->
        "Phoenix is a web framework for Elixir, known for real-time features via channels."

      true ->
        "No specific information found. Try a different query."
    end
  end

  def calculate(_ctx, %{"expression" => expr}) do
    IO.puts("  [Calculate: #{expr}]")
    try do
      {result, _} = Code.eval_string(expr)
      "#{expr} = #{result}"
    rescue
      _ -> "Error evaluating: #{expr}"
    end
  end
end

# ============================================================================
# Method 1: Basic Agent with ReAct-style Instructions
# ============================================================================

IO.puts("--- Method 1: Manual ReAct Pattern ---\n")

agent = Nous.new("lmstudio:qwen3",
  instructions: """
  You solve problems by thinking step by step.

  For each step:
  1. State what you need to find out
  2. Use a tool to get information
  3. Process the result
  4. Continue until you have the answer

  Available tools: search (look up facts), calculate (do math)
  """,
  tools: [
    &DemoTools.search/2,
    &DemoTools.calculate/2
  ]
)

question = "How old is Lewis Hamilton, and how many F1 championships has he won?"
IO.puts("Question: #{question}\n")

{:ok, result} = Nous.run(agent, question)

IO.puts("\nAnswer: #{result.output}")
IO.puts("Tool calls: #{result.usage.tool_calls}")
IO.puts("")

# ============================================================================
# Method 2: ReActAgent Module (v0.8.0)
# ============================================================================

IO.puts("--- Method 2: ReActAgent Module ---\n")

# ReActAgent adds built-in tools: plan, note, todo, final_answer
react_agent = Nous.ReActAgent.new("lmstudio:qwen3",
  tools: [
    &DemoTools.search/2,
    &DemoTools.calculate/2
  ]
)

IO.puts("ReActAgent includes additional reasoning tools:")
IO.puts("  - plan: Outline approach before starting")
IO.puts("  - note: Record observations")
IO.puts("  - todo: Track remaining steps")
IO.puts("  - final_answer: Conclude with the answer\n")

question2 = "What year was Elixir created, and how many years ago was that?"
IO.puts("Question: #{question2}\n")

{:ok, result2} = Nous.run(react_agent, question2)

IO.puts("\nAnswer: #{result2.output}")
IO.puts("Tool calls: #{result2.usage.tool_calls}")
IO.puts("Iterations: #{result2.usage.iterations || 1}")

# ============================================================================
# When to Use ReAct
# ============================================================================

IO.puts("""

--- When to Use ReAct ---

Good for:
  - Multi-step research questions
  - Problems requiring information gathering
  - Tasks with intermediate calculations
  - Complex reasoning chains

Not needed for:
  - Simple Q&A
  - Single-tool tasks
  - Direct knowledge queries

Benefits:
  - More transparent reasoning
  - Better error recovery
  - Reduced hallucination (grounded in tool results)
  - Self-correcting behavior
""")

IO.puts("Next: See providers/ for provider-specific examples")

#!/usr/bin/env elixir

# Enhanced ReAct Agent Demo - Shows structured planning and todo management
#
# This demonstrates the full ReActAgent module with:
# - Structured planning
# - Built-in todo list management
# - Note-taking for observations
# - Loop prevention
# - Explicit task completion

IO.puts("\n🧠 Yggdrasil AI - Enhanced ReAct Agent Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("ReAct Agent with Built-in Planning & Todo Management")
IO.puts("Based on: ReAct paper + HuggingFace smolagents patterns")
IO.puts("")

alias Yggdrasil.ReActAgent

# Custom domain tools (same as before)
defmodule KnowledgeTools do
  @moduledoc """
  Simulated knowledge base for the demo.
  """

  @doc "Search for information in the knowledge base"
  def search(_ctx, %{"query" => query}) do
    IO.puts("  🔍 SEARCH: \"#{query}\"")

    q = String.downcase(query)

    result = cond do
      String.match?(q, ~r/oldest.*(f1|formula).*driver/) ->
        "As of 2024, Fernando Alonso (43 years old) is the oldest active Formula 1 driver."

      String.match?(q, ~r/fernando alonso.*championship/) or String.match?(q, ~r/alonso.*first.*championship/) ->
        "Fernando Alonso won his first Formula 1 World Championship in 2005 with Renault."

      String.match?(q, ~r/current year|what year/) ->
        "The current year is 2024."

      String.match?(q, ~r/fernando alonso.*(age|old)/) ->
        "Fernando Alonso was born on July 29, 1981. As of 2024, he is 43 years old."

      true ->
        "No specific information found for: #{query}. Try rephrasing your query."
    end

    IO.puts("  ✓ Found: #{String.slice(result, 0..80)}#{if String.length(result) > 80, do: "...", else: ""}")
    result
  end

  @doc "Perform mathematical calculations"
  def calculate(_ctx, %{"expression" => expr}) do
    IO.puts("  🧮 CALCULATE: #{expr}")

    result = try do
      {value, _} = Code.eval_string(expr)
      value
    rescue
      _ -> "Error: Could not evaluate expression"
    end

    IO.puts("  ✓ Result: #{result}")
    result
  end
end

IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Create ReAct agent with custom tools
# The agent automatically includes: plan, note, add_todo, complete_todo, list_todos, final_answer
agent = ReActAgent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful research assistant that solves problems systematically.
  Always start with a plan, break work into todos, and document your findings.
  """,
  tools: [
    &KnowledgeTools.search/2,
    &KnowledgeTools.calculate/2
  ],
  model_settings: %{
    temperature: 0.3,
    max_tokens: 3000
  }
)

total_tools = length(agent.tools)
IO.puts("Agent created with #{total_tools} tools:")
IO.puts("  Built-in ReAct tools: plan, note, add_todo, complete_todo, list_todos, final_answer")
IO.puts("  Custom tools: search, calculate")
IO.puts("")

IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Complex multi-step question
question = """
Who is the oldest current Formula 1 driver, in what year did they win their
first championship, and how many years ago was that from now?

Please work through this systematically:
1. Create a plan first
2. Add todos for each major step
3. Complete todos as you finish them
4. Provide a final answer
"""

IO.puts("QUESTION:")
IO.puts(question)
IO.puts("")
IO.puts("-" |> String.duplicate(70))
IO.puts("")
IO.puts("AGENT WORKFLOW:")
IO.puts("(Watch as the agent plans, creates todos, and works through them)")
IO.puts("")

# Run the agent with increased max iterations
case ReActAgent.run(agent, question, max_iterations: 20) do
  {:ok, result} ->
    IO.puts("")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("")
    IO.puts("✅ FINAL RESULT:")
    IO.puts(result.output)

    IO.puts("")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("")

    IO.puts("📊 Agent Statistics:")
    IO.puts("  Tool calls: #{result.usage.tool_calls}")
    IO.puts("  Total tokens: #{result.usage.total_tokens}")
    IO.puts("  Requests: #{result.usage.requests}")

    if result.metadata do
      IO.puts("")
      IO.puts("📋 ReAct Metadata:")
      IO.puts("  Todos completed: #{result.metadata[:todos_completed] || 0}")
      IO.puts("  Todos pending: #{result.metadata[:todos_pending] || 0}")
      IO.puts("  Plans created: #{result.metadata[:plans_count] || 0}")
      IO.puts("  Notes recorded: #{result.metadata[:notes_count] || 0}")
    end

  {:error, error} ->
    IO.puts("")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("")
    IO.puts("❌ ERROR:")
    IO.puts(Exception.message(error))
    IO.puts("")
    IO.puts("Note: The agent may need more iterations or better guidance.")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("🎓 Enhanced ReAct Agent Features:")
IO.puts("")
IO.puts("✓ Structured Planning")
IO.puts("  - Facts survey (known, to look up, to derive)")
IO.puts("  - Step-by-step action planning")
IO.puts("")
IO.puts("✓ Built-in Todo Management")
IO.puts("  - add_todo: Track subtasks")
IO.puts("  - complete_todo: Mark progress")
IO.puts("  - list_todos: Monitor status")
IO.puts("")
IO.puts("✓ Observation Tracking")
IO.puts("  - note: Document findings")
IO.puts("  - Context preserved across tool calls")
IO.puts("")
IO.puts("✓ Explicit Completion")
IO.puts("  - final_answer: Required to finish")
IO.puts("  - Prevents ambiguous endings")
IO.puts("")
IO.puts("✓ Loop Prevention")
IO.puts("  - Tracks tool call history")
IO.puts("  - Warns on duplicate calls")
IO.puts("")
IO.puts("Based on:")
IO.puts("  • 'ReAct: Synergizing Reasoning and Acting in Language Models' (Yao et al., 2023)")
IO.puts("  • HuggingFace smolagents toolcalling_agent.yaml patterns")
IO.puts("")

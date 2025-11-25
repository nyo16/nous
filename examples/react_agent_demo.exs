#!/usr/bin/env elixir

# ReAct Agent Demo - Demonstrates the Reasoning and Acting pattern
#
# ReAct is a prompting paradigm that combines:
# - Reasoning: Thinking through what to do next
# - Acting: Taking actions using tools
# - Observing: Using tool results to inform next steps
#
# This creates a loop: Thought → Action → Observation → Thought → ...

IO.puts("\n🧠 Yggdrasil AI - ReAct Agent Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("ReAct = Reasoning + Acting")
IO.puts("The agent will interleave thoughts and actions to solve complex problems")
IO.puts("")

defmodule ReActTools do
  @moduledoc """
  Tools for the ReAct agent to use.
  These simulate information retrieval and calculation.
  """

  @doc "Search for information (simulated knowledge base)"
  def search(_ctx, %{"query" => query}) do
    IO.puts("  🔍 SEARCH: \"#{query}\"")

    q = String.downcase(query)

    result = cond do
      String.match?(q, ~r/lewis hamilton.*(age|old)/) or String.match?(q, ~r/how old.*lewis hamilton/) ->
        "Lewis Hamilton was born on January 7, 1985. As of 2024, he is 39 years old."

      String.match?(q, ~r/lewis hamilton.*championship/) ->
        "Lewis Hamilton has won 7 Formula 1 World Championships (2008, 2014, 2015, 2017, 2018, 2019, 2020)."

      String.match?(q, ~r/fernando alonso.*(age|old)/) or String.match?(q, ~r/how old.*fernando alonso/) ->
        "Fernando Alonso was born on July 29, 1981. As of 2024, he is 43 years old."

      String.match?(q, ~r/fernando alonso.*championship/) ->
        "Fernando Alonso has won 2 Formula 1 World Championships (2005, 2006)."

      String.match?(q, ~r/oldest.*(f1|formula).*driver/) ->
        "As of 2024, Fernando Alonso (43 years old) is the oldest active Formula 1 driver."

      String.match?(q, ~r/current year|what year/) ->
        "The current year is 2024."

      true ->
        "No specific information found for: #{query}. Try rephrasing or being more specific."
    end

    IO.puts("  ✓ Found: #{String.slice(result, 0..80)}#{if String.length(result) > 80, do: "...", else: ""}")
    result
  end

  @doc "Perform mathematical calculations"
  def calculate(_ctx, %{"expression" => expr}) do
    IO.puts("  🧮 CALCULATE: #{expr}")

    result = try do
      # Simple expression evaluator
      {value, _} = Code.eval_string(expr)
      value
    rescue
      _ -> "Error: Could not evaluate expression"
    end

    IO.puts("  ✓ Result: #{result}")
    result
  end

  @doc "Take notes during reasoning (helps agent track information)"
  def note(_ctx, %{"content" => content}) do
    IO.puts("  📝 NOTE: #{content}")
    "Note recorded: #{content}"
  end
end

# Create a ReAct agent with explicit instructions for the ReAct pattern
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a ReAct (Reasoning + Acting) agent. You solve problems by:

  1. THOUGHT: Think about what you need to know
  2. ACTION: Use a tool to get information or calculate
  3. OBSERVATION: Process the result
  4. Repeat until you have the answer

  Available tools:
  - search: Look up factual information
  - calculate: Perform mathematical operations
  - note: Record important facts

  Always explicitly state your reasoning before each action.
  Work step by step.
  """,
  tools: [
    &ReActTools.search/2,
    &ReActTools.calculate/2,
    &ReActTools.note/2
  ],
  model_settings: %{
    temperature: 0.3,  # Lower temperature for more focused reasoning
    max_tokens: 2000
  }
)

IO.puts("Agent created with #{length(agent.tools)} tools")
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Complex question that requires multiple reasoning steps
question = """
Who is the oldest current Formula 1 driver, and in what year did they win
their first championship? How many years ago was that from now?
"""

IO.puts("QUESTION:")
IO.puts(question)
IO.puts("")
IO.puts("-" |> String.duplicate(70))
IO.puts("")
IO.puts("AGENT REASONING AND ACTIONS:")
IO.puts("")

{:ok, result} = Yggdrasil.run(agent, question)

IO.puts("")
IO.puts("-" |> String.duplicate(70))
IO.puts("")
IO.puts("✅ FINAL ANSWER:")
IO.puts(result.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("📊 Agent Statistics:")
IO.puts("  Tool calls: #{result.usage.tool_calls}")
IO.puts("  Total tokens: #{result.usage.total_tokens}")
IO.puts("  Requests: #{result.usage.requests}")

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("🎓 What is ReAct?")
IO.puts("")
IO.puts("ReAct (Reasoning and Acting) is a paradigm where AI agents:")
IO.puts("  • Think about what they need to know (REASONING)")
IO.puts("  • Take actions using tools (ACTING)")
IO.puts("  • Observe and process results (OBSERVATION)")
IO.puts("  • Iterate until solving the problem")
IO.puts("")
IO.puts("Benefits:")
IO.puts("  ✓ More transparent decision making")
IO.puts("  ✓ Better handling of complex multi-step problems")
IO.puts("  ✓ Ability to course-correct based on observations")
IO.puts("  ✓ Reduces hallucinations by grounding in tool results")
IO.puts("")
IO.puts("Paper: 'ReAct: Synergizing Reasoning and Acting in Language Models'")
IO.puts("       by Yao et al. (2023)")
IO.puts("")

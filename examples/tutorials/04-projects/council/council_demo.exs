#!/usr/bin/env elixir

# LLM Council Demo
#
# This demonstrates a multi-LLM deliberation system where multiple models
# collaborate to answer questions through a 3-stage process:
#
# Stage 1: Each council member responds independently
# Stage 2: Members rank each other's responses (anonymized)
# Stage 3: A Chairman synthesizes the final answer
#
# Prerequisites:
# - LM Studio running at http://localhost:1234
# - A model loaded (e.g., qwen/qwen3-4b-2507)
#
# Run with:
#   cd examples/council
#   elixir council_demo.exs

# Load dependencies
Code.require_file("council.ex", __DIR__)

Mix.install([
  {:nous, path: "../.."}
])

IO.puts("""

╔══════════════════════════════════════════════════════════════════════════════╗
║                           LLM COUNCIL DEMO                                   ║
║                                                                              ║
║  Multiple LLMs collaborate through debate and synthesis                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
""")

# Configuration
base_url = System.get_env("LLM_BASE_URL", "http://localhost:1234/v1")
model_name = System.get_env("LLM_MODEL", "qwen/qwen3-4b-2507")

IO.puts("Configuration:")
IO.puts("  Base URL: #{base_url}")
IO.puts("  Model: #{model_name}")
IO.puts("")

# Define council members with different "personalities"
# Even with the same underlying model, different system prompts create diverse perspectives
council_models = [
  {"lmstudio:#{model_name}", "The Analyst - focuses on facts, data, and logical reasoning"},
  {"lmstudio:#{model_name}", "The Skeptic - questions assumptions and looks for flaws"},
  {"lmstudio:#{model_name}", "The Creative - thinks outside the box and offers novel perspectives"}
]

chairman_model = "lmstudio:#{model_name}"

IO.puts("Council Members:")
for {_model, role} <- council_models do
  IO.puts("  • #{role}")
end
IO.puts("\nChairman: #{chairman_model}")
IO.puts("")

# Create the council
council = Council.new(
  council_models: council_models,
  chairman_model: chairman_model,
  base_url: base_url,
  api_key: "not-needed",
  model_settings: %{
    temperature: 0.7,
    max_tokens: 1024
  }
)

# The question to deliberate
question = """
What are the most important factors to consider when designing a distributed system?
Provide specific recommendations.
"""

IO.puts(String.duplicate("═", 80))
IO.puts("QUESTION:")
IO.puts(String.duplicate("═", 80))
IO.puts(question)
IO.puts("")

# Run the council deliberation
start_time = System.monotonic_time(:millisecond)

case Council.deliberate(council, question) do
  {:ok, result} ->
    duration = System.monotonic_time(:millisecond) - start_time

    # Display Stage 1 Results
    IO.puts("\n" <> String.duplicate("═", 80))
    IO.puts("STAGE 1 RESULTS: Individual Responses")
    IO.puts(String.duplicate("═", 80))

    for resp <- result.stage1 do
      IO.puts("\n┌─ #{resp.role}")
      IO.puts("│  Model: #{resp.model}")
      IO.puts("├" <> String.duplicate("─", 78))
      resp.response
      |> String.split("\n")
      |> Enum.each(fn line -> IO.puts("│ #{line}") end)
      IO.puts("└" <> String.duplicate("─", 78))
    end

    # Display Stage 2 Results
    IO.puts("\n" <> String.duplicate("═", 80))
    IO.puts("STAGE 2 RESULTS: Peer Rankings")
    IO.puts(String.duplicate("═", 80))

    IO.puts("\nLabel Mapping (for reference):")
    for {label, member} <- result.metadata.label_to_member do
      IO.puts("  #{label} → #{member.role}")
    end

    IO.puts("\nRankings by each member:")
    for ranking <- result.stage2 do
      IO.puts("\n┌─ #{ranking.role}'s Ranking")
      IO.puts("│  Parsed: #{inspect(ranking.parsed_ranking)}")
      IO.puts("├" <> String.duplicate("─", 78))
      ranking.ranking
      |> String.split("\n")
      |> Enum.take(20)  # Limit output
      |> Enum.each(fn line -> IO.puts("│ #{line}") end)
      IO.puts("└" <> String.duplicate("─", 78))
    end

    # Display Aggregate Rankings
    IO.puts("\n" <> String.duplicate("═", 80))
    IO.puts("AGGREGATE RANKINGS (Combined Peer Scores)")
    IO.puts(String.duplicate("═", 80))

    for {agg, position} <- Enum.with_index(result.metadata.aggregate_rankings, 1) do
      IO.puts("  ##{position}. #{agg.role}")
      IO.puts("      Average Rank: #{agg.average_rank} (from #{agg.rankings_count} votes)")
    end

    # Display Stage 3 Results
    IO.puts("\n" <> String.duplicate("═", 80))
    IO.puts("STAGE 3 RESULT: Chairman's Final Synthesis")
    IO.puts(String.duplicate("═", 80))
    IO.puts("\nChairman: #{result.stage3.model}")
    IO.puts("")
    IO.puts(result.stage3.response)

    # Summary
    IO.puts("\n" <> String.duplicate("═", 80))
    IO.puts("SUMMARY")
    IO.puts(String.duplicate("═", 80))
    IO.puts("  Total duration: #{duration}ms")
    IO.puts("  Council members: #{length(result.stage1)}")
    IO.puts("  Rankings collected: #{length(result.stage2)}")
    IO.puts("  Stages completed: 3")
    IO.puts("")

  {:error, reason} ->
    IO.puts("\n[ERROR] Council deliberation failed!")
    IO.puts("        Reason: #{inspect(reason)}")
    IO.puts("")
    IO.puts("Make sure LM Studio is running at #{base_url}")
    IO.puts("with a model loaded.")
end

IO.puts("""

╔══════════════════════════════════════════════════════════════════════════════╗
║                           DEMO COMPLETE                                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
""")

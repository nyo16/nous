#!/usr/bin/env elixir

# Nous Workflow — Parallel Analysis
#
# Multiple specialist agents analyze the same input concurrently,
# then results are merged and a final agent synthesizes them.
#
# Demonstrates: parallel (static branches), parallel_map (dynamic),
#               deep_merge, error handling with continue_others
#
# Run: TEST_MODEL="lmstudio:qwen3.5-27b" mix run examples/workflow/parallel_analysis.exs

alias Nous.Workflow

model = System.get_env("TEST_MODEL", "lmstudio:qwen3.5-9b-mlx")
IO.puts("=== Parallel Analysis ===\nModel: #{model}\n")

# -------------------------------------------------------------------------
# Part 1: Dynamic parallel — analyze multiple texts concurrently
# -------------------------------------------------------------------------

IO.puts("--- Part 1: Dynamic Parallel (parallel_map) ---")

analyst =
  Nous.Agent.new(model,
    instructions:
      "You are a sentiment analyst. Given a text, respond with exactly one word: positive, negative, or neutral."
  )

texts = [
  "I absolutely love this product, it changed my life!",
  "The service was terrible, I want a refund immediately.",
  "The package arrived on Tuesday as expected.",
  "This is the worst experience I've ever had.",
  "Pretty good overall, would recommend to friends."
]

graph =
  Workflow.new("batch_sentiment")
  |> Workflow.add_node(:setup, :transform, %{
    transform_fn: fn data -> Map.put(data, :texts, texts) end
  })
  |> Workflow.add_node(:analyze, :parallel_map, %{
    items: fn state -> state.data.texts end,
    handler: fn text, _state ->
      {:ok, result} = Nous.AgentRunner.run(analyst, "Analyze sentiment: #{text}")
      String.trim(result.output) |> String.downcase()
    end,
    max_concurrency: 3,
    result_key: :sentiments
  })
  |> Workflow.add_node(:summarize, :transform, %{
    transform_fn: fn data ->
      results = Enum.zip(data.texts, data.sentiments)
      IO.puts("  Results:")

      Enum.each(results, fn {text, sentiment} ->
        IO.puts("    [#{sentiment}] #{String.slice(text, 0, 50)}...")
      end)

      counts = Enum.frequencies(data.sentiments)
      Map.put(data, :sentiment_counts, counts)
    end
  })
  |> Workflow.chain([:setup, :analyze, :summarize])

{:ok, state} = Workflow.run(graph, %{}, trace: true)
IO.puts("  Counts: #{inspect(state.data.sentiment_counts)}")

trace = state.metadata.trace

IO.puts(
  "  Timing: analyze=#{Enum.find(trace.entries, &(&1.node_id == "analyze")).duration_ms}ms\n"
)

# -------------------------------------------------------------------------
# Part 2: Static parallel — multiple specialist agents, deep merge
# -------------------------------------------------------------------------

IO.puts("--- Part 2: Static Parallel (named branches) ---")

topic_agent =
  Nous.Agent.new(model,
    instructions:
      "Extract 3 key topics from the text. Output one topic per line, no numbering. No extra text."
  )

tone_agent =
  Nous.Agent.new(model,
    instructions: "Describe the tone of the text in one word. Output only that word."
  )

input_text =
  "Elixir leverages the Erlang VM for building distributed, fault-tolerant applications. Its elegant syntax and powerful concurrency model make it a joy to work with for backend systems."

graph =
  Workflow.new("multi_analyst")
  |> Workflow.add_node(:fan_out, :parallel, %{
    branches: [:topics, :tone],
    merge: :deep_merge
  })
  |> Workflow.add_node(:topics, :agent_step, %{
    agent: topic_agent,
    prompt: fn _state -> "Extract topics from: #{input_text}" end,
    result_key: :extracted_topics
  })
  |> Workflow.add_node(:tone, :agent_step, %{
    agent: tone_agent,
    prompt: fn _state -> "What is the tone of: #{input_text}" end,
    result_key: :detected_tone
  })
  |> Workflow.add_node(:report, :transform, %{
    transform_fn: fn data ->
      IO.puts("  Topics: #{data[:extracted_topics]}")
      IO.puts("  Tone: #{data[:detected_tone]}")
      data
    end
  })
  |> Workflow.connect(:fan_out, :report)

{:ok, _state} = Workflow.run(graph)
IO.puts("\n=== Done ===")

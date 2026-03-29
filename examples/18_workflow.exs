#!/usr/bin/env elixir

# Nous AI - Workflow Engine
# Compose agents, tools, and control flow as executable directed graphs.
#
# The Workflow module provides an Ecto.Multi-style builder API for defining
# DAG-based workflows with branching, parallel execution, cycles, and
# human-in-the-loop checkpoints.
#
# Prerequisites:
#   - LM Studio running at localhost:1234 (or set LMSTUDIO_BASE_URL)
#   - A model loaded in LM Studio
#
# Run: mix run examples/18_workflow.exs

alias Nous.Workflow
alias Nous.Workflow.Graph

IO.puts("=== Nous AI - Workflow Engine Demo ===\n")

# ============================================================================
# Example 1: Linear Pipeline with Transform Nodes
# ============================================================================
#
# The simplest workflow: a chain of transform nodes that process data
# step by step. No LLM calls needed — pure data transformation.

IO.puts("--- Example 1: Linear Data Pipeline ---")

graph =
  Workflow.new("data_pipeline")
  |> Workflow.add_node(:ingest, :transform, %{
    transform_fn: fn data ->
      Map.put(data, :raw, "The quick brown fox jumps over the lazy dog")
    end
  })
  |> Workflow.add_node(:clean, :transform, %{
    transform_fn: fn data ->
      Map.put(data, :cleaned, String.downcase(data.raw) |> String.trim())
    end
  })
  |> Workflow.add_node(:analyze, :transform, %{
    transform_fn: fn data ->
      words = String.split(data.cleaned)

      Map.merge(data, %{word_count: length(words), unique_words: words |> Enum.uniq() |> length()})
    end
  })
  |> Workflow.chain([:ingest, :clean, :analyze])

{:ok, state} = Workflow.run(graph)

IO.puts("  Words: #{state.data.word_count}, Unique: #{state.data.unique_words}")
IO.puts("  Node results: #{inspect(Map.keys(state.node_results))}\n")

# ============================================================================
# Example 2: Branching with Quality Gate
# ============================================================================
#
# A workflow with conditional branching. The branch node evaluates the
# state and routes to different paths.

IO.puts("--- Example 2: Conditional Branching ---")

graph =
  Workflow.new("quality_gate")
  |> Workflow.add_node(:score, :transform, %{
    transform_fn: fn data -> Map.put(data, :quality, 0.9) end
  })
  |> Workflow.add_node(:check, :branch, %{})
  |> Workflow.add_node(:publish, :transform, %{
    transform_fn: fn data -> Map.put(data, :action, "published!") end
  })
  |> Workflow.add_node(:revise, :transform, %{
    transform_fn: fn data -> Map.put(data, :action, "needs revision") end
  })
  |> Workflow.connect(:score, :check)
  |> Workflow.connect(:check, :publish, condition: fn s -> s.data.quality >= 0.8 end)
  |> Workflow.connect(:check, :revise, condition: fn s -> s.data.quality < 0.8 end)

{:ok, state} = Workflow.run(graph)
IO.puts("  Quality: #{state.data.quality} → #{state.data.action}\n")

# ============================================================================
# Example 3: Dynamic Parallel Fan-Out
# ============================================================================
#
# parallel_map discovers items at runtime and processes them concurrently.
# This is the scatter-gather pattern — great for fetching multiple URLs,
# processing batch items, etc.

IO.puts("--- Example 3: Dynamic Parallel Map ---")

graph =
  Workflow.new("parallel_demo")
  |> Workflow.add_node(:discover, :transform, %{
    transform_fn: fn data ->
      Map.put(data, :items, ["alpha", "beta", "gamma", "delta"])
    end
  })
  |> Workflow.add_node(:process, :parallel_map, %{
    items: fn state -> state.data.items end,
    handler: fn item, _state ->
      # Simulate processing — in real use, this could be an LLM call or API request
      Process.sleep(Enum.random(10..50))
      String.upcase(item)
    end,
    max_concurrency: 4,
    result_key: :processed
  })
  |> Workflow.add_node(:summarize, :transform, %{
    transform_fn: fn data ->
      Map.put(
        data,
        :summary,
        "Processed #{length(data.processed)} items: #{Enum.join(data.processed, ", ")}"
      )
    end
  })
  |> Workflow.chain([:discover, :process, :summarize])

{:ok, state} = Workflow.run(graph)
IO.puts("  #{state.data.summary}\n")

# ============================================================================
# Example 4: Subworkflow Composition
# ============================================================================
#
# Nest workflows inside other workflows. Each subworkflow runs in isolation
# with input/output mappers controlling data flow.

IO.puts("--- Example 4: Subworkflow Composition ---")

# Inner workflow: processes a single item
inner =
  Graph.new("processor")
  |> Graph.add_node(:process, :transform, %{
    transform_fn: fn data ->
      Map.put(data, :result, "processed(#{data.input})")
    end
  })

# Outer workflow: sets up data, runs inner, uses result
outer =
  Workflow.new("composed")
  |> Workflow.add_node(:setup, :transform, %{
    transform_fn: fn data -> Map.put(data, :raw_input, "hello world") end
  })
  |> Workflow.add_node(:sub, :subworkflow, %{
    workflow: inner,
    input_mapper: fn data -> %{input: data.raw_input} end,
    output_mapper: fn data -> %{processed_output: data.result} end
  })
  |> Workflow.add_node(:done, :transform, %{
    transform_fn: fn data -> Map.put(data, :final, "Got: #{data.processed_output}") end
  })
  |> Workflow.chain([:setup, :sub, :done])

{:ok, state} = Workflow.run(outer)
IO.puts("  #{state.data.final}\n")

# ============================================================================
# Example 5: Execution Trace
# ============================================================================
#
# Enable tracing to record timing and status for every node execution.
# Useful for debugging and performance analysis.

IO.puts("--- Example 5: Execution Trace ---")

graph =
  Workflow.new("traced_pipeline")
  |> Workflow.add_node(:step1, :transform, %{transform_fn: fn d -> Map.put(d, :s1, true) end})
  |> Workflow.add_node(:step2, :transform, %{
    transform_fn: fn d ->
      Process.sleep(10)
      Map.put(d, :s2, true)
    end
  })
  |> Workflow.add_node(:step3, :transform, %{transform_fn: fn d -> Map.put(d, :s3, true) end})
  |> Workflow.chain([:step1, :step2, :step3])

{:ok, state} = Workflow.run(graph, %{}, trace: true)

trace = state.metadata.trace
IO.puts("  Run ID: #{trace.run_id}")
IO.puts("  Total nodes: #{Nous.Workflow.Trace.node_count(trace)}")

for entry <- trace.entries do
  IO.puts("    #{entry.node_id} (#{entry.node_type}): #{entry.status} in #{entry.duration_ms}ms")
end

IO.puts("")

# ============================================================================
# Example 6: Mermaid Visualization
# ============================================================================
#
# Generate a Mermaid diagram to visualize any workflow graph.
# Paste the output into a Mermaid renderer (GitHub markdown, mermaid.live).

IO.puts("--- Example 6: Mermaid Diagram ---")

graph =
  Workflow.new("research")
  |> Workflow.add_node(:plan, :agent_step, %{agent: nil}, label: "Plan Research")
  |> Workflow.add_node(:search, :parallel, %{branches: [:web, :papers]}, label: "Search Sources")
  |> Workflow.add_node(:web, :transform, %{transform_fn: &Function.identity/1},
    label: "Web Search"
  )
  |> Workflow.add_node(:papers, :transform, %{transform_fn: &Function.identity/1},
    label: "Paper Search"
  )
  |> Workflow.add_node(:synthesize, :agent_step, %{agent: nil}, label: "Synthesize")
  |> Workflow.add_node(:review, :human_checkpoint, %{}, label: "Human Review")
  |> Workflow.add_node(:report, :agent_step, %{agent: nil}, label: "Final Report")
  |> Workflow.connect(:plan, :search)
  |> Workflow.connect(:search, :synthesize)
  |> Workflow.connect(:synthesize, :review)
  |> Workflow.connect(:review, :report)

IO.puts("```mermaid")
IO.puts(Workflow.to_mermaid(graph))
IO.puts("```")

IO.puts("\n=== Workflow Engine Demo Complete ===")

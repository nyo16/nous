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

model = System.get_env("TEST_MODEL", "lmstudio:qwen3.5-9b-mlx")

IO.puts("=== Nous AI - Workflow Engine Demo ===")
IO.puts("Using model: #{model}\n")

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

IO.puts("  Words: #{state.data.word_count}, Unique: #{state.data.unique_words}\n")

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
IO.puts("  Quality: #{state.data.quality} -> #{state.data.action}\n")

# ============================================================================
# Example 3: Dynamic Parallel Fan-Out
# ============================================================================
#
# parallel_map discovers items at runtime and processes them concurrently.
# This is the scatter-gather pattern.

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
# Example 4: Static Parallel Branches
# ============================================================================
#
# Named branches run concurrently, results are deep-merged back.
# Each branch is an independent node executed in parallel.

IO.puts("--- Example 4: Static Parallel Branches ---")

graph =
  Workflow.new("multi_source")
  |> Workflow.add_node(:fan_out, :parallel, %{
    branches: [:analysis_a, :analysis_b],
    merge: :deep_merge
  })
  |> Workflow.add_node(:analysis_a, :transform, %{
    transform_fn: fn _data -> %{sentiment: "positive", confidence: 0.85} end
  })
  |> Workflow.add_node(:analysis_b, :transform, %{
    transform_fn: fn _data -> %{topics: ["elixir", "agents", "workflow"], count: 3} end
  })
  |> Workflow.add_node(:combine, :transform, %{
    transform_fn: fn data ->
      Map.put(data, :report, "Sentiment: #{data.sentiment}, Topics: #{data.count}")
    end
  })
  |> Workflow.connect(:fan_out, :combine)

{:ok, state} = Workflow.run(graph)
IO.puts("  #{state.data.report}\n")

# ============================================================================
# Example 5: Cycle / Retry Loop
# ============================================================================
#
# A workflow that loops until a quality threshold is met, with a max
# iteration guard to prevent infinite loops.

IO.puts("--- Example 5: Cycle with Quality Gate ---")

graph =
  Graph.new("retry_loop", allows_cycles: true)
  |> Graph.add_node(:init, :transform, %{
    transform_fn: fn data -> Map.put(data, :quality, 0) end
  })
  |> Graph.add_node(:improve, :transform, %{
    transform_fn: fn data ->
      new_q = data.quality + 0.35
      IO.puts("    Iteration: quality #{Float.round(new_q, 2)}")
      Map.put(data, :quality, new_q)
    end
  })
  |> Graph.add_node(:check, :branch, %{})
  |> Graph.add_node(:done, :transform, %{
    transform_fn: fn data -> Map.put(data, :converged, true) end
  })
  |> Graph.connect(:init, :improve)
  |> Graph.connect(:improve, :check)
  |> Graph.connect(:check, :done, condition: fn s -> s.data.quality >= 1.0 end)
  |> Graph.connect(:check, :improve, condition: fn s -> s.data.quality < 1.0 end)

{:ok, state} = Workflow.run(graph, %{}, max_iterations: 10)

IO.puts(
  "  Final quality: #{Float.round(state.data.quality, 2)}, converged: #{state.data.converged}\n"
)

# ============================================================================
# Example 6: Human-in-the-Loop Checkpoint
# ============================================================================
#
# A human_checkpoint node pauses for review. With a handler function,
# it can approve, edit, or reject the workflow.

IO.puts("--- Example 6: Human-in-the-Loop ---")

# 6a: Auto-approve handler
graph =
  Workflow.new("hitl_approve")
  |> Workflow.add_node(:generate, :transform, %{
    transform_fn: fn data -> Map.put(data, :draft, "This is a draft report.") end
  })
  |> Workflow.add_node(:review, :human_checkpoint, %{
    prompt: "Review this draft before publishing",
    handler: fn state, prompt ->
      IO.puts("    [HITL] Prompt: #{prompt}")
      IO.puts("    [HITL] Draft: #{state.data.draft}")
      IO.puts("    [HITL] Decision: APPROVED")
      :approve
    end
  })
  |> Workflow.add_node(:publish, :transform, %{
    transform_fn: fn data -> Map.put(data, :published, true) end
  })
  |> Workflow.chain([:generate, :review, :publish])

{:ok, state} = Workflow.run(graph)
IO.puts("  Published: #{state.data.published}")

# 6b: Edit handler — modifies state before continuing
graph =
  Workflow.new("hitl_edit")
  |> Workflow.add_node(:generate, :transform, %{
    transform_fn: fn data -> Map.put(data, :draft, "rough draft") end
  })
  |> Workflow.add_node(:review, :human_checkpoint, %{
    handler: fn state, _prompt ->
      IO.puts("    [HITL] Editing draft: '#{state.data.draft}' -> 'polished version'")
      {:edit, Nous.Workflow.State.update_data(state, &Map.put(&1, :draft, "polished version"))}
    end
  })
  |> Workflow.add_node(:finish, :transform, %{transform_fn: &Function.identity/1})
  |> Workflow.chain([:generate, :review, :finish])

{:ok, state} = Workflow.run(graph)
IO.puts("  Final draft: #{state.data.draft}")

# 6c: Suspend (no handler) — workflow pauses and returns checkpoint
graph =
  Workflow.new("hitl_suspend")
  |> Workflow.add_node(:work, :transform, %{
    transform_fn: fn data -> Map.put(data, :done, true) end
  })
  |> Workflow.add_node(:await_human, :human_checkpoint, %{prompt: "Waiting for approval..."})
  |> Workflow.chain([:work, :await_human])

{:ok, compiled} = Workflow.compile(graph)

case Nous.Workflow.Engine.execute(compiled) do
  {:suspended, state, checkpoint} ->
    IO.puts("    [HITL] Workflow suspended at node: #{checkpoint.node_id}")
    IO.puts("    [HITL] State preserved: done=#{state.data.done}")

  {:ok, _} ->
    IO.puts("    (completed)")
end

IO.puts("")

# ============================================================================
# Example 7: Hooks — Pause and Intercept
# ============================================================================
#
# Hooks let you intercept execution before/after each node.
# A pre_node hook can pause the workflow at any point.

IO.puts("--- Example 7: Workflow Hooks ---")

pre_hook = %Nous.Hook{
  event: :pre_node,
  type: :function,
  handler: fn _event, %{node_id: id, node_type: type} ->
    IO.puts("    [hook] About to execute: #{id} (#{type})")
    :allow
  end
}

post_hook = %Nous.Hook{
  event: :post_node,
  type: :function,
  handler: fn _event, %{node_id: id} ->
    IO.puts("    [hook] Completed: #{id}")
    :allow
  end
}

graph =
  Workflow.new("hooked")
  |> Workflow.add_node(:a, :transform, %{transform_fn: fn d -> Map.put(d, :a, 1) end})
  |> Workflow.add_node(:b, :transform, %{transform_fn: fn d -> Map.put(d, :b, 2) end})
  |> Workflow.chain([:a, :b])

{:ok, _state} = Workflow.run(graph, %{}, hooks: [pre_hook, post_hook])
IO.puts("")

# ============================================================================
# Example 8: Error Strategies
# ============================================================================
#
# Each node can have its own error handling strategy.

IO.puts("--- Example 8: Error Strategies ---")

counter = :counters.new(1, [:atomics])

graph =
  Workflow.new("error_demo")
  |> Workflow.add_node(:safe, :transform, %{
    transform_fn: fn data -> Map.put(data, :step1, "ok") end
  })
  |> Workflow.add_node(
    :flaky,
    :transform,
    %{
      transform_fn: fn data ->
        attempt = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, attempt)

        if attempt < 3,
          do: raise("attempt #{attempt} failed"),
          else: Map.put(data, :step2, "ok after #{attempt} attempts")
      end
    },
    error_strategy: {:retry, 3, 0}
  )
  |> Workflow.add_node(
    :risky,
    :transform,
    %{
      transform_fn: fn _data -> raise "this always fails" end
    },
    error_strategy: :skip
  )
  |> Workflow.add_node(:final, :transform, %{
    transform_fn: fn data -> Map.put(data, :step4, "completed despite errors") end
  })
  |> Workflow.chain([:safe, :flaky, :risky, :final])

{:ok, state} = Workflow.run(graph)
IO.puts("  Step 1: #{state.data.step1}")
IO.puts("  Step 2: #{state.data.step2}")
IO.puts("  Step 4: #{state.data.step4}")
IO.puts("  Errors: #{length(state.errors)} (skipped node recorded)\n")

# ============================================================================
# Example 9: Subworkflow Composition
# ============================================================================

IO.puts("--- Example 9: Subworkflow Composition ---")

inner =
  Graph.new("processor")
  |> Graph.add_node(:process, :transform, %{
    transform_fn: fn data -> Map.put(data, :result, "processed(#{data.input})") end
  })

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
# Example 10: LLM Agent Steps — Real AI Workflow
# ============================================================================
#
# A complete workflow using actual LLM agent steps. Each agent_step
# sends a prompt to the model and gets a response.

IO.puts("--- Example 10: LLM Agent Workflow ---")

researcher =
  Nous.Agent.new(model,
    instructions:
      "You are a concise research assistant. Answer in 2-3 sentences max. Do not use any special formatting."
  )

editor =
  Nous.Agent.new(model,
    instructions:
      "You are an editor. Take the given text and make it more concise — one sentence max. Do not use any special formatting. Output only the edited text."
  )

graph =
  Workflow.new("llm_pipeline")
  |> Workflow.add_node(:research, :agent_step, %{
    agent: researcher,
    prompt: fn state -> "What is #{state.data.topic}? Be very brief." end,
    result_key: :research_output
  })
  |> Workflow.add_node(:log_research, :transform, %{
    transform_fn: fn data ->
      IO.puts("  [Research] #{data.research_output}")
      data
    end
  })
  |> Workflow.add_node(:edit, :agent_step, %{
    agent: editor,
    prompt: fn state -> "Edit this to one sentence: #{state.node_results["research"]}" end,
    result_key: :edited_output
  })
  |> Workflow.add_node(:log_edit, :transform, %{
    transform_fn: fn data ->
      IO.puts("  [Edited]   #{data.edited_output}")
      data
    end
  })
  |> Workflow.chain([:research, :log_research, :edit, :log_edit])

{:ok, state} = Workflow.run(graph, %{topic: "the BEAM virtual machine"}, trace: true)

trace = state.metadata.trace
IO.puts("  Trace:")

for entry <- trace.entries do
  IO.puts("    #{entry.node_id}: #{entry.status} in #{entry.duration_ms}ms")
end

IO.puts("")

# ============================================================================
# Example 11: Parallel LLM Agents
# ============================================================================
#
# Fan out to multiple LLM agents concurrently using parallel_map.
# Each question is answered in parallel by the same model.

IO.puts("--- Example 11: Parallel LLM Agents ---")

answerer =
  Nous.Agent.new(model,
    instructions: "Answer in exactly one sentence. No formatting."
  )

graph =
  Workflow.new("parallel_llm")
  |> Workflow.add_node(:setup, :transform, %{
    transform_fn: fn data ->
      Map.put(data, :questions, [
        "What is Elixir?",
        "What is OTP?",
        "What is the BEAM?"
      ])
    end
  })
  |> Workflow.add_node(:answer_all, :parallel_map, %{
    items: fn state -> state.data.questions end,
    handler: fn question, _state ->
      {:ok, result} = Nous.AgentRunner.run(answerer, question)
      result.output
    end,
    max_concurrency: 3,
    result_key: :answers
  })
  |> Workflow.chain([:setup, :answer_all])

{:ok, state} = Workflow.run(graph)

Enum.zip(state.data.questions, state.data.answers)
|> Enum.each(fn {q, a} ->
  IO.puts("  Q: #{q}")
  IO.puts("  A: #{a}\n")
end)

# ============================================================================
# Example 12: Mermaid Visualization
# ============================================================================

IO.puts("--- Example 12: Mermaid Diagram ---")

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

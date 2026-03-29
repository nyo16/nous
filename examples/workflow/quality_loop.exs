#!/usr/bin/env elixir

# Nous Workflow — Quality Gate with Retry Loop
#
# An LLM generates content, a judge scores it, and the workflow loops
# back to improve until the quality threshold is met or max iterations
# are exhausted.
#
# Demonstrates: cycles (allows_cycles: true), branch, max_iterations,
#               agent_step in a loop
#
# Run: TEST_MODEL="lmstudio:qwen3.5-27b" mix run examples/workflow/quality_loop.exs

alias Nous.Workflow
alias Nous.Workflow.Graph

model = System.get_env("TEST_MODEL", "lmstudio:qwen3.5-9b-mlx")
IO.puts("=== Quality Gate Loop ===\nModel: #{model}\n")

writer =
  Nous.Agent.new(model,
    instructions: """
    You are a technical writer. Write or improve a brief explanation (2-3 sentences)
    of the given topic. If previous feedback is provided, incorporate it.
    Output only the explanation text, no formatting.
    """
  )

graph =
  Graph.new("quality_loop", allows_cycles: true)
  |> Graph.add_node(:init, :transform, %{
    transform_fn: fn data -> Map.merge(data, %{iteration: 0, draft: nil}) end
  })
  |> Graph.add_node(:write, :agent_step, %{
    agent: writer,
    prompt: fn state ->
      base = "Write a brief explanation of: #{state.data.topic}"

      case state.data.draft do
        nil -> base
        prev -> "#{base}\n\nPrevious draft (improve it): #{prev}"
      end
    end,
    result_key: :draft
  })
  |> Graph.add_node(:evaluate, :transform, %{
    transform_fn: fn data ->
      iteration = data.iteration + 1
      draft = data.draft || ""
      # Simple heuristic: score based on length and sentence count
      word_count = draft |> String.split() |> length()
      has_detail = word_count > 20
      score = if has_detail, do: 0.9, else: 0.4

      IO.puts("  Iteration #{iteration}: #{word_count} words, score=#{score}")
      Map.merge(data, %{iteration: iteration, score: score})
    end
  })
  |> Graph.add_node(:check, :branch, %{})
  |> Graph.add_node(:done, :transform, %{
    transform_fn: fn data ->
      IO.puts("  Accepted!")
      Map.put(data, :accepted, true)
    end
  })
  |> Graph.connect(:init, :write)
  |> Graph.connect(:write, :evaluate)
  |> Graph.connect(:evaluate, :check)
  |> Graph.connect(:check, :done, condition: fn s -> s.data.score >= 0.8 end)
  |> Graph.connect(:check, :write, condition: fn s -> s.data.score < 0.8 end)

{:ok, state} = Workflow.run(graph, %{topic: "pattern matching in Elixir"}, max_iterations: 5)

IO.puts("\n=== Final Draft (iteration #{state.data.iteration}) ===")
IO.puts(state.data.draft)

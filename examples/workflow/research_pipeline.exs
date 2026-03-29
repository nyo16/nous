#!/usr/bin/env elixir

# Nous Workflow — Multi-Agent Research Pipeline
#
# A realistic workflow where multiple LLM agents collaborate:
#   1. Planner generates research questions
#   2. Researcher answers each question in parallel
#   3. Synthesizer combines findings into a report
#
# Demonstrates: agent_step, parallel_map, result_key, tracing
#
# Run: TEST_MODEL="lmstudio:qwen3.5-27b" mix run examples/workflow/research_pipeline.exs

alias Nous.Workflow

model = System.get_env("TEST_MODEL", "lmstudio:qwen3.5-9b-mlx")
IO.puts("=== Research Pipeline ===\nModel: #{model}\n")

planner =
  Nous.Agent.new(model,
    instructions:
      "You are a research planner. Given a topic, output exactly 3 focused research questions, one per line. No numbering, no bullets, no extra text."
  )

researcher =
  Nous.Agent.new(model,
    instructions:
      "You are a research specialist. Answer the given question in 2-3 sentences. Be factual and concise. No formatting."
  )

synthesizer =
  Nous.Agent.new(model,
    instructions:
      "You are a report synthesizer. Given research findings, write a brief summary paragraph (3-4 sentences) combining the key points. No formatting, no headers."
  )

graph =
  Workflow.new("research_pipeline")
  |> Workflow.add_node(:plan, :agent_step, %{
    agent: planner,
    prompt: fn state -> "Generate research questions about: #{state.data.topic}" end,
    result_key: :plan_output
  })
  |> Workflow.add_node(:parse, :transform, %{
    transform_fn: fn data ->
      questions =
        (data[:plan_output] || "")
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(3)

      IO.puts("Questions:")
      Enum.each(questions, &IO.puts("  - #{&1}"))
      IO.puts("")
      Map.put(data, :questions, questions)
    end
  })
  |> Workflow.add_node(:research, :parallel_map, %{
    items: fn state -> state.data.questions end,
    handler: fn question, _state ->
      IO.puts("  Researching: #{String.slice(question, 0, 60)}...")
      {:ok, result} = Nous.AgentRunner.run(researcher, question)
      result.output
    end,
    max_concurrency: 3,
    result_key: :findings
  })
  |> Workflow.add_node(:synthesize, :agent_step, %{
    agent: synthesizer,
    prompt: fn state ->
      pairs =
        Enum.zip(state.data.questions, state.data.findings)
        |> Enum.map(fn {q, a} -> "Q: #{q}\nA: #{a}" end)
        |> Enum.join("\n\n")

      "Synthesize these research findings:\n\n#{pairs}"
    end,
    result_key: :report
  })
  |> Workflow.chain([:plan, :parse, :research, :synthesize])

{:ok, state} = Workflow.run(graph, %{topic: "Elixir's BEAM virtual machine"}, trace: true)

IO.puts("\n=== Report ===\n#{state.data.report}")
IO.puts("\n=== Trace ===")

for e <- state.metadata.trace.entries,
    do: IO.puts("  #{e.node_id}: #{e.status} (#{e.duration_ms}ms)")

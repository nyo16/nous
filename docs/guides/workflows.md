# Workflow Engine Guide

The `Nous.Workflow` module provides a DAG/graph-based workflow engine for orchestrating agents, tools, and control flow as executable directed graphs.

## Overview

Workflows complement existing Nous systems:

- **Decisions** track *why* an agent made choices (reasoning graph)
- **Workflows** define *what* executes and *when* (execution graph)
- **Teams** manage persistent agent groups; Workflows define transient execution plans

## Quick Start

```elixir
alias Nous.Workflow

graph =
  Workflow.new("my_pipeline")
  |> Workflow.add_node(:fetch, :agent_step, %{
    agent: Nous.Agent.new("lmstudio:qwen3", instructions: "Fetch information."),
    prompt: fn state -> "Research: #{state.data.topic}" end,
    result_key: :research
  })
  |> Workflow.add_node(:process, :transform, %{
    transform_fn: fn data -> Map.put(data, :processed, String.upcase(data.research)) end
  })
  |> Workflow.chain([:fetch, :process])

{:ok, state} = Workflow.run(graph, %{topic: "Elixir"})
IO.puts(state.data.processed)
```

## Node Types

| Type | Purpose | Config Keys |
|------|---------|-------------|
| `:agent_step` | Run an LLM agent | `:agent`, `:prompt`, `:result_key` |
| `:tool_step` | Execute a tool function | `:tool`, `:args` |
| `:transform` | Pure data transformation | `:transform_fn` (arity 1) |
| `:branch` | Conditional routing | (uses edge conditions) |
| `:parallel` | Static fan-out to named branches | `:branches`, `:merge` |
| `:parallel_map` | Dynamic fan-out over runtime data | `:items`, `:handler`, `:max_concurrency` |
| `:human_checkpoint` | Pause for human review | `:handler`, `:prompt` |
| `:subworkflow` | Nested workflow | `:workflow`, `:input_mapper`, `:output_mapper` |

## Building Graphs

The API follows the `Ecto.Multi` builder pattern — pipe-friendly struct accumulation:

```elixir
graph =
  Workflow.new("pipeline_id")
  |> Workflow.add_node(:step1, :transform, %{transform_fn: &process/1})
  |> Workflow.add_node(:step2, :agent_step, %{agent: my_agent, prompt: "..."})
  |> Workflow.add_node(:step3, :transform, %{transform_fn: &finalize/1})
  |> Workflow.chain([:step1, :step2, :step3])
```

### Connecting Nodes

```elixir
# Sequential edge (always followed)
|> Workflow.connect(:a, :b)

# Conditional edge (followed when predicate is true)
|> Workflow.connect(:check, :path_a, condition: fn s -> s.data.score > 0.8 end)

# Default edge (fallback when no conditional matches)
|> Workflow.connect(:check, :path_b, default: true)

# Chain shorthand
|> Workflow.chain([:a, :b, :c, :d])
```

## Branching

Route execution based on state:

```elixir
graph =
  Workflow.new("branch_demo")
  |> Workflow.add_node(:evaluate, :transform, %{transform_fn: &score/1})
  |> Workflow.add_node(:check, :branch, %{})
  |> Workflow.add_node(:publish, :transform, %{transform_fn: &publish/1})
  |> Workflow.add_node(:revise, :transform, %{transform_fn: &revise/1})
  |> Workflow.connect(:evaluate, :check)
  |> Workflow.connect(:check, :publish, condition: fn s -> s.data.quality >= 0.8 end)
  |> Workflow.connect(:check, :revise, condition: fn s -> s.data.quality < 0.8 end)
```

## Parallel Execution

### Static Parallel (Named Branches)

```elixir
|> Workflow.add_node(:fan_out, :parallel, %{
  branches: [:web_search, :paper_search, :code_search],
  merge: :deep_merge,          # or :list_collect, or custom fn
  max_concurrency: 3,
  on_branch_error: :continue_others  # or :fail_fast
})
```

### Dynamic Parallel (parallel_map)

Fan out over a runtime-computed list:

```elixir
|> Workflow.add_node(:fetch_all, :parallel_map, %{
  items: fn state -> state.data.urls end,       # list from state
  handler: fn url, _state -> fetch(url) end,    # runs per item
  max_concurrency: 10,
  result_key: :fetched_pages,
  on_error: :collect                            # or :fail_fast
})
```

## Cycles (Retry Loops)

Enable with `allows_cycles: true`. The engine enforces `max_iterations` per node:

```elixir
graph =
  Graph.new("quality_loop", allows_cycles: true)
  |> Graph.add_node(:write, :agent_step, %{agent: writer, prompt: "..."})
  |> Graph.add_node(:evaluate, :transform, %{transform_fn: &score/1})
  |> Graph.add_node(:check, :branch, %{})
  |> Graph.add_node(:done, :transform, %{transform_fn: &finalize/1})
  |> Graph.connect(:write, :evaluate)
  |> Graph.connect(:evaluate, :check)
  |> Graph.connect(:check, :done, condition: fn s -> s.data.score >= 0.8 end)
  |> Graph.connect(:check, :write, condition: fn s -> s.data.score < 0.8 end)

Workflow.run(graph, %{}, max_iterations: 5)
```

## Human-in-the-Loop

Three patterns:

```elixir
# 1. Handler approves immediately
|> Workflow.add_node(:review, :human_checkpoint, %{
  handler: fn state, prompt -> :approve end
})

# 2. Handler edits state before continuing
|> Workflow.add_node(:review, :human_checkpoint, %{
  handler: fn state, _prompt ->
    {:edit, State.update_data(state, &Map.put(&1, :text, "revised"))}
  end
})

# 3. No handler — workflow suspends, returns {:suspended, state, checkpoint}
|> Workflow.add_node(:review, :human_checkpoint, %{prompt: "Awaiting review"})
```

## Hooks

Intercept execution at node boundaries:

```elixir
pre_hook = %Nous.Hook{
  event: :pre_node,
  type: :function,
  handler: fn _event, %{node_id: id, node_type: type} ->
    Logger.info("Executing #{id} (#{type})")
    :allow  # or {:pause, reason} to suspend
  end
}

post_hook = %Nous.Hook{
  event: :post_node,
  type: :function,
  handler: fn _event, %{node_id: id, state: state} ->
    {:modify, State.update_data(state, &Map.put(&1, :last_node, id))}
  end
}

Workflow.run(graph, %{}, hooks: [pre_hook, post_hook])
```

## Error Strategies

Per-node error handling:

```elixir
# Halt immediately (default)
|> Workflow.add_node(:step, :transform, config, error_strategy: :fail_fast)

# Skip and continue
|> Workflow.add_node(:step, :transform, config, error_strategy: :skip)

# Retry with backoff
|> Workflow.add_node(:step, :agent_step, config, error_strategy: {:retry, 3, 1000})

# Route to fallback node
|> Workflow.add_node(:step, :agent_step, config, error_strategy: {:fallback, "safe_step"})
```

## Subworkflows

Nest workflows with data isolation:

```elixir
inner = Graph.new("sub") |> Graph.add_node(:process, :transform, %{...})

|> Workflow.add_node(:sub, :subworkflow, %{
  workflow: inner,
  input_mapper: fn data -> %{input: data.raw} end,     # parent -> child
  output_mapper: fn data -> %{result: data.output} end  # child -> parent
})
```

## Observability

### Tracing

```elixir
{:ok, state} = Workflow.run(graph, %{}, trace: true)

for entry <- state.metadata.trace.entries do
  IO.puts("#{entry.node_id}: #{entry.status} in #{entry.duration_ms}ms")
end
```

### Telemetry Events

- `[:nous, :workflow, :run, :start]` / `:stop` / `:exception`
- `[:nous, :workflow, :node, :start]` / `:stop` / `:exception`

### Mermaid Diagrams

```elixir
IO.puts(Workflow.to_mermaid(graph))
# Generates a Mermaid flowchart with type-specific node shapes
```

## Checkpointing

Save and resume suspended workflows:

```elixir
alias Nous.Workflow.Checkpoint
alias Nous.Workflow.Checkpoint.ETS, as: Store

# Workflow suspends at human checkpoint
{:suspended, state, raw_checkpoint} = Engine.execute(compiled)

# Save checkpoint
cp = Checkpoint.new(%{workflow_id: "wf1", node_id: "review", state: state})
Store.save(cp)

# Later: load and resume
{:ok, cp} = Store.load(cp.run_id)
```

## Examples

See the [workflow examples](https://github.com/nyo16/nous/tree/master/examples/workflow):

- `research_pipeline.exs` — Multi-agent research with parallel search
- `quality_loop.exs` — LLM content generation with retry loop
- `human_review.exs` — HITL approve, edit, and suspend patterns
- `parallel_analysis.exs` — Batch sentiment analysis + multi-specialist branches

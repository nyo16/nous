#!/usr/bin/env elixir

# Nous Workflow — Human-in-the-Loop Review
#
# An LLM generates content, then a human checkpoint pauses for review.
# Demonstrates three HITL patterns:
#   1. Auto-approve (handler returns :approve)
#   2. Edit and continue (handler returns {:edit, new_state})
#   3. Suspend (no handler — workflow pauses, returns checkpoint)
#
# Demonstrates: human_checkpoint, suspend/resume, hooks
#
# Run: TEST_MODEL="lmstudio:qwen3.5-27b" mix run examples/workflow/human_review.exs

alias Nous.Workflow

model = System.get_env("TEST_MODEL", "lmstudio:qwen3.5-9b-mlx")
IO.puts("=== Human-in-the-Loop Review ===\nModel: #{model}\n")

writer =
  Nous.Agent.new(model,
    instructions:
      "Write a one-sentence tagline for the given product. Output only the tagline, no quotes, no formatting."
  )

# -------------------------------------------------------------------------
# Pattern 1: Auto-approve — simulates a human approving immediately
# -------------------------------------------------------------------------

IO.puts("--- Pattern 1: Auto-Approve ---")

graph =
  Workflow.new("auto_approve")
  |> Workflow.add_node(:generate, :agent_step, %{
    agent: writer,
    prompt: fn state -> "Write a tagline for: #{state.data.product}" end,
    result_key: :tagline
  })
  |> Workflow.add_node(:review, :human_checkpoint, %{
    prompt: "Review the tagline before publishing",
    handler: fn state, prompt ->
      IO.puts("  [Human] #{prompt}")
      IO.puts("  [Human] Tagline: #{state.data.tagline}")
      IO.puts("  [Human] Decision: APPROVED")
      :approve
    end
  })
  |> Workflow.add_node(:publish, :transform, %{
    transform_fn: fn data -> Map.put(data, :published, true) end
  })
  |> Workflow.chain([:generate, :review, :publish])

{:ok, state} = Workflow.run(graph, %{product: "an AI-powered code editor"})
IO.puts("  Published: #{state.data.published}\n")

# -------------------------------------------------------------------------
# Pattern 2: Edit — human modifies the content before continuing
# -------------------------------------------------------------------------

IO.puts("--- Pattern 2: Edit Before Continue ---")

graph =
  Workflow.new("edit_flow")
  |> Workflow.add_node(:generate, :agent_step, %{
    agent: writer,
    prompt: fn state -> "Write a tagline for: #{state.data.product}" end,
    result_key: :tagline
  })
  |> Workflow.add_node(:review, :human_checkpoint, %{
    handler: fn state, _prompt ->
      original = state.data.tagline
      edited = "#{original} — Now with AI superpowers!"
      IO.puts("  [Human] Original: #{original}")
      IO.puts("  [Human] Edited:   #{edited}")
      {:edit, Nous.Workflow.State.update_data(state, &Map.put(&1, :tagline, edited))}
    end
  })
  |> Workflow.add_node(:publish, :transform, %{
    transform_fn: fn data ->
      IO.puts("  [Publish] Final: #{data.tagline}")
      Map.put(data, :published, true)
    end
  })
  |> Workflow.chain([:generate, :review, :publish])

{:ok, _state} = Workflow.run(graph, %{product: "a smart coffee maker"})
IO.puts("")

# -------------------------------------------------------------------------
# Pattern 3: Suspend — no handler, workflow pauses and returns checkpoint
# -------------------------------------------------------------------------

IO.puts("--- Pattern 3: Suspend for External Review ---")

graph =
  Workflow.new("suspend_flow")
  |> Workflow.add_node(:generate, :agent_step, %{
    agent: writer,
    prompt: fn state -> "Write a tagline for: #{state.data.product}" end,
    result_key: :tagline
  })
  |> Workflow.add_node(:await_review, :human_checkpoint, %{
    prompt: "Awaiting external review..."
  })
  |> Workflow.add_node(:publish, :transform, %{
    transform_fn: fn data -> Map.put(data, :published, true) end
  })
  |> Workflow.chain([:generate, :await_review, :publish])

{:ok, compiled} = Workflow.compile(graph)

case Nous.Workflow.Engine.execute(compiled, %{product: "a self-driving skateboard"}) do
  {:suspended, state, checkpoint} ->
    IO.puts("  Workflow SUSPENDED at node: #{checkpoint.node_id}")
    IO.puts("  Tagline so far: #{state.data.tagline}")
    IO.puts("  (In production, save checkpoint to DB and resume later)")

  {:ok, state} ->
    IO.puts("  Published: #{state.data.published}")
end

IO.puts("\n=== Done ===")

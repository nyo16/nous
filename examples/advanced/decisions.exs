#!/usr/bin/env elixir

# Decision Graph — Tracking Agent Reasoning
#
# The decision graph gives agents a structured way to record their own
# reasoning: goals, decisions, options, actions, and outcomes become nodes
# in a directed graph connected by typed edges. This example shows BOTH ways
# to use it:
#
#   Part 1 — the direct core API (no LLM required): init an ETS store, add
#            nodes and edges by hand, then query active goals and recent
#            decisions.
#   Part 2 — wiring the Nous.Plugins.Decisions plugin into an agent so the
#            model gets add_goal / record_decision / record_outcome /
#            query_decisions tools and decision context in its prompt.
#
# Run: mix run examples/advanced/decisions.exs
#
# Part 2 needs a running provider. We default to "lmstudio:qwen3" (a local
# LM Studio server), but ANY provider works — swap the model string for
# "openai:gpt-4o", "anthropic:claude-sonnet-4-5-20250929", etc.

alias Nous.Decisions
alias Nous.Decisions.{Node, Edge}
alias Nous.Decisions.Store

# Any provider works — swap this for "openai:gpt-4o", "anthropic:...", etc.
model = "lmstudio:qwen3"

# =============================================================================
# Part 1: Direct core API — drive the graph without an agent
# =============================================================================

IO.puts("=== Part 1: Direct Decision Graph API (ETS store) ===\n")

# The store state is opaque — init/1 hands back table references that you
# thread through every subsequent call. Writes return an updated state.
{:ok, state} = Store.ETS.init([])

# --- A goal node ----------------------------------------------------------
goal = Node.new(%{type: :goal, label: "Implement user authentication", confidence: 0.9})
{:ok, state} = Decisions.add_node(Store.ETS, state, goal)
IO.puts("Added goal:     #{goal.label} (confidence #{goal.confidence})")

# --- A decision node, linked back to the goal -----------------------------
decision =
  Node.new(%{
    type: :decision,
    label: "Use JWT tokens",
    rationale: "Stateless and scales horizontally"
  })

{:ok, state} = Decisions.add_node(Store.ETS, state, decision)
IO.puts("Added decision: #{decision.label}")

# Edges are directed and typed. :leads_to says "this goal led to this decision".
edge = Edge.new(%{from_id: goal.id, to_id: decision.id, edge_type: :leads_to})
{:ok, state} = Decisions.add_edge(Store.ETS, state, edge)
IO.puts("Linked goal -[:leads_to]-> decision\n")

# --- A second decision so recent_decisions has something to sort ----------
decision2 =
  Node.new(%{
    type: :decision,
    label: "Store sessions in Redis",
    rationale: "Fast lookups, easy revocation"
  })

{:ok, state} = Decisions.add_node(Store.ETS, state, decision2)
edge2 = Edge.new(%{from_id: goal.id, to_id: decision2.id, edge_type: :leads_to})
{:ok, state} = Decisions.add_edge(Store.ETS, state, edge2)

# --- Queries --------------------------------------------------------------
# Queries always return {:ok, list}; an empty list means "no matches", never
# an error. Only get_node/3 returns {:error, :not_found}.
{:ok, goals} = Decisions.active_goals(Store.ETS, state)
IO.puts("Active goals (#{length(goals)}):")

for g <- goals do
  IO.puts("  - #{g.label} [#{g.status}]")
end

{:ok, recent} = Decisions.recent_decisions(Store.ETS, state, limit: 5)
IO.puts("\nRecent decisions (newest first):")

for d <- recent do
  IO.puts("  - #{d.label} — #{d.rationale}")
end

# Fetching a single node by ID, and updating its fields (bumps updated_at).
{:ok, state} = Decisions.update_node(Store.ETS, state, goal.id, %{status: :completed})
{:ok, refreshed} = Decisions.get_node(Store.ETS, state, goal.id)
IO.puts("\nGoal status after update_node: #{refreshed.status}")

# After completing the goal it is no longer "active".
{:ok, still_active} = Decisions.active_goals(Store.ETS, state)
IO.puts("Active goals remaining: #{length(still_active)}\n")

# Note: the ETS store is run-scoped — its tables die with this process. Reach
# for the DuckDB backend with a file :path if you need cross-run persistence.

# =============================================================================
# Part 2: Wire the plugin into an agent
# =============================================================================

IO.puts("=== Part 2: Decisions plugin attached to an agent ===\n")

# IMPORTANT: deps is a RUN-time option passed to Nous.run/3, NOT to Nous.new/2.
# The plugin reads deps[:decisions_config] to init its own store on each run.
agent = Nous.new(model, plugins: [Nous.Plugins.Decisions])

deps = %{
  decisions_config: %{
    # Required: the store backend module.
    store: Store.ETS,
    # Optional knobs (defaults shown):
    store_opts: [],
    decision_limit: 5,
    auto_inject: true,
    inject_strategy: :first_only
  }
}

IO.puts("Agent built with Nous.Plugins.Decisions.")
IO.puts("On run, the agent gains these tools:")
IO.puts("  add_goal, record_decision, record_outcome, query_decisions")
IO.puts("and its prompt is seeded with current goals + recent decisions.\n")

prompt = "Plan and implement user authentication. Track your reasoning as you go."
IO.puts("Running agent with prompt:\n  #{prompt}\n")

# The agent run needs a live provider. If none is reachable we report the
# error instead of crashing, so Part 1 still demonstrates cleanly.
case Nous.run(agent, prompt, deps: deps) do
  {:ok, result} ->
    IO.puts("Response:\n#{result.output}\n")
    IO.puts("Tokens used: #{result.usage.total_tokens}")

  {:error, reason} ->
    IO.puts("Agent run did not complete: #{inspect(reason)}")
    IO.puts("(Part 2 needs a running provider — set `model` and try again.)")
end

IO.puts("\n=== Done ===")

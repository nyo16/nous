#!/usr/bin/env elixir

# Nous AI - Teams (Multi-Agent Coordination)
#
# A "team" is a small OTP supervision tree: one Coordinator that spawns and
# monitors agent processes, a SharedState process (discoveries + file-region
# locks), an optional RateLimiter (started only when you pass :budget), and a
# PubSub topic scheme that carries membership and inter-agent messages.
#
# This script walks the team lifecycle WITHOUT making any LLM calls — it only
# starts the supervision tree, spawns agents with roles, inspects the team, and
# tears it down. That makes it runnable offline with no provider configured.
#
# When the spawned agents DO run, give them a model. The default convention in
# these examples is "lmstudio:qwen3" for a local LM Studio server, but any
# "provider:model" string works (e.g. "openai:gpt-4o", "anthropic:claude-...").
#
# See also:
#   - docs/guides/teams.md                       (full guide)
#   - examples/13_sub_agents.exs                 (one-shot sub-agent delegation)
#   - examples/advanced/liveview_multi_agent.exs (dashboard over team PubSub)

alias Nous.Teams.{Coordinator, Role}

IO.puts("=== Nous AI - Teams Demo ===\n")

# ============================================================================
# Optional: a PubSub for membership events
# ============================================================================
#
# Teams broadcast membership events ({:agent_joined, name}, {:agent_left, name},
# {:team_dissolved, id}) on the topic "nous:team:<id>". PubSub is OPTIONAL — all
# the Teams.Comms helpers no-op when it is nil — so the lifecycle below works
# either way. If phoenix_pubsub is available we start one and subscribe so you
# can see the events fire.

pubsub =
  if Code.ensure_loaded?(Phoenix.PubSub) do
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Nous.Teams.DemoPubSub)
    Nous.Teams.DemoPubSub
  else
    IO.puts("(phoenix_pubsub not available — skipping membership-event demo)\n")
    nil
  end

# ============================================================================
# 1. Start the per-team supervision tree
# ============================================================================
#
# Only :team_id is required; every internal process name is derived from it.
# Passing :budget is what starts the RateLimiter (omitted here, so none runs).

IO.puts("--- 1. Starting the team supervisor ---")

team_id = "demo_team"

{:ok, _sup} =
  Nous.Teams.Supervisor.start_link(
    team_id: team_id,
    team_name: "Research Team",
    pubsub: pubsub,
    name: :demo_team_sup
  )

# You drive the team through its Coordinator, registered under a derived name.
coordinator = :"team_coordinator_#{team_id}"

# Subscribe so we observe {:agent_joined, _} etc. on the team topic.
if pubsub, do: Nous.Teams.Comms.subscribe_team(pubsub, team_id)

IO.puts("Team '#{team_id}' started. Coordinator: #{inspect(coordinator)}\n")

# ============================================================================
# 2. Spawn agents with different roles
# ============================================================================
#
# spawn_agent/4 takes (coordinator, name, agent_config_map, opts). The config
# map is whatever AgentServer accepts; pass a Teams.Role via :role to shape the
# agent's system prompt and tool access. Built-in roles: researcher/0, coder/0,
# lead/0. You can also build a custom one with Role.new/1.

IO.puts("--- 2. Spawning agents with roles ---")

{:ok, _alice} =
  Coordinator.spawn_agent(
    coordinator,
    "alice",
    %{model: "lmstudio:qwen3", instructions: "Research specialist"},
    role: Role.researcher()
  )

IO.puts(
  "Spawned 'alice' as #{Role.researcher().name} (max_iterations: #{Role.researcher().max_iterations})"
)

{:ok, _bob} =
  Coordinator.spawn_agent(
    coordinator,
    "bob",
    %{model: "lmstudio:qwen3", instructions: "Implementation specialist"},
    role: Role.coder()
  )

IO.puts("Spawned 'bob' as #{Role.coder().name}")

# A custom role: whitelist via Role.new/1. allowed_tools wins over denied_tools.
reviewer = Role.new(name: :reviewer, system_prompt: "Review carefully", max_iterations: 10)

{:ok, _carol} =
  Coordinator.spawn_agent(
    coordinator,
    "carol",
    %{model: "lmstudio:qwen3", instructions: "Reviews the work of others"},
    role: reviewer
  )

IO.puts("Spawned 'carol' as #{reviewer.name}\n")

# Duplicate names are rejected, not replaced.
case Coordinator.spawn_agent(coordinator, "alice", %{model: "lmstudio:qwen3"}) do
  {:error, :already_exists} ->
    IO.puts("Re-spawning 'alice' correctly returned {:error, :already_exists}\n")

  other ->
    IO.puts("Unexpected: #{inspect(other)}\n")
end

# ============================================================================
# 3. Inspect the team
# ============================================================================

IO.puts("--- 3. Inspecting the team ---")

agents = Coordinator.list_agents(coordinator)
IO.puts("list_agents/1 returned #{length(agents)} agents:")

for a <- agents do
  IO.puts("  - #{a.name} (#{a.status}) #{inspect(a.pid)}")
end

status = Coordinator.team_status(coordinator)

IO.puts("""

team_status/1:
  team_id:     #{status.team_id}
  team_name:   #{status.team_name}
  agent_count: #{status.agent_count}
""")

# Drain any membership events PubSub delivered to this process.
if pubsub do
  events =
    Stream.repeatedly(fn ->
      receive do
        msg -> msg
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))

  IO.puts("Membership events received: #{inspect(events)}\n")
end

# ============================================================================
# 4. Stop one agent, then dissolve the team
# ============================================================================
#
# stop_agent/2 terminates one agent. dissolve/1 terminates ALL agents but keeps
# the Coordinator alive (you could spawn fresh agents afterward); tear the whole
# tree down via the Supervisor.

IO.puts("--- 4. Tearing down ---")

:ok = Coordinator.stop_agent(coordinator, "bob")
IO.puts("Stopped 'bob'. Remaining: #{Coordinator.team_status(coordinator).agent_count}")

:ok = Coordinator.dissolve(coordinator)
IO.puts("Dissolved team. Remaining: #{Coordinator.team_status(coordinator).agent_count}")

# Stop the whole supervision tree (Coordinator, SharedState, agent supervisor).
:ok = Supervisor.stop(:demo_team_sup)
IO.puts("Stopped the team supervision tree.\n")

IO.puts("Done!")

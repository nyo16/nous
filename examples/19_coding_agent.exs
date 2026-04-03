#!/usr/bin/env elixir

# Example 19: Building a Coding Agent
#
# Demonstrates how to build a coding agent with built-in file and shell tools,
# tool permissions, session guardrails, and transcript compaction.
#
# Run with: mix run examples/19_coding_agent.exs
#
# Requires: ANTHROPIC_API_KEY or OPENAI_API_KEY

alias Nous.{Agent, Permissions, Transcript}
alias Nous.Session.{Config, Guardrails}
alias Nous.Tools.{Bash, FileRead, FileWrite, FileEdit, FileGlob, FileGrep}

# ── 1. Configure permissions ────────────────────────────────
#
# Block dangerous tools, require approval for write operations

policy =
  Permissions.build_policy(
    mode: :default,
    deny: [],
    approval_required: ["bash", "file_write", "file_edit"]
  )

IO.puts("=== Coding Agent Example ===\n")
IO.puts("Permission policy: #{inspect(policy.mode)}")

# ── 2. Build tool list with permission filtering ────────────
#
# All 6 coding tools, filtered through the permission policy

all_tools =
  [Bash, FileRead, FileWrite, FileEdit, FileGlob, FileGrep]
  |> Enum.map(&Nous.Tool.from_module/1)

allowed_tools = Permissions.filter_tools(policy, all_tools)
IO.puts("Tools: #{length(allowed_tools)} allowed out of #{length(all_tools)}")

Enum.each(allowed_tools, fn tool ->
  approval =
    if Permissions.requires_approval?(policy, tool.name), do: " [approval required]", else: ""

  IO.puts("  - #{tool.name} (#{tool.category})#{approval}")
end)

# ── 3. Configure session guardrails ─────────────────────────
#
# Limit turns and token budget to prevent runaway agents

config =
  Config.new(
    max_turns: 5,
    max_budget_tokens: 50_000,
    compact_after_turns: 3
  )

IO.puts("\nSession config:")
IO.puts("  Max turns: #{config.max_turns}")
IO.puts("  Max budget: #{config.max_budget_tokens} tokens")
IO.puts("  Compact after: #{config.compact_after_turns} turns")

# ── 4. Create the agent ─────────────────────────────────────

model = System.get_env("NOUS_MODEL", "anthropic:claude-sonnet-4-20250514")

# In a real app you'd call Agent.run/3 or Agent.run_stream/3 on this agent.
# Here we just show the setup.
_agent =
  Agent.new(model,
    instructions: """
    You are a coding assistant with access to file and shell tools.
    Use tools to read, search, and edit files. Be concise.
    """,
    tools: allowed_tools
  )

IO.puts("\nAgent created with model: #{model}")

# ── 5. Simulate a session with guardrails ────────────────────

IO.puts("\n--- Session Simulation ---\n")

# Check limits before each turn
turn_count = 0
in_tokens = 0
out_tokens = 0

case Guardrails.check_limits(config, turn_count, in_tokens, out_tokens) do
  :ok ->
    IO.puts("Turn #{turn_count + 1}: Limits OK")
    summary = Guardrails.summary(config, turn_count, in_tokens, out_tokens)
    IO.puts("  Remaining: #{summary.turns.remaining} turns, #{summary.tokens.remaining} tokens")

  {:error, reason} ->
    IO.puts("Session blocked: #{reason}")
end

# ── 6. Demonstrate transcript compaction ─────────────────────

IO.puts("\n--- Transcript Compaction ---\n")

# Simulate 25 messages
messages =
  for i <- 1..25 do
    if rem(i, 2) == 1,
      do: Nous.Message.user("User message #{i}"),
      else: Nous.Message.assistant("Assistant response #{i}")
  end

IO.puts("Messages before compaction: #{length(messages)}")
IO.puts("Estimated tokens: #{Transcript.estimate_messages_tokens(messages)}")

# Auto-compact: every 20 messages, keep last 10
compacted = Transcript.maybe_compact(messages, every: 20, keep_last: 10)

IO.puts("Messages after compaction: #{length(compacted)}")
IO.puts("First message: #{String.slice(hd(compacted).content, 0..60)}...")

# Async compaction with callback
IO.puts("\nAsync compaction:")
test_pid = self()

Transcript.maybe_compact_async(messages, [every: 20, keep_last: 10], fn
  {:compacted, msgs} ->
    send(test_pid, {:done, length(msgs)})

  {:unchanged, _} ->
    send(test_pid, {:done, :unchanged})
end)

receive do
  {:done, count} -> IO.puts("  Background compaction result: #{inspect(count)} messages")
after
  5_000 -> IO.puts("  Timeout waiting for compaction")
end

IO.puts("\n=== Done ===")

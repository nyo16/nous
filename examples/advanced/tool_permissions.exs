#!/usr/bin/env elixir

# Tool Permissions Example
#
# Demonstrates the Nous.Permissions policy engine for controlling
# which tools agents can use.
#
# Run with: mix run examples/advanced/tool_permissions.exs

alias Nous.Permissions
alias Nous.Permissions.Policy
alias Nous.Tools.{Bash, FileRead, FileWrite, FileEdit, FileGlob, FileGrep}

IO.puts("=== Tool Permissions Demo ===\n")

# Build tools from modules
tools =
  [Bash, FileRead, FileWrite, FileEdit, FileGlob, FileGrep]
  |> Enum.map(&Nous.Tool.from_module/1)

IO.puts("All tools: #{Enum.map(tools, & &1.name) |> Enum.join(", ")}\n")

# ── Preset Policies ─────────────────────────────────────────

IO.puts("--- Preset Policies ---\n")

# Default: read/search open, write/execute need approval
default = Permissions.default_policy()
IO.puts("Default policy (mode: #{default.mode}):")

Enum.each(tools, fn t ->
  blocked = Permissions.blocked?(default, t.name)
  approval = Permissions.requires_approval?(default, t.name)

  status =
    cond do
      blocked -> "BLOCKED"
      approval -> "needs approval"
      true -> "open"
    end

  IO.puts("  #{t.name}: #{status}")
end)

# Permissive: everything open
IO.puts("\nPermissive policy:")
permissive = Permissions.permissive_policy()
IO.puts("  bash needs approval? #{Permissions.requires_approval?(permissive, "bash")}")

# Strict: everything needs approval
IO.puts("\nStrict policy:")
strict = Permissions.strict_policy()
IO.puts("  file_read needs approval? #{Permissions.requires_approval?(strict, "file_read")}")

# ── Custom Policy ────────────────────────────────────────────

IO.puts("\n--- Custom Policy ---\n")

custom =
  Permissions.build_policy(
    mode: :default,
    deny: ["bash"],
    deny_prefixes: ["file_write"],
    approval_required: ["file_edit"]
  )

IO.puts("Custom policy (deny bash, block file_write*, approve file_edit):")
{allowed, blocked} = Permissions.partition_tools(custom, tools)

IO.puts("  Allowed: #{Enum.map(allowed, & &1.name) |> Enum.join(", ")}")
IO.puts("  Blocked: #{Enum.map(blocked, & &1.name) |> Enum.join(", ")}")

# ── Filtering for Agent ──────────────────────────────────────

IO.puts("\n--- Filtering for Agent ---\n")

filtered = Permissions.filter_tools(custom, tools)
IO.puts("Agent will receive #{length(filtered)} tools:")

Enum.each(filtered, fn t ->
  approval = if Permissions.requires_approval?(custom, t.name), do: " [approval]", else: ""
  IO.puts("  #{t.name} (#{t.category})#{approval}")
end)

IO.puts("\n=== Done ===")

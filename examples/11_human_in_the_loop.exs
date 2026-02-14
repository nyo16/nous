#!/usr/bin/env elixir

# Nous AI - Human-in-the-Loop (HITL)
# Require human approval before executing sensitive tool calls
#
# Run: mix run examples/11_human_in_the_loop.exs

IO.puts("=== Nous AI - Human-in-the-Loop Demo ===\n")

# ============================================================================
# Example 1: Direct approval handler (no plugin)
# ============================================================================

IO.puts("--- Example 1: Direct Approval Handler ---\n")

# Define a "dangerous" tool that requires approval
send_email = fn _ctx, %{"to" => to, "subject" => subject, "body" => body} ->
  # In production, this would actually send an email
  IO.puts("  [EMAIL SENT] To: #{to}, Subject: #{subject}")
  %{sent: true, to: to, subject: subject}
end

# Create the tool with requires_approval: true
email_tool =
  Nous.Tool.from_function(send_email,
    name: "send_email",
    description: "Send an email to a recipient",
    requires_approval: true,
    parameters: %{
      "type" => "object",
      "properties" => %{
        "to" => %{"type" => "string", "description" => "Email address"},
        "subject" => %{"type" => "string", "description" => "Email subject"},
        "body" => %{"type" => "string", "description" => "Email body"}
      },
      "required" => ["to", "subject", "body"]
    }
  )

# A safe tool that does NOT require approval
search = fn _ctx, %{"query" => query} ->
  %{results: ["Result 1 for: #{query}", "Result 2 for: #{query}"]}
end

agent =
  Nous.new("lmstudio:qwen3",
    instructions: """
    You are an executive assistant. You can search for information and send emails.
    When asked to send an email, use the send_email tool.
    """,
    tools: [
      email_tool,
      Nous.Tool.from_function(search,
        name: "search",
        description: "Search for information",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"}
          },
          "required" => ["query"]
        }
      )
    ]
  )

# The approval handler is called BEFORE the tool executes.
# It receives the tool call details and must return:
#   :approve       - proceed with execution
#   :reject        - skip execution, return rejection message
#   {:edit, args}  - proceed with modified arguments
approval_handler = fn tool_call ->
  IO.puts("\n  *** APPROVAL REQUIRED ***")
  IO.puts("  Tool: #{tool_call.name}")
  IO.puts("  Arguments: #{inspect(tool_call.arguments)}")
  IO.write("  Approve? [y/n/e(dit)]: ")

  case IO.gets("") |> String.trim() |> String.downcase() do
    "y" ->
      IO.puts("  --> Approved!")
      :approve

    "e" ->
      IO.write("  New recipient email: ")
      new_to = IO.gets("") |> String.trim()
      new_args = Map.put(tool_call.arguments, "to", new_to)
      IO.puts("  --> Approved with edits!")
      {:edit, new_args}

    _ ->
      IO.puts("  --> Rejected!")
      :reject
  end
end

IO.puts("Asking the agent to send an email (you'll be prompted to approve)...\n")

{:ok, result} =
  Nous.run(
    agent,
    "Send an email to bob@example.com with subject 'Meeting Tomorrow' and body 'Hi Bob, let's meet at 3pm.'",
    approval_handler: approval_handler
  )

IO.puts("\nAgent response: #{result.output}")
IO.puts("Tool calls made: #{result.usage.tool_calls}")

# ============================================================================
# Example 2: Using the HumanInTheLoop plugin
# ============================================================================

IO.puts("\n\n--- Example 2: HumanInTheLoop Plugin ---\n")

# The plugin approach is more declarative: specify which tools need
# approval in the deps config, and the plugin handles the rest.

delete_record = fn _ctx, %{"table" => table, "id" => id} ->
  IO.puts("  [DELETED] #{table}:#{id}")
  %{deleted: true, table: table, id: id}
end

read_record = fn _ctx, %{"table" => table, "id" => id} ->
  %{table: table, id: id, data: %{name: "Alice", email: "alice@example.com"}}
end

agent2 =
  Nous.new("lmstudio:qwen3",
    instructions: "You are a database admin assistant. You can read and delete records.",
    tools: [
      Nous.Tool.from_function(delete_record,
        name: "delete_record",
        description: "Delete a database record",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "table" => %{"type" => "string", "description" => "Table name"},
            "id" => %{"type" => "string", "description" => "Record ID"}
          },
          "required" => ["table", "id"]
        }
      ),
      Nous.Tool.from_function(read_record,
        name: "read_record",
        description: "Read a database record",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "table" => %{"type" => "string", "description" => "Table name"},
            "id" => %{"type" => "string", "description" => "Record ID"}
          },
          "required" => ["table", "id"]
        }
      )
    ],
    # Add the HITL plugin
    plugins: [Nous.Plugins.HumanInTheLoop]
  )

# Configure HITL via deps:
#   :tools   - list of tool names that require approval (others execute freely)
#   :handler - the approval function
hitl_config = %{
  # Only delete needs approval; read is fine
  tools: ["delete_record"],
  handler: fn tool_call ->
    IO.puts("\n  *** DANGEROUS OPERATION ***")
    IO.puts("  Tool: #{tool_call.name}")
    IO.puts("  Arguments: #{inspect(tool_call.arguments)}")
    IO.write("  Type 'yes' to confirm: ")

    case IO.gets("") |> String.trim() |> String.downcase() do
      "yes" -> :approve
      _ -> :reject
    end
  end
}

IO.puts("Asking the agent to delete a record (delete requires approval, read does not)...\n")

{:ok, result} =
  Nous.run(
    agent2,
    "First read user 42, then delete user 42 from the users table.",
    deps: %{hitl_config: hitl_config}
  )

IO.puts("\nAgent response: #{result.output}")

# ============================================================================
# Example 3: Auto-approve with logging (audit trail)
# ============================================================================

IO.puts("\n\n--- Example 3: Auto-Approve with Audit Log ---\n")

# In production, you might auto-approve but log everything for audit
audit_log = :ets.new(:audit_log, [:set, :public])

audit_handler = fn tool_call ->
  entry = %{
    tool: tool_call.name,
    args: tool_call.arguments,
    timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
    decision: :approve
  }

  :ets.insert(audit_log, {System.unique_integer([:positive]), entry})
  IO.puts("  [AUDIT] Logged: #{tool_call.name}(#{inspect(tool_call.arguments)})")
  :approve
end

{:ok, result} =
  Nous.run(agent, "Send an email to alice@example.com with subject 'Hello' and body 'Hi Alice!'",
    approval_handler: audit_handler
  )

IO.puts("\nAgent response: #{result.output}")

# Show audit log
IO.puts("\nAudit log entries:")

:ets.tab2list(audit_log)
|> Enum.each(fn {_id, entry} ->
  IO.puts("  #{entry.timestamp} | #{entry.tool} | #{inspect(entry.args)}")
end)

:ets.delete(audit_log)

IO.puts("\n\nNext: mix run examples/12_plugins.exs (coming soon)")

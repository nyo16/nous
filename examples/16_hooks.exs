# Example 16: Hooks — Lifecycle Interceptors for Tool Execution
#
# Hooks provide granular control over agent behavior at specific lifecycle
# events. They can block actions, modify inputs/outputs, and enforce policies.
#
# Run with: mix run examples/16_hooks.exs
# Requires: OPENAI_API_KEY environment variable

alias Nous.{Agent, Hook}

# =============================================================================
# Example 1: Block dangerous tool calls with a function hook
# =============================================================================

IO.puts("=== Example 1: Blocking Hook ===\n")

# Define a simple tool
defmodule FileTools do
  def delete_file(_ctx, %{"path" => path}) do
    {:ok, "Deleted: #{path}"}
  end

  def read_file(_ctx, %{"path" => path}) do
    {:ok, "Contents of: #{path}"}
  end
end

# Create an agent with a hook that blocks deleting files in /etc
agent =
  Agent.new("openai:gpt-4o-mini",
    instructions: "You are a file management assistant.",
    tools: [
      Nous.Tool.from_function(&FileTools.delete_file/2,
        name: "delete_file",
        description: "Delete a file at the given path",
        parameters: %{
          type: "object",
          properties: %{"path" => %{type: "string", description: "File path to delete"}},
          required: ["path"]
        }
      ),
      Nous.Tool.from_function(&FileTools.read_file/2,
        name: "read_file",
        description: "Read a file at the given path",
        parameters: %{
          type: "object",
          properties: %{"path" => %{type: "string", description: "File path to read"}},
          required: ["path"]
        }
      )
    ],
    hooks: [
      # Block deleting system files
      %Hook{
        event: :pre_tool_use,
        matcher: "delete_file",
        type: :function,
        name: "protect_system_files",
        handler: fn _event, %{arguments: args} ->
          path = args["path"] || ""

          if String.starts_with?(path, "/etc") or String.starts_with?(path, "/sys") do
            {:deny, "Cannot delete system files"}
          else
            :allow
          end
        end
      },
      # Log all tool calls
      %Hook{
        event: :post_tool_use,
        type: :function,
        name: "tool_logger",
        handler: fn _event, %{tool_name: name, result: result} ->
          IO.puts(
            "  [LOG] Tool '#{name}' returned: #{inspect(String.slice(to_string(result), 0..80))}"
          )

          :allow
        end
      }
    ]
  )

IO.puts("Agent created with #{length(agent.hooks)} hooks\n")

# =============================================================================
# Example 2: Module-based hook
# =============================================================================

IO.puts("=== Example 2: Module-Based Hook ===\n")

defmodule RateLimitHook do
  @behaviour Nous.Hook

  @impl true
  def handle(:pre_tool_use, %{tool_name: name}) do
    IO.puts("  [RATE LIMIT] Checking rate limit for tool: #{name}")
    # In production, check against a counter/ETS table
    :allow
  end

  def handle(_event, _payload), do: :allow
end

agent2 =
  Agent.new("openai:gpt-4o-mini",
    instructions: "You are helpful.",
    hooks: [
      %Hook{
        event: :pre_tool_use,
        type: :module,
        handler: RateLimitHook,
        name: "rate_limiter"
      }
    ]
  )

IO.puts("Agent created with module hook: #{hd(agent2.hooks).name}\n")

# =============================================================================
# Example 3: Hook priority ordering
# =============================================================================

IO.puts("=== Example 3: Hook Priority ===\n")

hooks = [
  %Hook{
    event: :pre_tool_use,
    type: :function,
    handler: fn _, _ ->
      IO.puts("  [Priority 300] Last hook")
      :allow
    end,
    priority: 300,
    name: "last"
  },
  %Hook{
    event: :pre_tool_use,
    type: :function,
    handler: fn _, _ ->
      IO.puts("  [Priority 10] First hook")
      :allow
    end,
    priority: 10,
    name: "first"
  },
  %Hook{
    event: :pre_tool_use,
    type: :function,
    handler: fn _, _ ->
      IO.puts("  [Priority 100] Middle hook")
      :allow
    end,
    priority: 100,
    name: "middle"
  }
]

# Demonstrate hook ordering via registry
registry = Nous.Hook.Registry.from_hooks(hooks)
ordered = Nous.Hook.Registry.hooks_for(registry, :pre_tool_use)
IO.puts("Hooks in execution order:")

for hook <- ordered do
  IO.puts("  #{hook.name} (priority: #{hook.priority})")
end

IO.puts("\nRunning hooks:")
Nous.Hook.Runner.run(registry, :pre_tool_use, %{tool_name: "test"})

IO.puts("\n=== Done ===")

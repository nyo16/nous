# Auto-Update Memory
#
# Demonstrates automatic memory updates after each agent run.
# Instead of the agent explicitly calling remember/recall/forget tools,
# a reflection step runs after each conversation turn and updates
# memories automatically — similar to Claude Code's "recalled/wrote memory".
#
# Run: OPENAI_API_KEY="sk-..." mix run examples/memory/auto_update.exs
#
# You can also use a local model:
#   mix run examples/memory/auto_update.exs

# Choose a model (local or cloud)
model = (System.get_env("OPENAI_API_KEY") && "openai:gpt-4o-mini") || "lmstudio:qwen3-4b"

alias Nous.Memory.Store

# Create an agent with auto_update_memory enabled
agent =
  Nous.new(model,
    plugins: [Nous.Plugins.Memory],
    instructions: "You are a helpful personal assistant. Remember what the user tells you.",
    deps: %{
      memory_config: %{
        store: Store.ETS,
        auto_update_memory: true,
        auto_update_every: 1,
        # Use a cheaper/faster model for the reflection step (optional)
        # reflection_model: "openai:gpt-4o-mini",
        reflection_max_tokens: 500
      }
    }
  )

IO.puts("=== Auto-Update Memory Demo ===\n")

# Turn 1: Tell the agent something personal
IO.puts("--- Turn 1 ---")
{:ok, result1} = Nous.run(agent, "My name is Alice and I work as a data scientist at Acme Corp.")
IO.puts("Agent: #{result1.output}\n")

# Check what memories were auto-created
store_state = result1.context.deps[:memory_config][:store_state]
{:ok, memories} = Store.ETS.list(store_state, [])
IO.puts("Memories after turn 1 (#{length(memories)}):")
for m <- memories, do: IO.puts("  - [#{m.type}] #{m.content}")
IO.puts("")

# Turn 2: Continue the conversation (pass context for continuity)
IO.puts("--- Turn 2 ---")

{:ok, result2} =
  Nous.run(agent, "Actually, I just switched jobs. I'm now at TechCorp as a ML engineer.",
    context: result1.context
  )

IO.puts("Agent: #{result2.output}\n")

# Check memories again — should have updated, not duplicated
store_state = result2.context.deps[:memory_config][:store_state]
{:ok, memories} = Store.ETS.list(store_state, [])
IO.puts("Memories after turn 2 (#{length(memories)}):")
for m <- memories, do: IO.puts("  - [#{m.type}] (#{m.id |> String.slice(0..7)}) #{m.content}")
IO.puts("")

# Turn 3: Ask something that requires memory
IO.puts("--- Turn 3 ---")
{:ok, result3} = Nous.run(agent, "What do you know about me?", context: result2.context)
IO.puts("Agent: #{result3.output}\n")

# Final memory state
store_state = result3.context.deps[:memory_config][:store_state]
{:ok, memories} = Store.ETS.list(store_state, [])
IO.puts("=== Final Memory State (#{length(memories)} memories) ===")

for m <- memories do
  IO.puts("  [#{m.type}, importance: #{m.importance}] #{m.content}")
end

run_count = result3.context.deps[:memory_config][:_run_count]
IO.puts("\nReflection runs completed: #{run_count}")
IO.puts("Done!")

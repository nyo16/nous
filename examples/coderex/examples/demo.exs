# Coderex Demo Script
#
# This script demonstrates the Coderex code agent.
#
# Usage:
#   cd examples/coderex
#   mix run examples/demo.exs
#
# Make sure you have ANTHROPIC_API_KEY set in your environment.

IO.puts("""
===============================================
        Coderex - Code Agent Demo
===============================================
""")

# Create a temporary directory for the demo
demo_dir = Path.join(System.tmp_dir!(), "coderex_demo_#{:rand.uniform(10000)}")
File.mkdir_p!(demo_dir)

IO.puts("Demo directory: #{demo_dir}\n")

# Create the agent
# You can use other models like:
#   - "openai:gpt-4"
#   - "anthropic:claude-sonnet-4-20250514"
#   - "lmstudio:qwen/qwen3-30b" (local)
agent = Coderex.new("anthropic:claude-sonnet-4-20250514",
  model_settings: %{temperature: 0.2, max_tokens: 4096}
)

IO.puts("Agent created. Running coding task...\n")
IO.puts("─" |> String.duplicate(50))

# Run a simple coding task
task = """
Create a simple Elixir module called `Calculator` in `lib/calculator.ex` that has:
1. An `add/2` function that adds two numbers
2. A `subtract/2` function that subtracts two numbers
3. A `multiply/2` function that multiplies two numbers
4. A `divide/2` function that divides two numbers (handle division by zero)

After creating the file, read it back and confirm the contents.
"""

case Coderex.run(agent, task, cwd: demo_dir) do
  {:ok, result} ->
    IO.puts("\n" <> "─" |> String.duplicate(50))
    IO.puts("\n📝 Agent Response:\n")
    IO.puts(result.output)
    IO.puts("\n" <> "─" |> String.duplicate(50))
    IO.puts("\n📊 Stats:")
    IO.puts("  • Iterations: #{result.iterations}")
    IO.puts("  • Tool calls: #{result.usage.tool_calls}")
    IO.puts("  • Total tokens: #{result.usage.total_tokens}")

    # Check if the file was created
    calculator_path = Path.join([demo_dir, "lib", "calculator.ex"])
    if File.exists?(calculator_path) do
      IO.puts("\n✅ File created successfully at: #{calculator_path}")
      IO.puts("\nFile contents:")
      IO.puts("─" |> String.duplicate(50))
      IO.puts(File.read!(calculator_path))
    else
      IO.puts("\n❌ File was not created")
    end

  {:error, error} ->
    IO.puts("\n❌ Error: #{inspect(error)}")
end

IO.puts("\n" <> "─" |> String.duplicate(50))
IO.puts("Demo complete!")
IO.puts("Demo files are in: #{demo_dir}")
IO.puts("You can delete them with: rm -rf #{demo_dir}")

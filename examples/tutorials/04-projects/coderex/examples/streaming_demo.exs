# Coderex Streaming Demo
#
# This script demonstrates streaming output from the Coderex code agent.
#
# Usage:
#   cd examples/coderex
#   mix run examples/streaming_demo.exs

IO.puts("""
===============================================
     Coderex - Streaming Demo
===============================================
""")

# Create a temporary directory
demo_dir = Path.join(System.tmp_dir!(), "coderex_stream_#{:rand.uniform(10000)}")
File.mkdir_p!(demo_dir)

IO.puts("Demo directory: #{demo_dir}\n")

# Create the agent
agent = Coderex.new("anthropic:claude-sonnet-4-20250514",
  model_settings: %{temperature: 0.2}
)

IO.puts("Running with streaming output...\n")
IO.puts("─" |> String.duplicate(50) <> "\n")

task = """
Create a simple "Hello World" module in `lib/hello.ex` with a `greet/1` function
that takes a name and returns a greeting message.
"""

case Coderex.run_stream(agent, task, cwd: demo_dir) do
  {:ok, stream} ->
    # Process the stream
    final_result = stream
    |> Stream.each(fn event ->
      case event do
        {:text_delta, text} ->
          IO.write(text)

        {:tool_call, call} ->
          IO.puts("\n\n🔧 Tool: #{call.name}")
          IO.puts("   Args: #{inspect(call.arguments, pretty: true, limit: 200)}")

        {:tool_result, result} ->
          case result do
            %{error: error} ->
              IO.puts("   ❌ Error: #{error}")
            _ ->
              IO.puts("   ✅ Success")
          end

        {:complete, result} ->
          result

        _ ->
          :ok
      end
    end)
    |> Enum.to_list()
    |> List.last()

    IO.puts("\n\n" <> "─" |> String.duplicate(50))

    case final_result do
      {:complete, result} ->
        IO.puts("\n📊 Stats:")
        IO.puts("  • Iterations: #{result.iterations}")
        IO.puts("  • Tool calls: #{result.usage.tool_calls}")
        IO.puts("  • Total tokens: #{result.usage.total_tokens}")

      _ ->
        IO.puts("\nStream completed")
    end

  {:error, error} ->
    IO.puts("❌ Error: #{inspect(error)}")
end

IO.puts("\nDemo files are in: #{demo_dir}")

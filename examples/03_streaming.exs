#!/usr/bin/env elixir

# Nous AI - Streaming Responses
# See AI responses in real-time as they're generated

IO.puts("=== Nous AI - Streaming Demo ===\n")

agent = Nous.new("lmstudio:qwen3",
  instructions: "You are helpful. Explain concepts clearly."
)

# ============================================================================
# Basic Streaming
# ============================================================================

IO.puts("--- Basic Streaming ---")
IO.puts("Question: Explain recursion in 3 sentences.\n")

{:ok, stream} = Nous.run_stream(agent, "Explain recursion in 3 sentences.")

stream
|> Enum.each(fn event ->
  case event do
    {:text_delta, text} -> IO.write(text)
    {:finish, result} ->
      IO.puts("\n\n[Done - #{result.usage.total_tokens} tokens]")
    {:error, reason} -> IO.puts("\n[Error: #{inspect(reason)}]")
    _ -> :ok
  end
end)

IO.puts("")

# ============================================================================
# Streaming with State Tracking
# ============================================================================

IO.puts("--- Streaming with Stats ---")
IO.puts("Question: List 5 benefits of functional programming.\n")

defmodule StreamTracker do
  def process(stream) do
    start_time = System.monotonic_time(:millisecond)

    final_state = stream
    |> Enum.reduce(%{text: "", chunks: 0}, fn event, state ->
      case event do
        {:text_delta, text} ->
          IO.write(text)
          %{state | text: state.text <> text, chunks: state.chunks + 1}

        {:finish, result} ->
          duration = System.monotonic_time(:millisecond) - start_time
          IO.puts("\n")
          IO.puts("[Stats: #{state.chunks} chunks, #{duration}ms, #{result.usage.total_tokens} tokens]")
          state

        _ -> state
      end
    end)

    final_state
  end
end

{:ok, stream} = Nous.run_stream(agent, "List 5 benefits of functional programming.")
StreamTracker.process(stream)

IO.puts("")

# ============================================================================
# Streaming with Tools
# ============================================================================

IO.puts("--- Streaming with Tools ---")

get_weather = fn _ctx, %{"city" => city} ->
  %{city: city, temp: 72, conditions: "sunny"}
end

agent_with_tools = Nous.new("lmstudio:qwen3",
  instructions: "You have a weather tool. Use it when asked about weather.",
  tools: [get_weather]
)

IO.puts("Question: What's the weather in Tokyo?\n")

{:ok, stream} = Nous.run_stream(agent_with_tools, "What's the weather in Tokyo?")

stream
|> Enum.each(fn event ->
  case event do
    {:text_delta, text} -> IO.write(text)
    {:tool_call, call} -> IO.puts("\n[Tool: #{call.name}]")
    {:tool_result, result} -> IO.puts("[Result: #{inspect(result.result)}]")
    {:finish, _} -> IO.puts("\n[Done]")
    _ -> :ok
  end
end)

# ============================================================================
# Alternative: Use Callbacks (v0.8.0)
# ============================================================================

IO.puts("\n--- Alternative: Callbacks ---")
IO.puts("Same result using callbacks option:\n")

{:ok, _result} = Nous.run(agent, "What is 2+2?",
  callbacks: %{
    on_llm_new_delta: fn _event, delta -> IO.write(delta) end,
    on_llm_new_message: fn _event, _msg -> IO.puts("\n[Complete]") end
  }
)

IO.puts("\nNext: mix run examples/04_conversation.exs")

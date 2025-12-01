#!/usr/bin/env elixir

# Yggdrasil AI - Streaming Responses Example
# See AI responses in real-time as they're generated

IO.puts("🌊 Streaming Response Demo")
IO.puts("Watch the AI response appear word by word in real-time!")
IO.puts("")

# ============================================================================
# Agent Setup
# ============================================================================

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You are a helpful assistant.
  Provide detailed explanations with examples.
  Think step by step when explaining complex topics.
  """,
  model_settings: %{
    temperature: 0.7,
    max_tokens: -1
  }
)

# ============================================================================
# Example 1: Basic Streaming - Just Print Text
# ============================================================================

IO.puts("📝 Question: Explain how machine learning works in simple terms")
IO.puts("🤖 AI Response (streaming live):")
IO.puts("")

start_time = System.monotonic_time(:millisecond)
total_chars = 0

case Yggdrasil.run_stream(agent, "Explain how machine learning works in simple terms, including examples.") do
  {:ok, stream} ->
    stream
    |> Stream.each(fn event ->
      case event do
        {:text_delta, text_chunk} ->
          # Print each chunk as it arrives
          IO.write(text_chunk)
          total_chars = total_chars + String.length(text_chunk)

        {:finish, result} ->
          end_time = System.monotonic_time(:millisecond)
          duration = end_time - start_time

          IO.puts("\n")
          IO.puts("⚡ Streaming complete!")
          IO.puts("📊 Performance:")
          IO.puts("   Duration: #{duration}ms")
          IO.puts("   Characters: #{total_chars}")
          IO.puts("   Speed: #{Float.round(total_chars / (duration / 1000), 1)} chars/sec")
          IO.puts("   Tokens: #{result.usage.input_tokens} in + #{result.usage.output_tokens} out")

        {:error, reason} ->
          IO.puts("\n❌ Stream error: #{inspect(reason)}")

        other ->
          IO.puts("\n🔧 Other event: #{inspect(other)}")
      end
    end)
    |> Stream.run()

  {:error, reason} ->
    IO.puts("❌ Failed to start stream: #{inspect(reason)}")
end

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Example 2: Advanced Streaming with State Tracking
# ============================================================================

defmodule StreamTracker do
  @doc """
  Track streaming statistics and handle different event types
  """
  def process_stream(stream) do
    initial_state = %{
      text: "",
      chunks: 0,
      start_time: System.monotonic_time(:millisecond),
      events: []
    }

    stream
    |> Enum.reduce(initial_state, fn event, state ->
      handle_event(event, state)
    end)
  end

  defp handle_event({:text_delta, text}, state) do
    IO.write(text)

    %{
      state |
      text: state.text <> text,
      chunks: state.chunks + 1
    }
  end

  defp handle_event({:finish, result}, state) do
    end_time = System.monotonic_time(:millisecond)
    duration = end_time - state.start_time

    IO.puts("\n")
    IO.puts("🎯 Advanced Stream Stats:")
    IO.puts("   Text chunks: #{state.chunks}")
    IO.puts("   Average chunk size: #{Float.round(String.length(state.text) / state.chunks, 1)} chars")
    IO.puts("   Words generated: #{length(String.split(state.text))}")
    IO.puts("   Lines generated: #{length(String.split(state.text, "\n"))}")

    if result do
      IO.puts("   Cost estimate: ~$#{estimate_cost(result.usage)}")
    end

    state
  end

  defp handle_event({:error, reason}, state) do
    IO.puts("\n❌ Stream error: #{inspect(reason)}")
    state
  end

  defp handle_event({event_type, data}, state) do
    IO.puts("\n🔧 Event [#{event_type}]: #{inspect(data)}")
    %{state | events: [event_type | state.events]}
  end

  defp estimate_cost(usage) do
    # Rough cost estimate (varies by provider)
    input_cost = usage.input_tokens * 0.00001  # ~$0.01 per 1K tokens
    output_cost = usage.output_tokens * 0.00003  # ~$0.03 per 1K tokens
    Float.round(input_cost + output_cost, 4)
  end
end

IO.puts("🧠 Question: Describe the benefits of AI agents with examples")
IO.puts("🤖 AI Response (with advanced tracking):")
IO.puts("")

case Yggdrasil.run_stream(agent, "Describe the benefits of AI agents with real-world examples and use cases.") do
  {:ok, stream} ->
    StreamTracker.process_stream(stream)

  {:error, reason} ->
    IO.puts("❌ Failed to start advanced stream: #{inspect(reason)}")
end

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Example 3: Buffered Streaming (Better for UIs)
# ============================================================================

defmodule BufferedStreaming do
  @doc """
  Buffer streaming chunks for smoother UI updates.
  Useful for web interfaces where too many updates can be jarring.
  """
  def stream_with_buffer(stream, buffer_size \\ 50) do
    stream
    |> Enum.reduce([], fn event, buffer ->
      case event do
        {:text_delta, text} ->
          new_buffer = buffer ++ [text]
          buffer_text = Enum.join(new_buffer)

          if String.length(buffer_text) >= buffer_size do
            # Flush buffer when it reaches size
            IO.write(buffer_text)
            []
          else
            new_buffer
          end

        {:finish, result} ->
          # Flush remaining buffer
          if buffer != [] do
            IO.write(Enum.join(buffer))
          end

          IO.puts("\n🔄 Buffered streaming complete!")
          if result, do: IO.puts("   Tokens: #{result.usage.total_tokens}")
          []

        {:error, reason} ->
          IO.puts("\n❌ Buffered stream error: #{inspect(reason)}")
          []

        _ ->
          buffer
      end
    end)
  end
end

IO.puts("📦 Question: What is the future of AI technology?")
IO.puts("🤖 AI Response (buffered for smooth UI updates):")
IO.puts("")

case Yggdrasil.run_stream(agent, "What do you think the future of AI technology looks like? Include potential impacts on society.") do
  {:ok, stream} ->
    BufferedStreaming.stream_with_buffer(stream, 30)

  {:error, reason} ->
    IO.puts("❌ Failed to start buffered stream: #{inspect(reason)}")
end

IO.puts("")
IO.puts(String.duplicate("=", 60))

# ============================================================================
# Streaming Best Practices
# ============================================================================

IO.puts("")
IO.puts("💡 Streaming Best Practices:")
IO.puts("")
IO.puts("✅ Use streaming for:")
IO.puts("   • Chat interfaces")
IO.puts("   • Long-form content generation")
IO.puts("   • Real-time user feedback")
IO.puts("   • Reducing perceived latency")
IO.puts("")
IO.puts("⚠️  Consider buffering for:")
IO.puts("   • Web UIs (avoid excessive DOM updates)")
IO.puts("   • Mobile apps (smooth animations)")
IO.puts("   • Network optimization")
IO.puts("")
IO.puts("🔧 Handle errors gracefully:")
IO.puts("   • Network interruptions")
IO.puts("   • API rate limits")
IO.puts("   • Malformed responses")
IO.puts("")
IO.puts("📱 UI Integration tips:")
IO.puts("   • Show typing indicators")
IO.puts("   • Allow cancellation")
IO.puts("   • Handle reconnection")
IO.puts("   • Buffer for smooth updates")

# ============================================================================
# Next Steps
# ============================================================================

IO.puts("")
IO.puts("🚀 Next Steps:")
IO.puts("1. Try changing the questions above")
IO.puts("2. Experiment with different buffer sizes")
IO.puts("3. See templates/streaming_agent.exs for more patterns")
IO.puts("4. Check liveview_agent_example.ex for web integration")
IO.puts("5. Try conversation_history_example.exs for multi-turn streaming")

# ============================================================================
# Streaming with Tools (Advanced)
# ============================================================================

IO.puts("")
IO.puts("🔧 Advanced: Streaming + Tools")
IO.puts("Want to see AI use tools while streaming responses?")
IO.puts("Run: mix run examples/with_tools_working.exs")
IO.puts("Or try the ReAct agent: mix run examples/react_agent_demo.exs")
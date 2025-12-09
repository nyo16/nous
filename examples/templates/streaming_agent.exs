#!/usr/bin/env elixir

# Nous Streaming Agent Template
# Shows how to get real-time responses as they're generated

# ============================================================================
# Configuration - Edit these values
# ============================================================================

# Choose your model
model = "lmstudio:qwen/qwen3-30b"

# Instructions
instructions = """
You are a helpful assistant.
Provide detailed, informative responses.
Think step by step when explaining complex topics.
"""

# Prompt that will generate a longer response (better for seeing streaming)
prompt = "Explain how machine learning works in simple terms, including the main types of ML and some real-world examples."

# ============================================================================
# Streaming Response Handler
# ============================================================================

defmodule StreamHandler do
  @doc """
  Handle streaming events as they arrive.
  This function processes each chunk of the response in real-time.
  """
  def handle_stream_event(event, state \\ %{text: "", start_time: nil})

  # Text delta - new text chunk received
  def handle_stream_event({:text_delta, text_chunk}, state) do
    # Print text as it arrives (no newline to keep it flowing)
    IO.write(text_chunk)

    # Track timing if this is the first chunk
    start_time = state.start_time || System.monotonic_time(:millisecond)

    # Update accumulated text
    new_state = %{
      text: state.text <> text_chunk,
      start_time: start_time
    }

    new_state
  end

  # Stream finished
  def handle_stream_event({:finish, final_result}, state) do
    end_time = System.monotonic_time(:millisecond)
    duration = end_time - state.start_time

    IO.puts("\n")
    IO.puts("⚡ Stream complete!")
    IO.puts("📊 Stats:")
    IO.puts("  Duration: #{duration}ms")
    IO.puts("  Characters: #{String.length(state.text)}")
    IO.puts("  Speed: #{Float.round(String.length(state.text) / (duration / 1000), 1)} chars/sec")

    if final_result do
      IO.puts("  Input tokens: #{final_result.usage.input_tokens}")
      IO.puts("  Output tokens: #{final_result.usage.output_tokens}")
    end

    state
  end

  # Error occurred
  def handle_stream_event({:error, reason}, state) do
    IO.puts("\n❌ Stream error: #{inspect(reason)}")
    state
  end

  # Other events (tool calls, etc.)
  def handle_stream_event({event_type, data}, state) do
    IO.puts("\n🔧 Event: #{event_type} - #{inspect(data)}")
    state
  end
end

# ============================================================================
# Agent Creation and Streaming
# ============================================================================

# Create the agent
agent = Nous.new(model,
  instructions: instructions,
  model_settings: %{
    temperature: 0.7,
    max_tokens: -1
  }
)

IO.puts("🌊 Starting streaming response...")
IO.puts("📝 Prompt: #{prompt}")
IO.puts("⏳ Response (live):")
IO.puts("")

# Method 1: Simple streaming (just print text as it arrives)
simple_streaming = fn ->
  case Nous.run_stream(agent, prompt) do
    {:ok, stream} ->
      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:finish, _result} -> IO.puts("\n✅ Stream complete!")
        {:error, reason} -> IO.puts("\n❌ Error: #{inspect(reason)}")
        _ -> :ok
      end)
      |> Stream.run()

    {:error, reason} ->
      IO.puts("❌ Failed to start stream: #{inspect(reason)}")
  end
end

# Method 2: Advanced streaming with state tracking
advanced_streaming = fn ->
  case Nous.run_stream(agent, prompt) do
    {:ok, stream} ->
      # Process stream with our custom handler
      stream
      |> Enum.reduce(%{text: "", start_time: nil}, &StreamHandler.handle_stream_event/2)

    {:error, reason} ->
      IO.puts("❌ Failed to start stream: #{inspect(reason)}")
  end
end

# Choose which method to use:
# simple_streaming.()      # Uncomment for simple approach
advanced_streaming.()    # Comment out for simple approach

# ============================================================================
# Streaming Best Practices
# ============================================================================

# Tips for effective streaming:
#
# 1. **Buffer management**: For UIs, consider buffering chunks to avoid
#    excessive updates
#
# 2. **Error handling**: Always handle stream errors gracefully
#
# 3. **User feedback**: Show loading states and progress indicators
#
# 4. **Cancellation**: Allow users to stop long-running streams
#
# 5. **Fallback**: Have a non-streaming fallback for unreliable connections

# Example: Buffered streaming for UIs
buffered_streaming_example = fn ->
  buffer = []
  buffer_size = 50  # characters

  case Nous.run_stream(agent, prompt) do
    {:ok, stream} ->
      stream
      |> Enum.reduce(buffer, fn event, acc ->
        case event do
          {:text_delta, text} ->
            new_buffer = acc ++ [text]

            # Flush buffer when it reaches size
            if Enum.join(new_buffer) |> String.length() >= buffer_size do
              IO.write(Enum.join(new_buffer))
              []
            else
              new_buffer
            end

          {:finish, _} ->
            # Flush remaining buffer
            if acc != [] do
              IO.write(Enum.join(acc))
            end
            IO.puts("\n✅ Complete!")
            []

          _ -> acc
        end
      end)

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end
end

# Uncomment to try buffered streaming:
# IO.puts("\n" <> String.duplicate("=", 50))
# IO.puts("Buffered streaming example:")
# buffered_streaming_example.()

# ============================================================================
# Next Steps
# ============================================================================

# Ready for more?
# - conversation_agent.exs    (multi-turn chat)
# - ../by_feature/streaming/ (more streaming examples)
# - ../liveview_agent_example.ex (streaming in web apps)
# Streaming & Real-time Examples

Examples showing real-time responses, streaming patterns, and live updates.

## Learning Path
New to streaming? Follow this progression:
1. **[Basic Streaming](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/01-streaming.exs)** - Simple real-time responses
2. **[LiveView Streaming](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/02-liveview-streaming.ex)** - Web UI integration
3. **[Advanced Patterns](https://github.com/nyo16/nous/blob/master/examples/liveview_chat_example.ex)** - Production chat systems

## Basic Streaming

### Simple Real-time Responses
- **[01-streaming.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/01-streaming.exs)** - Basic streaming example
- **[streaming_example.exs](https://github.com/nyo16/nous/blob/master/examples/streaming_example.exs)** - Real-time text generation
- Text appears as it's generated, not all at once

### Stream Event Handling
```elixir
# Basic streaming pattern
Nous.run_stream(agent, prompt)
|> Enum.reduce("", fn event, acc ->
  case event do
    {:text_delta, text} ->
      IO.write(text)  # Print as it arrives
      acc <> text
    {:finish, result} ->
      IO.puts("\n✅ Complete: #{result.usage.total_tokens} tokens")
      acc
  end
end)
```

## Web Integration

### Phoenix LiveView
- **[02-liveview-streaming.ex](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/02-liveview-streaming.ex)** - LiveView streaming
- **[liveview_agent_example.ex](https://github.com/nyo16/nous/blob/master/examples/liveview_agent_example.ex)** - Basic LiveView integration
- **[liveview_chat_example.ex](https://github.com/nyo16/nous/blob/master/examples/liveview_chat_example.ex)** - Complete chat interface

### LiveView Chat Patterns
- **[LiveView Chat Example](https://github.com/nyo16/nous/blob/master/examples/liveview_chat_example.ex)** - Complete chat implementation
- **[LiveView Integration Guide](liveview_integration.html)** - General integration patterns

## Advanced Streaming

### Stream State Management
```elixir
# Accumulating streamed content with state
{messages, final_result} =
  Nous.run_stream(agent, prompt)
  |> Enum.reduce({[], ""}, fn event, {msgs, content} ->
    case event do
      {:text_delta, text} ->
        # Update UI incrementally
        send(self(), {:stream_update, content <> text})
        {msgs, content <> text}
      {:finish, result} ->
        # Final state with complete message
        final_msgs = msgs ++ [%{role: "assistant", content: content}]
        {final_msgs, content}
    end
  end)
```

### Buffered Streaming
```elixir
# Buffer chunks for smoother UI updates
buffer_size = 10
Nous.run_stream(agent, prompt)
|> Stream.chunk_every(buffer_size)
|> Enum.each(fn events ->
  text = events
  |> Enum.filter(&match?({:text_delta, _}, &1))
  |> Enum.map_join("", fn {:text_delta, text} -> text end)

  send(self(), {:stream_chunk, text})
end)
```

## Production Streaming

### Error Handling
```elixir
# Robust streaming with error handling
try do
  Nous.run_stream(agent, prompt)
  |> Stream.map(fn
    {:text_delta, text} -> {:ok, text}
    {:finish, result} -> {:complete, result}
    {:error, error} -> {:error, error}
  end)
  |> Enum.reduce_while("", fn
    {:ok, text}, acc ->
      {:cont, acc <> text}
    {:complete, _result}, acc ->
      {:halt, acc}
    {:error, error}, _acc ->
      {:halt, {:error, error}}
  end)
rescue
  error -> {:error, "Streaming failed: #{inspect(error)}"}
end
```

### Stream Cancellation
- **[cancellation_demo.exs](https://github.com/nyo16/nous/blob/master/examples/cancellation_demo.exs)** - Cancelling long-running streams
- Useful for user-initiated stops or timeouts

### WebSocket Integration
```elixir
# Streaming to WebSocket clients
def handle_info({:stream_update, text}, socket) do
  push_event(socket, "stream_update", %{text: text})
  {:noreply, socket}
end

# JavaScript side
window.addEventListener("phx:stream_update", (e) => {
  document.getElementById("output").textContent += e.detail.text;
});
```

## Streaming Patterns

### Real-time Chat
- Message-by-message streaming
- Typing indicators during generation
- User can interrupt/cancel responses

### Live Document Generation
- Code streaming for development tools
- Document writing with real-time preview
- Interactive content creation

### Monitoring & Dashboards
- Real-time metric updates
- Log streaming and analysis
- System status updates

## Performance Considerations

### Stream Optimization
- **Buffer chunks** for smoother UI (10-50 characters)
- **Debounce updates** to avoid UI thrashing
- **Cancel streams** when user navigates away
- **Handle backpressure** in high-volume scenarios

### Token Usage
- Streaming doesn't change token costs
- Monitor `usage.total_tokens` in `:finish` event
- Same pricing as non-streaming requests

## Troubleshooting Streaming

### Common Issues
- **No stream events**: Check if provider supports streaming
- **Incomplete responses**: Handle `:finish` event properly
- **UI lag**: Buffer chunks or debounce updates
- **Memory leaks**: Ensure streams are consumed fully

### Debug Streaming
```elixir
# Log all stream events
Nous.run_stream(agent, prompt)
|> Enum.each(fn event ->
  IO.inspect(event, label: "Stream Event")
end)
```

---

**Next Steps:**
- Start with [01-streaming.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/02-patterns/01-streaming.exs)
- Try [LiveView streaming](https://github.com/nyo16/nous/blob/master/examples/tutorials/03-production/02-liveview-streaming.ex) for web apps
- Read the [LiveView Integration Guide](liveview_integration.html)

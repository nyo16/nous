#!/usr/bin/env elixir

# Test provider format conversion with our new Message system
alias Nous.{Message, Messages}

IO.puts("🔄 Testing Provider Format Conversion")
IO.puts("=" <> String.duplicate("=", 50))

# Create a sample conversation using new Message structs
conversation = [
  Message.system("You are a helpful coding assistant. Always provide clear examples."),
  Message.user("How do I create a list in Elixir?"),
  Message.assistant("You can create lists in Elixir using square brackets: `[1, 2, 3]`",
    tool_calls: [%{
      "id" => "call_123",
      "name" => "code_example",
      "arguments" => %{"language" => "elixir", "code" => "[1, 2, 3]"}
    }]
  ),
  Message.tool("call_123", "Example executed successfully")
]

IO.puts("📋 Original conversation:")
Enum.with_index(conversation, 1)
|> Enum.each(fn {msg, i} ->
  IO.puts("  #{i}. #{msg.role}: #{String.slice(Message.extract_text(msg), 0, 50)}...")
  if Message.has_tool_calls?(msg) do
    IO.puts("     └─ Tool calls: #{length(msg.tool_calls)}")
  end
end)

# Test OpenAI format conversion
IO.puts("\n🔵 Converting to OpenAI format:")
openai_messages = Messages.to_openai_format(conversation)
Enum.with_index(openai_messages, 1)
|> Enum.each(fn {msg, i} ->
  role = Map.get(msg, :role) || Map.get(msg, "role")
  content_preview = case Map.get(msg, :content) || Map.get(msg, "content") do
    content when is_binary(content) -> String.slice(content, 0, 40) <> "..."
    content -> inspect(content)
  end
  IO.puts("  #{i}. #{role}: #{content_preview}")

  # Check for tool calls
  tool_calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls) || []
  if length(tool_calls) > 0 do
    IO.puts("     └─ Tool calls: #{length(tool_calls)}")
  end
end)

# Test Anthropic format conversion
IO.puts("\n🟠 Converting to Anthropic format:")
{system_prompt, anthropic_messages} = Messages.to_anthropic_format(conversation)
IO.puts("  System: #{String.slice(system_prompt || "none", 0, 50)}...")
Enum.with_index(anthropic_messages, 1)
|> Enum.each(fn {msg, i} ->
  content = Map.get(msg, "content", "")
  content_preview = case content do
    content when is_binary(content) -> String.slice(content, 0, 40) <> "..."
    content when is_list(content) ->
      text_parts = Enum.filter(content, &(Map.get(&1, "type") == "text"))
      text = Enum.map_join(text_parts, " ", &Map.get(&1, "text", ""))
      String.slice(text, 0, 40) <> "..."
    content ->
      (inspect(content) |> String.slice(0, 40)) <> "..."
  end
  IO.puts("  #{i}. #{Map.get(msg, "role")}: #{content_preview}")
end)

# Test Gemini format conversion
IO.puts("\n🔴 Converting to Gemini format:")
{gemini_system, gemini_contents} = Messages.to_gemini_format(conversation)
IO.puts("  System: #{String.slice(gemini_system || "none", 0, 50)}...")
Enum.with_index(gemini_contents, 1)
|> Enum.each(fn {content, i} ->
  parts = Map.get(content, "parts", [])
  role = Map.get(content, "role", "unknown")
  IO.puts("  #{i}. #{role}: #{length(parts)} parts")
end)

# Test normalization round-trip
IO.puts("\n🔄 Testing format normalization:")
test_openai_message = %{
  "role" => "user",
  "content" => "Test message for normalization"
}

normalized = Messages.normalize_format([test_openai_message])
IO.puts("Normalized OpenAI message: #{inspect(hd(normalized))}")

# Test message utilities with our conversation
IO.puts("\n📊 Message Analysis:")
IO.puts("Total messages: #{length(conversation)}")
IO.puts("Tool-related messages: #{length(Enum.filter(conversation, &Message.is_tool_related?/1))}")
IO.puts("Assistant messages: #{length(Messages.find_by_role(conversation, :assistant))}")
IO.puts("Total tool calls: #{length(Messages.extract_tool_calls(conversation))}")

IO.puts("\n✅ Format conversion testing completed!")
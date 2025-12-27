#!/usr/bin/env elixir

# Test response parsing and multi-modal content with our new Message system
alias Nous.{Message, Messages}
alias Nous.Message.ContentPart

IO.puts("🔍 Testing Response Parsing & Multi-Modal Content")
IO.puts("=" <> String.duplicate("=", 55))

# Test 1: Multi-modal content creation
IO.puts("\n📱 Test 1: Creating multi-modal messages")

multimodal_message = Message.user([
  ContentPart.text("Here's some code and an image: "),
  ContentPart.text("```elixir\ndefmodule Test do\n  def hello, do: :world\nend\n```")
])

IO.puts("Multi-modal message content: #{Message.extract_text(multimodal_message)}")
IO.puts("Content parts in metadata: #{inspect(Message.get_metadata(multimodal_message, :content_parts))}")

# Test 2: Test response parsing with a mock OpenAI-style response
IO.puts("\n🔄 Test 2: Testing response parsing")

mock_response = %{
  "choices" => [
    %{
      "message" => %{
        "role" => "assistant",
        "content" => "Here's how to create a list in Elixir:",
        "tool_calls" => [
          %{
            "id" => "call_abc123",
            "type" => "function",
            "function" => %{
              "name" => "show_code",
              "arguments" => "{\"code\": \"[1, 2, 3, 4]\"}"
            }
          }
        ]
      }
    }
  ],
  "usage" => %{
    "prompt_tokens" => 15,
    "completion_tokens" => 25,
    "total_tokens" => 40
  },
  "model" => "qwen3-4b-thinking-2507-mlx"
}

parsed_message = Messages.from_openai_response(mock_response)
IO.puts("Parsed response:")
IO.puts("  Role: #{parsed_message.role}")
IO.puts("  Content: #{parsed_message.content}")
IO.puts("  Tool calls: #{length(parsed_message.tool_calls)}")
IO.puts("  Usage: #{inspect(parsed_message.metadata.usage)}")
IO.puts("  Model: #{parsed_message.metadata.model_name}")

# Test 3: Make actual request to LMStudio and parse response
IO.puts("\n🌐 Test 3: Live request to LMStudio")

# Create a conversation using Message structs
conversation = [
  Message.system("You are a helpful assistant. Be brief and informative."),
  Message.user("What are the benefits of functional programming? Give me 2 key points.")
]

# Convert to OpenAI format for the request
openai_format = Messages.to_openai_format(conversation)

# Prepare the request body
request_body = %{
  "model" => "qwen3-4b-thinking-2507-mlx",
  "messages" => Enum.map(openai_format, fn msg ->
    %{
      "role" => Map.get(msg, :role),
      "content" => Map.get(msg, :content)
    }
  end),
  "temperature" => 0.7,
  "max_tokens" => 150,
  "stream" => false
} |> Jason.encode!()

IO.puts("📤 Sending request to LMStudio...")
IO.puts("Request preview: #{String.slice(request_body, 0, 200)}...")

# Make the request using curl (simpler for this test)
curl_result = System.cmd("curl", [
  "-s",
  "http://localhost:1234/v1/chat/completions",
  "-H", "Content-Type: application/json",
  "-d", request_body
])

case curl_result do
  {response_json, 0} ->
    try do
      response = Jason.decode!(response_json)

      # Parse the response using our new system
      parsed = Messages.from_openai_response(response)

      IO.puts("\n✅ Response received and parsed:")
      IO.puts("📥 Content: #{parsed.content}")
      IO.puts("📊 Tokens used: #{parsed.metadata.usage.total_tokens}")
      IO.puts("🤖 Model: #{parsed.metadata.model_name}")
      IO.puts("🏷️  Role: #{parsed.role}")

      # Test message classification
      IO.puts("\n🔍 Message classification:")
      IO.puts("  From assistant? #{Message.from_assistant?(parsed)}")
      IO.puts("  Has tool calls? #{Message.has_tool_calls?(parsed)}")
      IO.puts("  Tool-related? #{Message.is_tool_related?(parsed)}")

    rescue
      e -> IO.puts("❌ Failed to parse response: #{inspect(e)}")
    end

  {error, _code} ->
    IO.puts("❌ Request failed: #{error}")
end

# Test 4: Legacy format compatibility
IO.puts("\n🔄 Test 4: Legacy format conversion")

legacy_messages = [
  {:system_prompt, "You are helpful"},
  {:user_prompt, "Hello!"},
  {:tool_return, %{call_id: "call_123", result: "Success"}}
]

IO.puts("Legacy format: #{inspect(legacy_messages)}")

converted = Enum.map(legacy_messages, &Message.from_legacy/1)
IO.puts("Converted to Message structs:")
Enum.each(converted, fn msg ->
  IO.puts("  #{msg.role}: #{Message.extract_text(msg)}")
end)

IO.puts("\n🎉 Response parsing tests completed!")
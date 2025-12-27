#!/usr/bin/env elixir

# Test multi-modal functionality with vision models using our new Message system
alias Nous.{Agent, AgentRunner, Message, Messages}
alias Nous.Message.ContentPart

IO.puts("👁️ Testing Multi-Modal Vision with LMStudio")
IO.puts("=" <> String.duplicate("=", 50))

# Test 1: Create multi-modal message with our ContentPart system
IO.puts("\n📸 Test 1: Creating multi-modal messages")

# Test our new image conversion utilities
IO.puts("🔧 Testing image conversion utilities:")

# Create a test image using our utility
test_image_part = ContentPart.test_image()
IO.puts("  Test image created: #{String.slice(test_image_part.content, 0, 50)}...")

# Test MIME type detection
IO.puts("  MIME type for .jpg: #{ContentPart.detect_mime_type("photo.jpg")}")
IO.puts("  MIME type for .png: #{ContentPart.detect_mime_type("image.png")}")

# Test base64 conversion
sample_binary = <<137, 80, 78, 71, 13, 10, 26, 10>>
data_url = ContentPart.to_data_url(sample_binary, "image/png")
IO.puts("  Binary to data URL: #{String.slice(data_url, 0, 50)}...")

multimodal_message = Message.user([
  ContentPart.text("What do you see in this image? Please describe it."),
  test_image_part
])

IO.puts("Multi-modal message created:")
IO.puts("  Role: #{multimodal_message.role}")
IO.puts("  Content (text): #{Message.extract_text(multimodal_message)}")
IO.puts("  Content parts: #{length(Message.get_metadata(multimodal_message, :content_parts) || [])}")

# Test 2: Convert to OpenAI format and inspect
IO.puts("\n🔄 Test 2: Converting to OpenAI format")

conversation = [
  Message.system("You are a helpful vision assistant. Analyze images carefully and describe what you see."),
  multimodal_message
]

openai_format = Messages.to_openai_format(conversation)
IO.puts("Converted to OpenAI format:")
Enum.with_index(openai_format, 1)
|> Enum.each(fn {msg, i} ->
  role = Map.get(msg, :role)
  content = Map.get(msg, :content)

  IO.puts("  #{i}. #{role}:")
  case content do
    content when is_binary(content) ->
      IO.puts("    Text: #{String.slice(content, 0, 50)}...")
    content when is_list(content) ->
      IO.puts("    Multi-modal content with #{length(content)} parts:")
      Enum.each(content, fn part ->
        case Map.get(part, "type") do
          "text" -> IO.puts("      - Text: #{String.slice(Map.get(part, "text", ""), 0, 30)}...")
          "image_url" -> IO.puts("      - Image: #{String.slice(Map.get(part, "image_url", %{}) |> Map.get("url", ""), 0, 30)}...")
          other -> IO.puts("      - #{other}")
        end
      end)
    _ ->
      IO.puts("    Other: #{inspect(content)}")
  end
end)

# Test 3: Make actual request to LMStudio vision model
IO.puts("\n🤖 Test 3: Testing with LMStudio Vision Model")

model = "lmstudio:qwen3-vl-8b-thinking"
agent = Agent.new(model,
  instructions: "You are a helpful vision assistant. Analyze images carefully and describe exactly what you see. Be specific and detailed.",
  model_settings: %{
    base_url: "http://localhost:1234/v1",
    temperature: 0.7,
    max_tokens: 200
  }
)

IO.puts("Created vision agent with model: #{model}")

# Test with a simple prompt first (to verify the model switch worked)
simple_prompt = "Can you see images? Just answer yes or no."
IO.puts("\n📤 Testing vision capabilities: #{simple_prompt}")

case AgentRunner.run(agent, simple_prompt) do
  {:ok, result} ->
    IO.puts("\n✅ Vision model response:")
    IO.puts("📥 Response: #{String.slice(result.output, 0, 200)}...")
    IO.puts("📊 Tokens: #{result.usage.total_tokens}")
  {:error, error} ->
    IO.puts("\n❌ Error: #{inspect(error)}")
end

# Test 4: Demonstrate direct API call with multimodal content
IO.puts("\n🌐 Test 4: Direct API call with multimodal content")

# Create the request manually to test multi-modal
request_body = %{
  "model" => "qwen3-vl-8b-thinking",
  "messages" => [
    %{
      "role" => "system",
      "content" => "You are a helpful vision assistant."
    },
    %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => "This is a test image (1x1 pixel). What do you see?"},
        %{"type" => "image_url", "image_url" => %{"url" => test_image_part.content}}
      ]
    }
  ],
  "temperature" => 0.7,
  "max_tokens" => 150,
  "stream" => false
} |> Jason.encode!()

IO.puts("📤 Sending multimodal request to LMStudio...")

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
      parsed = Messages.from_openai_response(response)

      IO.puts("\n✅ Multimodal response received:")
      IO.puts("📥 Content: #{String.slice(parsed.content, 0, 300)}...")
      IO.puts("📊 Tokens: #{parsed.metadata.usage.total_tokens}")
      IO.puts("🤖 Model: #{parsed.metadata.model_name}")
    rescue
      e -> IO.puts("❌ Failed to parse response: #{inspect(e)}")
    end
  {error, _code} ->
    IO.puts("❌ Request failed: #{error}")
end

# Test 5: Show our Message utilities work with multimodal content
IO.puts("\n🔍 Test 5: Message utilities with multimodal content")

test_conversation = [
  Message.system("You are helpful"),
  Message.user([ContentPart.text("Hello"), test_image_part]),
  Message.assistant("I can see your image!")
]

IO.puts("Conversation analysis:")
IO.puts("  Total messages: #{length(test_conversation)}")
IO.puts("  User messages: #{length(Messages.find_by_role(test_conversation, :user))}")
IO.puts("  Text extraction: #{Messages.extract_text(test_conversation) |> Enum.map(&String.slice(&1, 0, 20)) |> inspect}")

multimodal_user = Messages.find_by_role(test_conversation, :user) |> hd()
IO.puts("  Multimodal message content parts: #{length(Message.get_metadata(multimodal_user, :content_parts) || [])}")

IO.puts("\n🎉 Multi-modal vision testing completed!")
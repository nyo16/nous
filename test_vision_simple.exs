#!/usr/bin/env elixir

# Simple vision test using direct API calls with our image utilities
alias Nous.{Message, Messages}
alias Nous.Message.ContentPart

IO.puts("👁️ Simple Vision Test with LMStudio")
IO.puts("=" <> String.duplicate("=", 40))

# Test our image utilities
IO.puts("\n🔧 Testing image conversion utilities:")

# Create test image
test_image = ContentPart.test_image()
IO.puts("✅ Test image: #{String.slice(test_image.content, 0, 40)}...")

# Create a small red square
red_square_data = Base.decode64!(
  "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAG0lEQVR42mP8/5+hnoEJGJ/F/w8D" <>
  "I3gKsgAAMgkKAP7TlpYAAAAASUVORK5CYII="
)
red_square = ContentPart.from_binary(red_square_data, "red.png")
IO.puts("✅ Red square: #{String.slice(red_square.content, 0, 40)}...")

# MIME type detection
IO.puts("✅ MIME detection:")
Enum.each(["test.jpg", "image.png", "file.gif"], fn filename ->
  IO.puts("   #{filename} -> #{ContentPart.detect_mime_type(filename)}")
end)

# Test with vision model
IO.puts("\n🤖 Testing vision with direct API call:")

request_body = %{
  "model" => "qwen3-vl-8b-thinking",
  "messages" => [
    %{
      "role" => "system",
      "content" => "You are a helpful vision assistant. Describe images clearly and briefly."
    },
    %{
      "role" => "user",
      "content" => [
        %{"type" => "text", "text" => "What colors and shapes do you see in this image?"},
        %{"type" => "image_url", "image_url" => %{"url" => red_square.content}}
      ]
    }
  ],
  "temperature" => 0.3,
  "max_tokens" => 100,
  "stream" => false
} |> Jason.encode!()

IO.puts("📤 Sending image to vision model...")

case System.cmd("curl", [
  "-s",
  "http://localhost:1234/v1/chat/completions",
  "-H", "Content-Type: application/json",
  "-d", request_body
]) do
  {response_json, 0} ->
    case Jason.decode(response_json) do
      {:ok, response} ->
        parsed = Messages.from_openai_response(response)
        IO.puts("\n✅ Vision model response:")
        IO.puts("📥 #{String.slice(parsed.content, 0, 300)}...")
        IO.puts("📊 Tokens: #{parsed.metadata.usage.total_tokens}")
        IO.puts("🤖 Model: #{parsed.metadata.model_name}")
      {:error, _} ->
        IO.puts("❌ Failed to parse JSON: #{String.slice(response_json, 0, 200)}...")
    end
  {error, _code} ->
    IO.puts("❌ Request failed: #{error}")
end

# Test Message construction with our utilities
IO.puts("\n📝 Message construction examples:")

# Simple multi-modal message
multimodal_msg = Message.user([
  ContentPart.text("Analyze this image:"),
  red_square
])

IO.puts("✅ Multi-modal message created")
IO.puts("   Role: #{multimodal_msg.role}")
IO.puts("   Content parts: #{length(Message.get_metadata(multimodal_msg, :content_parts))}")
IO.puts("   Text: #{Message.extract_text(multimodal_msg)}")

# Convert to OpenAI format
conversation = [
  Message.system("You are a vision assistant"),
  multimodal_msg
]

openai_format = Messages.to_openai_format(conversation)
user_msg = Enum.at(openai_format, 1)
content = Map.get(user_msg, :content)

IO.puts("✅ Converted to OpenAI format:")
IO.puts("   Content type: #{if is_list(content), do: "multi-modal list", else: "text"}")
if is_list(content) do
  IO.puts("   Parts: #{length(content)}")
  Enum.with_index(content, 1)
  |> Enum.each(fn {part, i} ->
    type = Map.get(part, "type")
    IO.puts("     #{i}. #{type}")
  end)
end

IO.puts("\n🎉 Vision test completed!")
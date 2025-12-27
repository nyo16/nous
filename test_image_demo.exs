#!/usr/bin/env elixir

# Simple demonstration of image utilities and vision with LMStudio
alias Nous.{Agent, AgentRunner, Message, Messages}
alias Nous.Message.ContentPart

IO.puts("🖼️  Simple Image Vision Demo with LMStudio")
IO.puts("=" <> String.duplicate("=", 45))

# Create a simple colored square image (PNG format)
# This is a 2x2 red square in PNG format
red_square_png = Base.decode64!(
  "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAG0lEQVR42mP8/5+hnoEJGJ/F/w8D" <>
  "I3gKsgAAMgkKAP7TlpYAAAAASUVORK5CYII="
)

# Test our image utilities
IO.puts("\n🔧 Testing image utilities:")

# Test from_binary utility
image_part = ContentPart.from_binary(red_square_png, "red_square.png")
IO.puts("✅ Created image from binary data")
IO.puts("   Type: #{image_part.type}")
IO.puts("   Data URL starts with: #{String.slice(image_part.content, 0, 30)}...")

# Test MIME detection
IO.puts("✅ MIME type detection:")
Enum.each([".jpg", ".png", ".gif", ".webp"], fn ext ->
  IO.puts("   #{ext} -> #{ContentPart.detect_mime_type("image#{ext}")}")
end)

# Test with LMStudio Vision Model
IO.puts("\n🤖 Testing with LMStudio Vision:")

model = "lmstudio:qwen3-vl-8b-thinking"
agent = Agent.new(model,
  instructions: "You are a helpful vision assistant. Describe what you see in images clearly and concisely.",
  model_settings: %{
    base_url: "http://localhost:1234/v1",
    temperature: 0.3,
    max_tokens: 100
  }
)

# Create multi-modal message
vision_message = Message.user([
  ContentPart.text("What do you see in this image? Describe the colors and shape."),
  image_part
])

IO.puts("📤 Sending image to vision model...")
IO.puts("   Message content: #{Message.extract_text(vision_message)}")

case AgentRunner.run(agent, vision_message) do
  {:ok, result} ->
    IO.puts("\n✅ Vision model response:")
    IO.puts("📥 #{String.slice(result.output, 0, 200)}...")
    IO.puts("📊 Usage: #{result.usage.total_tokens} tokens")

  {:error, error} ->
    IO.puts("\n❌ Error: #{inspect(error)}")
end

# Show format conversion
IO.puts("\n🔄 Format conversion example:")
conversation = [Message.system("Analyze images"), vision_message]
openai_format = Messages.to_openai_format(conversation)

IO.puts("Converted to OpenAI format:")
Enum.with_index(openai_format, 1)
|> Enum.each(fn {msg, i} ->
  content = Map.get(msg, :content)
  case content do
    content when is_list(content) ->
      text_parts = Enum.filter(content, &(Map.get(&1, "type") == "text"))
      image_parts = Enum.filter(content, &(Map.get(&1, "type") == "image_url"))
      IO.puts("  #{i}. Multi-modal: #{length(text_parts)} text + #{length(image_parts)} image parts")
    content when is_binary(content) ->
      IO.puts("  #{i}. Text: #{String.slice(content, 0, 40)}...")
  end
end)

IO.puts("\n🎉 Vision demo completed!")
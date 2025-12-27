#!/usr/bin/env elixir

# Test vision with real Acropolis image using our Message system
alias Nous.{Message, Messages}
alias Nous.Message.ContentPart

IO.puts("🏛️ Testing Vision with Real Acropolis Image")
IO.puts("=" <> String.duplicate("=", 45))

# Real image URL from user
acropolis_url = "https://e498h76z5mp.exactdn.com/wp-content/uploads/2016/07/Acroplis-Athens-720x482.jpg?quality=65"

IO.puts("\n🖼️ Image URL: #{acropolis_url}")

# Create image content part
acropolis_image = ContentPart.image_url(acropolis_url)
IO.puts("✅ Created image ContentPart")
IO.puts("   Type: #{acropolis_image.type}")
IO.puts("   URL: #{String.slice(acropolis_image.content, 0, 60)}...")

# Create multimodal message
vision_message = Message.user([
  ContentPart.text("What do you see in this image? Please describe the architecture, setting, and any historical landmarks you can identify."),
  acropolis_image
])

IO.puts("\n📝 Created multimodal message:")
IO.puts("   Text content: #{Message.extract_text(vision_message)}")
IO.puts("   Content parts: #{length(Message.get_metadata(vision_message, :content_parts))}")

# Convert to OpenAI format for API
conversation = [
  Message.system("You are an expert art and architecture historian with knowledge of ancient Greek landmarks. Analyze images in detail."),
  vision_message
]

openai_format = Messages.to_openai_format(conversation)
user_openai_msg = Enum.at(openai_format, 1)

IO.puts("\n🔄 Converted to OpenAI API format:")
content = Map.get(user_openai_msg, :content)
if is_list(content) do
  text_part = Enum.find(content, &(Map.get(&1, "type") == "text"))
  image_part = Enum.find(content, &(Map.get(&1, "type") == "image_url"))

  IO.puts("   Text: #{String.slice(Map.get(text_part, "text", ""), 0, 60)}...")
  image_url = get_in(image_part, ["image_url", "url"])
  IO.puts("   Image URL: #{String.slice(image_url, 0, 60)}...")
end

# Make API call to vision model
IO.puts("\n🤖 Calling LMStudio vision model...")

request_body = %{
  "model" => "qwen3-vl-8b-thinking",
  "messages" => [
    %{
      "role" => "system",
      "content" => "You are an expert art and architecture historian with knowledge of ancient Greek landmarks. Analyze images in detail."
    },
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "text",
          "text" => "What do you see in this image? Please describe the architecture, setting, and any historical landmarks you can identify."
        },
        %{
          "type" => "image_url",
          "image_url" => %{"url" => acropolis_url}
        }
      ]
    }
  ],
  "temperature" => 0.3,
  "max_tokens" => 300,
  "stream" => false
} |> Jason.encode!()

IO.puts("📤 Sending request to LMStudio...")

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

        IO.puts("\n✅ 🏛️ VISION MODEL ANALYSIS:")
        IO.puts("=" <> String.duplicate("=", 50))
        IO.puts(parsed.content)
        IO.puts("=" <> String.duplicate("=", 50))
        IO.puts("\n📊 Usage Stats:")
        IO.puts("   Tokens: #{parsed.metadata.usage.total_tokens} (#{parsed.metadata.usage.input_tokens} in + #{parsed.metadata.usage.output_tokens} out)")
        IO.puts("   Model: #{parsed.metadata.model_name}")

      {:error, decode_error} ->
        IO.puts("❌ JSON decode error: #{inspect(decode_error)}")
        IO.puts("Raw response: #{String.slice(response_json, 0, 500)}...")
    end

  {error, exit_code} ->
    IO.puts("❌ curl failed (exit #{exit_code}): #{error}")
end

# Show our Message system utilities
IO.puts("\n📋 Message System Features Demonstrated:")
IO.puts("✅ ContentPart.image_url() - Create image content parts")
IO.puts("✅ Message.user() - Multi-modal message construction")
IO.puts("✅ Messages.to_openai_format() - Provider format conversion")
IO.puts("✅ Messages.from_openai_response() - Response parsing")
IO.puts("✅ Message utilities - Text extraction, metadata access")

IO.puts("\n🎉 Acropolis vision test completed!")
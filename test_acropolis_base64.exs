#!/usr/bin/env elixir

# Test vision with real Acropolis image using base64 conversion
alias Nous.{Message, Messages}
alias Nous.Message.ContentPart

IO.puts("🏛️ Testing Vision with Base64 Image Conversion")
IO.puts("=" <> String.duplicate("=", 50))

# Image URL from user
acropolis_url = "https://e498h76z5mp.exactdn.com/wp-content/uploads/2016/07/Acroplis-Athens-720x482.jpg?quality=65"

IO.puts("\n📥 Downloading image from: #{acropolis_url}")

# Download the image and convert to base64
case System.cmd("curl", ["-s", "-L", acropolis_url]) do
  {image_binary, 0} when byte_size(image_binary) > 0 ->
    IO.puts("✅ Image downloaded: #{byte_size(image_binary)} bytes")

    # Use our ContentPart utilities to convert to base64
    acropolis_image = ContentPart.from_binary(image_binary, "acropolis.jpg")

    IO.puts("✅ Converted to base64 data URL")
    IO.puts("   Type: #{acropolis_image.type}")
    IO.puts("   Data URL starts: #{String.slice(acropolis_image.content, 0, 50)}...")
    IO.puts("   Total size: #{byte_size(acropolis_image.content)} characters")

    # Test MIME type detection
    detected_mime = ContentPart.detect_mime_type("image.jpg")
    IO.puts("✅ MIME type detected: #{detected_mime}")

    # Create vision message
    vision_message = Message.user([
      ContentPart.text("What do you see in this image? Please describe the architecture and identify any historical landmarks."),
      acropolis_image
    ])

    IO.puts("\n📝 Created vision message with #{length(Message.get_metadata(vision_message, :content_parts))} content parts")

    # Convert to API format
    conversation = [
      Message.system("You are an expert on ancient Greek architecture and archaeology."),
      vision_message
    ]

    openai_format = Messages.to_openai_format(conversation)
    user_msg = Enum.at(openai_format, 1)
    content = Map.get(user_msg, :content)

    # Extract the image part for API call
    image_part = Enum.find(content, &(Map.get(&1, "type") == "image_url"))
    image_data_url = get_in(image_part, ["image_url", "url"])

    IO.puts("✅ Ready for vision API call")
    IO.puts("   Image data URL length: #{String.length(image_data_url)}")

    # Make API call
    IO.puts("\n🤖 Calling LMStudio vision model...")

    request_body = %{
      "model" => "qwen3-vl-8b-thinking",
      "messages" => [
        %{
          "role" => "system",
          "content" => "You are an expert on ancient Greek architecture and archaeology."
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => "What do you see in this image? Please describe the architecture and identify any historical landmarks."
            },
            %{
              "type" => "image_url",
              "image_url" => %{"url" => image_data_url}
            }
          ]
        }
      ],
      "temperature" => 0.3,
      "max_tokens" => 400,
      "stream" => false
    } |> Jason.encode!()

    # Write request to temp file for curl (too large for command line)
    File.write!("/tmp/vision_request.json", request_body)

    case System.cmd("curl", [
      "-s",
      "http://localhost:1234/v1/chat/completions",
      "-H", "Content-Type: application/json",
      "--data-binary", "@/tmp/vision_request.json"
    ]) do
      {response_json, 0} ->
        case Jason.decode(response_json) do
          {:ok, response} ->
            parsed = Messages.from_openai_response(response)

            IO.puts("\n✅ 🏛️ ACROPOLIS VISION ANALYSIS:")
            IO.puts("=" <> String.duplicate("=", 60))
            IO.puts(parsed.content)
            IO.puts("=" <> String.duplicate("=", 60))
            IO.puts("\n📊 Analysis Stats:")
            IO.puts("   Tokens used: #{parsed.metadata.usage.total_tokens}")
            IO.puts("   Input tokens: #{parsed.metadata.usage.input_tokens}")
            IO.puts("   Output tokens: #{parsed.metadata.usage.output_tokens}")
            IO.puts("   Model: #{parsed.metadata.model_name}")

          {:error, json_error} ->
            IO.puts("❌ JSON parse error: #{inspect(json_error)}")
            IO.puts("Response preview: #{String.slice(response_json, 0, 300)}...")
        end

      {error, exit_code} ->
        IO.puts("❌ API call failed (#{exit_code}): #{error}")
    end

    # Clean up
    File.rm("/tmp/vision_request.json")

  {_, exit_code} ->
    IO.puts("❌ Failed to download image (exit code: #{exit_code})")
    IO.puts("Creating a simple test with base64 utilities instead...")

    # Fallback: test with our test image
    test_image = ContentPart.test_image()
    IO.puts("✅ Using test image: #{String.slice(test_image.content, 0, 50)}...")

    # Quick test with test image
    simple_request = %{
      "model" => "qwen3-vl-8b-thinking",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "What color is this image?"},
            %{"type" => "image_url", "image_url" => %{"url" => test_image.content}}
          ]
        }
      ],
      "max_tokens" => 50
    } |> Jason.encode!()

    case System.cmd("curl", [
      "-s",
      "http://localhost:1234/v1/chat/completions",
      "-H", "Content-Type: application/json",
      "-d", simple_request
    ]) do
      {test_response, 0} ->
        case Jason.decode(test_response) do
          {:ok, response} ->
            parsed = Messages.from_openai_response(response)
            IO.puts("✅ Test image analysis: #{parsed.content}")
          {:error, _} ->
            IO.puts("❌ Test failed")
        end
      _ ->
        IO.puts("❌ Test request failed")
    end
end

IO.puts("\n📋 ContentPart Utilities Demonstrated:")
IO.puts("✅ ContentPart.from_binary() - Convert binary data to base64")
IO.puts("✅ ContentPart.detect_mime_type() - Auto-detect image format")
IO.puts("✅ ContentPart.test_image() - Generate test images")
IO.puts("✅ Multi-modal Message construction")
IO.puts("✅ Base64 data URL generation")

IO.puts("\n🎉 Base64 vision test completed!")
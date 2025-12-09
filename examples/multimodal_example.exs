#!/usr/bin/env elixir

# Nous AI - Multimodal Example (Vision + Text)
# Work with images and text together using AI models that support vision

IO.puts("👁️  Multimodal AI Demo (Vision + Text)")
IO.puts("Analyze images, extract text, and combine visual with textual understanding!")
IO.puts("")

# ============================================================================
# Check for Multimodal Support
# ============================================================================

defmodule MultimodalChecker do
  @doc """
  Check which models support multimodal capabilities
  """
  def check_support do
    IO.puts("🔍 Checking multimodal support across providers:")
    IO.puts("")

    # Models known to support vision
    vision_models = [
      %{provider: "Anthropic", model: "claude-3-sonnet", supports_vision: true, notes: "Excellent vision capabilities"},
      %{provider: "OpenAI", model: "gpt-4-vision-preview", supports_vision: true, notes: "Good vision understanding"},
      %{provider: "Gemini", model: "gemini-pro-vision", supports_vision: true, notes: "Google's vision model"},
      %{provider: "Local", model: "llava", supports_vision: true, notes: "Open source vision model"},
      %{provider: "Local", model: "qwen3-30b", supports_vision: false, notes: "Text only"}
    ]

    vision_models
    |> Enum.each(fn model ->
      status = if model.supports_vision, do: "✅", else: "❌"
      IO.puts("#{status} #{model.provider} (#{model.model}): #{model.notes}")
    end)

    IO.puts("")
    IO.puts("💡 For this demo, we'll show patterns that work with vision-capable models.")
    IO.puts("   If you have access to Claude 3+ or GPT-4V, you can try the real examples!")
    IO.puts("")
  end
end

MultimodalChecker.check_support()

# ============================================================================
# Image Analysis Patterns
# ============================================================================

defmodule ImageAnalyzer do
  @doc """
  Analyze images using vision-capable AI models
  """

  def analyze_image(agent, image_path, prompt \\ "Describe what you see in this image.") do
    IO.puts("🖼️  Analyzing image: #{image_path}")
    IO.puts("📝 Prompt: #{prompt}")

    # Check if image file exists
    if File.exists?(image_path) do
      # Read image as base64 (required for most APIs)
      case File.read(image_path) do
        {:ok, image_data} ->
          base64_image = Base.encode64(image_data)

          # Create multimodal message
          multimodal_message = create_multimodal_message(prompt, base64_image, image_path)

          case Nous.run(agent, multimodal_message) do
            {:ok, result} ->
              IO.puts("🤖 AI Analysis:")
              IO.puts(result.output)
              IO.puts("📊 Tokens used: #{result.usage.total_tokens}")
              {:ok, result}

            {:error, reason} ->
              IO.puts("❌ Analysis failed: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          IO.puts("❌ Could not read image: #{inspect(reason)}")
          {:error, reason}
      end
    else
      IO.puts("❌ Image file not found: #{image_path}")
      IO.puts("💡 For this demo, we'll simulate the multimodal patterns")
      simulate_image_analysis(agent, image_path, prompt)
    end
  end

  defp create_multimodal_message(text_prompt, base64_image, image_path) do
    # Different providers have different formats for multimodal messages
    # This is a simplified example - actual implementation depends on the provider

    file_ext = Path.extname(image_path) |> String.downcase()
    mime_type = case file_ext do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end

    # Example format (varies by provider):
    """
    #{text_prompt}

    [IMAGE: #{mime_type} data provided - #{byte_size(Base.decode64!(base64_image))} bytes]
    """
  end

  defp simulate_image_analysis(agent, image_path, prompt) do
    # Since we might not have a real image, simulate the analysis
    simulation_prompt = """
    #{prompt}

    Note: This is a simulation since no image file was found at #{image_path}.
    In a real multimodal scenario, you would analyze the actual image content.
    Please explain what kinds of things you could analyze if you had access to the image.
    """

    case Nous.run(agent, simulation_prompt) do
      {:ok, result} ->
        IO.puts("🤖 Simulated Analysis (no image provided):")
        IO.puts(result.output)
        {:ok, result}

      {:error, reason} ->
        IO.puts("❌ Simulation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

# ============================================================================
# Example 1: Basic Image Analysis
# ============================================================================

IO.puts("1️⃣  Basic Image Analysis Demo:")
IO.puts("")

# Create agent (using text model for demo - replace with vision model in practice)
vision_agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: """
  You are a multimodal AI assistant that can analyze images.
  When provided with images, describe them in detail including:
  - Objects and people present
  - Setting and environment
  - Colors and lighting
  - Mood and atmosphere
  - Any text visible in the image
  Be specific and helpful in your analysis.
  """,
  model_settings: %{temperature: 0.7}
)

# Example image paths (create these files or update paths to existing images)
example_images = [
  "/tmp/example_photo.jpg",
  "/tmp/chart.png",
  "/tmp/document.jpg"
]

# Try to analyze each image
Enum.each(example_images, fn image_path ->
  ImageAnalyzer.analyze_image(
    vision_agent,
    image_path,
    "Describe this image in detail. What do you see?"
  )
  IO.puts("")
end)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Example 2: Specific Analysis Tasks
# ============================================================================

defmodule SpecificAnalysis do
  @doc """
  Perform specific types of image analysis
  """

  def extract_text(agent, image_path) do
    ImageAnalyzer.analyze_image(
      agent,
      image_path,
      "Extract and transcribe any text visible in this image. Format it clearly."
    )
  end

  def analyze_chart(agent, image_path) do
    ImageAnalyzer.analyze_image(
      agent,
      image_path,
      """
      Analyze this chart or graph. Provide:
      1. Type of chart (bar, line, pie, etc.)
      2. Key data points and trends
      3. Main insights or conclusions
      4. Any notable patterns
      """
    )
  end

  def describe_scene(agent, image_path) do
    ImageAnalyzer.analyze_image(
      agent,
      image_path,
      """
      Describe this scene as if explaining to someone who can't see it:
      1. Setting and location
      2. People and their activities
      3. Objects and their arrangement
      4. Atmosphere and mood
      """
    )
  end

  def check_quality(agent, image_path) do
    ImageAnalyzer.analyze_image(
      agent,
      image_path,
      """
      Assess the technical quality of this image:
      1. Resolution and sharpness
      2. Lighting and exposure
      3. Composition and framing
      4. Any technical issues
      5. Suggestions for improvement
      """
    )
  end

  def identify_objects(agent, image_path) do
    ImageAnalyzer.analyze_image(
      agent,
      image_path,
      """
      Identify and list all objects visible in this image.
      Organize them by category (people, animals, vehicles, furniture, etc.).
      Include approximate counts and locations.
      """
    )
  end
end

IO.puts("2️⃣  Specific Analysis Tasks:")

analysis_tasks = [
  {"Text Extraction", &SpecificAnalysis.extract_text/2},
  {"Chart Analysis", &SpecificAnalysis.analyze_chart/2},
  {"Scene Description", &SpecificAnalysis.describe_scene/2},
  {"Quality Assessment", &SpecificAnalysis.check_quality/2},
  {"Object Identification", &SpecificAnalysis.identify_objects/2}
]

test_image = "/tmp/sample_image.jpg"

Enum.each(analysis_tasks, fn {task_name, task_function} ->
  IO.puts("🔍 #{task_name}:")
  task_function.(vision_agent, test_image)
  IO.puts("")
end)

IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Example 3: Batch Image Processing
# ============================================================================

defmodule BatchImageProcessor do
  @doc """
  Process multiple images efficiently
  """

  def process_image_batch(agent, image_paths, analysis_type \\ :describe) do
    IO.puts("📁 Processing #{length(image_paths)} images...")
    IO.puts("")

    results = image_paths
    |> Enum.with_index(1)
    |> Enum.map(fn {image_path, index} ->
      IO.puts("Processing image #{index}/#{length(image_paths)}: #{Path.basename(image_path)}")

      prompt = case analysis_type do
        :describe -> "Briefly describe this image in 2-3 sentences."
        :extract_text -> "Extract any text from this image."
        :categorize -> "Categorize this image (photo, document, chart, etc.) and briefly explain."
        :quality -> "Rate the quality of this image (poor/fair/good/excellent) and explain."
      end

      start_time = System.monotonic_time(:millisecond)

      result = case ImageAnalyzer.analyze_image(agent, image_path, prompt) do
        {:ok, analysis_result} ->
          %{
            image: image_path,
            status: :success,
            analysis: analysis_result.output,
            tokens: analysis_result.usage.total_tokens,
            processing_time: System.monotonic_time(:millisecond) - start_time
          }

        {:error, reason} ->
          %{
            image: image_path,
            status: :error,
            error: reason,
            processing_time: System.monotonic_time(:millisecond) - start_time
          }
      end

      IO.puts("")
      result
    end)

    print_batch_summary(results)
    results
  end

  defp print_batch_summary(results) do
    successful = Enum.count(results, & &1.status == :success)
    failed = length(results) - successful
    total_tokens = results
      |> Enum.filter(& &1.status == :success)
      |> Enum.map(& &1.tokens)
      |> Enum.sum()
    avg_time = results
      |> Enum.map(& &1.processing_time)
      |> Enum.sum()
      |> div(length(results))

    IO.puts("📊 Batch Processing Summary:")
    IO.puts("   Images processed: #{length(results)}")
    IO.puts("   Successful: #{successful}")
    IO.puts("   Failed: #{failed}")
    IO.puts("   Total tokens: #{total_tokens}")
    IO.puts("   Average processing time: #{avg_time}ms")
  end
end

IO.puts("3️⃣  Batch Image Processing Demo:")

# Example batch of images
batch_images = [
  "/tmp/photo1.jpg",
  "/tmp/photo2.jpg",
  "/tmp/document.png",
  "/tmp/chart.svg"
]

BatchImageProcessor.process_image_batch(vision_agent, batch_images, :describe)

IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")

# ============================================================================
# Example 4: Multimodal Conversation
# ============================================================================

defmodule MultimodalConversation do
  @doc """
  Have a conversation that includes both images and text
  """

  def start_multimodal_chat(agent) do
    IO.puts("💬 Multimodal Conversation Demo:")
    IO.puts("This shows how to mix images and text in a conversation.")
    IO.puts("")

    # Simulate a conversation with images
    conversation_steps = [
      {:text, "Hello! I'm going to show you some images and ask questions about them."},
      {:image, "/tmp/vacation_photo.jpg", "What can you tell me about this vacation photo?"},
      {:text, "Based on that image, what activities would you recommend for someone visiting that location?"},
      {:image, "/tmp/menu.jpg", "Now look at this restaurant menu. What would you recommend ordering?"},
      {:text, "Thanks! Can you summarize what we've discussed so far?"}
    ]

    message_history = []

    final_history = Enum.reduce(conversation_steps, message_history, fn step, history ->
      case step do
        {:text, message} ->
          IO.puts("👤 User: #{message}")
          handle_text_message(agent, message, history)

        {:image, image_path, message} ->
          IO.puts("👤 User: #{message} [with image: #{Path.basename(image_path)}]")
          handle_image_message(agent, image_path, message, history)

        _ ->
          history
      end
    end)

    IO.puts("🎉 Multimodal conversation complete!")
    IO.puts("Total messages in conversation: #{length(final_history)}")
  end

  defp handle_text_message(agent, message, history) do
    case Nous.run(agent, message, message_history: history) do
      {:ok, result} ->
        IO.puts("🤖 Assistant: #{result.output}")
        IO.puts("")
        result.new_messages

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
        history
    end
  end

  defp handle_image_message(agent, image_path, message, history) do
    # Combine image analysis with conversation context
    multimodal_message = """
    #{message}

    [Previous conversation context is available in message history]
    """

    case ImageAnalyzer.analyze_image(agent, image_path, multimodal_message) do
      {:ok, result} ->
        IO.puts("🤖 Assistant: #{result.output}")
        IO.puts("")

        # In a real implementation, you'd properly integrate this with message history
        # For now, we'll simulate adding it to the conversation
        history ++ [
          %{role: "user", content: "#{message} [image: #{Path.basename(image_path)}]"},
          %{role: "assistant", content: result.output}
        ]

      {:error, reason} ->
        IO.puts("❌ Image analysis error: #{inspect(reason)}")
        history
    end
  end
end

MultimodalConversation.start_multimodal_chat(vision_agent)

IO.puts("")
IO.puts(String.duplicate("=", 60))

# ============================================================================
# Multimodal Best Practices
# ============================================================================

IO.puts("")
IO.puts("💡 Multimodal AI Best Practices:")
IO.puts("")
IO.puts("✅ Image preparation:")
IO.puts("   • Use high-quality, clear images")
IO.puts("   • Optimal size: 1024x1024 or similar")
IO.puts("   • Supported formats: JPEG, PNG, WebP")
IO.puts("   • Compress large images to reduce costs")
IO.puts("")
IO.puts("✅ Prompt engineering:")
IO.puts("   • Be specific about what to analyze")
IO.puts("   • Ask for structured output when needed")
IO.puts("   • Combine visual and contextual information")
IO.puts("   • Use follow-up questions for deeper analysis")
IO.puts("")
IO.puts("✅ Cost considerations:")
IO.puts("   • Vision models cost more than text-only")
IO.puts("   • Image size affects processing cost")
IO.puts("   • Batch processing can be more efficient")
IO.puts("   • Cache results for repeated analyses")
IO.puts("")
IO.puts("✅ Privacy and security:")
IO.puts("   • Don't send sensitive images to cloud APIs")
IO.puts("   • Consider local vision models for private data")
IO.puts("   • Implement image content filtering")
IO.puts("   • Follow data retention policies")
IO.puts("")
IO.puts("✅ Performance optimization:")
IO.puts("   • Resize images to optimal dimensions")
IO.puts("   • Use appropriate image quality settings")
IO.puts("   • Implement caching for repeated analyses")
IO.puts("   • Consider async processing for batches")

# ============================================================================
# Model-Specific Implementation Notes
# ============================================================================

IO.puts("")
IO.puts("🔧 Implementation Notes for Different Providers:")
IO.puts("")
IO.puts("Anthropic Claude 3+:")
IO.puts("   • Excellent vision capabilities")
IO.puts("   • Supports detailed image analysis")
IO.puts("   • Good at reading text in images")
IO.puts("   • Format: Include base64 image in message")
IO.puts("")
IO.puts("OpenAI GPT-4 Vision:")
IO.puts("   • Strong general vision understanding")
IO.puts("   • Good at scene description and object detection")
IO.puts("   • Format: Use 'image_url' in message content")
IO.puts("")
IO.puts("Google Gemini Pro Vision:")
IO.puts("   • Good performance, competitive pricing")
IO.puts("   • Integrated with Google ecosystem")
IO.puts("   • Format: Include image as part of request")
IO.puts("")
IO.puts("Local Models (LLaVA, etc.):")
IO.puts("   • Privacy-friendly, no cloud dependency")
IO.puts("   • Requires more powerful hardware")
IO.puts("   • Growing ecosystem of open models")
IO.puts("   • Format: Depends on specific implementation")

# ============================================================================
# Next Steps
# ============================================================================

IO.puts("")
IO.puts("🚀 Next Steps:")
IO.puts("1. Set up a vision-capable model (Claude 3+, GPT-4V, etc.)")
IO.puts("2. Create test images to analyze")
IO.puts("3. Try different types of image analysis tasks")
IO.puts("4. Combine with other examples (streaming, conversation history)")
IO.puts("5. See cost_tracking_example.exs for monitoring vision API costs")
IO.puts("6. Explore local vision models for privacy-sensitive applications")
IO.puts("7. Build multimodal tools for your specific use cases")
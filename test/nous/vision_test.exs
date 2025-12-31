defmodule Nous.VisionTest do
  use ExUnit.Case

  # These tests require a vision-capable LLM (LM Studio with qwen3-vl)
  # Run with: mix test --include llm --include vision
  @moduletag :llm
  @moduletag :vision
  @moduletag timeout: 180_000

  alias Nous.{Agent, Message}
  alias Nous.Message.ContentPart
  alias Nous.Tool

  @fixtures_path "test/support/fixtures/images"
  @parthenon_path "#{@fixtures_path}/parthenon.jpg"

  describe "image analysis with local file" do
    test "agent can describe image from local file" do
      # Load image from file
      {:ok, image_part} = ContentPart.from_file(@parthenon_path)

      # Create multimodal message
      message = Message.user([
        ContentPart.text("What famous building or structure is shown in this image? Answer briefly in one sentence."),
        image_part
      ])

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "You are a helpful assistant that describes images accurately. Be concise."
      )

      {:ok, result} = Agent.run(agent, messages: [message])

      # The model should recognize the Parthenon or describe ancient architecture
      output = String.downcase(result.output)
      assert output =~ "parthenon" or output =~ "greece" or output =~ "athens" or
             output =~ "temple" or output =~ "ancient" or output =~ "column" or
             output =~ "acropolis" or output =~ "ruin"
    end

    test "agent can answer questions about image content" do
      {:ok, image_part} = ContentPart.from_file(@parthenon_path)

      messages = [
        Message.system("You are an art history expert. Answer in one word only."),
        Message.user([
          ContentPart.text("What architectural style is this building? One word."),
          image_part
        ])
      ]

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx")

      {:ok, result} = Agent.run(agent, messages: messages)

      output = String.downcase(result.output)
      # Should recognize Greek/Classical/Doric architecture
      assert output =~ "greek" or output =~ "classical" or output =~ "doric" or
             output =~ "ancient" or output =~ "neoclassical" or output =~ "ionic"
    end
  end

  # Note: LMStudio requires base64 encoded images, not URLs
  # URL-based image tests are skipped for LMStudio

  describe "image analysis with base64" do
    test "agent can describe image from base64 data" do
      # Read and encode image
      binary = File.read!(@parthenon_path)
      data_url = ContentPart.to_data_url(binary, "image/jpeg")

      message = Message.user([
        ContentPart.text("Is this building ancient or modern? Answer with one word."),
        ContentPart.image_url(data_url)
      ])

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Answer questions briefly."
      )

      {:ok, result} = Agent.run(agent, messages: [message])

      output = String.downcase(result.output)
      assert output =~ "ancient" or output =~ "old" or output =~ "classical" or output =~ "historic"
    end
  end

  describe "vision with tools" do
    test "agent can use tools while processing images" do
      {:ok, image_part} = ContentPart.from_file(@parthenon_path)

      # Create tool with proper schema
      save_note = Tool.from_function(
        fn _ctx, %{"note" => note} -> %{saved: true, note: note} end,
        name: "save_note",
        description: "Save a note about what you observe",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "note" => %{"type" => "string", "description" => "The note to save"}
          },
          "required" => ["note"]
        }
      )

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Describe images briefly. Use the save_note tool to record observations.",
        tools: [save_note]
      )

      {:ok, result} = Agent.run(agent,
        messages: [
          Message.user([
            ContentPart.text("Look at this image and save a note about what building you see."),
            image_part
          ])
        ]
      )

      # Model should complete (may or may not use tool)
      assert result.output != nil
    end
  end

  describe "multiple images" do
    test "agent can analyze multiple images" do
      {:ok, image1} = ContentPart.from_file(@parthenon_path)
      # Use test image as second image
      image2 = ContentPart.test_image()

      message = Message.user([
        ContentPart.text("I'm showing you two images. Describe what you see in each briefly."),
        image1,
        image2
      ])

      agent = Agent.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        instructions: "Describe images concisely."
      )

      {:ok, result} = Agent.run(agent, messages: [message])

      # Should provide some description
      assert String.length(result.output) > 10
    end
  end
end

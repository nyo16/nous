defmodule Nous.VisionPipelineTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Message.ContentPart
  alias Nous.Messages.{OpenAI, Anthropic, Gemini}

  @fixtures_path "test/support/fixtures/images"
  @parthenon_path "#{@fixtures_path}/parthenon.jpg"
  @png_path "#{@fixtures_path}/test_square.png"
  @webp_path "#{@fixtures_path}/test_tiny.webp"

  # ── Format Conversion Round-Trip ──────────────────────────────────────

  describe "OpenAI format conversion" do
    test "data URL image preserved in content parts" do
      data_url = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="

      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image_url(data_url)
        ])

      [formatted] = OpenAI.to_format([msg])

      assert [text_part, image_part] = formatted["content"]
      assert text_part == %{"type" => "text", "text" => "Describe"}
      assert image_part == %{"type" => "image_url", "image_url" => %{"url" => data_url}}
    end

    test "HTTP URL image preserved" do
      url = "https://example.com/photo.jpg"

      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image_url(url)
        ])

      [formatted] = OpenAI.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image_url"))

      assert image_part["image_url"]["url"] == url
    end

    test ":image content part converted to data URL" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image("base64data", media_type: "image/png")
        ])

      [formatted] = OpenAI.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image_url"))

      assert image_part["image_url"]["url"] == "data:image/png;base64,base64data"
    end

    test "detail option passed through for image_url" do
      msg =
        Message.user([
          ContentPart.new!(%{
            type: :image_url,
            content: "data:image/jpeg;base64,abc",
            options: %{detail: "low"}
          })
        ])

      [formatted] = OpenAI.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image_url"))

      assert image_part["image_url"]["detail"] == "low"
    end

    test "detail option omitted when not set" do
      msg =
        Message.user([
          ContentPart.image_url("data:image/jpeg;base64,abc")
        ])

      [formatted] = OpenAI.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image_url"))

      refute Map.has_key?(image_part["image_url"], "detail")
    end
  end

  describe "Anthropic format conversion" do
    test "data URL image: media_type and base64 extracted correctly" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image_url("data:image/png;base64,iVBORw0KGgo=")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image"))

      assert image_part["source"]["type"] == "base64"
      assert image_part["source"]["media_type"] == "image/png"
      # Must be raw base64, NOT the full data URL
      assert image_part["source"]["data"] == "iVBORw0KGgo="
      refute String.starts_with?(image_part["source"]["data"], "data:")
    end

    test "HTTP URL uses url source type" do
      msg =
        Message.user([
          ContentPart.image_url("https://example.com/img.jpg")
        ])

      {_sys, [formatted]} = Anthropic.to_format([msg])
      image_part = Enum.find(formatted["content"], &(&1["type"] == "image"))

      assert image_part["source"]["type"] == "url"
      assert image_part["source"]["url"] == "https://example.com/img.jpg"
    end
  end

  describe "Gemini format conversion" do
    test "data URL image: mimeType and data extracted correctly" do
      msg =
        Message.user([
          ContentPart.text("Describe"),
          ContentPart.image_url("data:image/webp;base64,UklGRlYAAABXRUJQ")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])
      image_part = Enum.find(formatted["parts"], &Map.has_key?(&1, "inlineData"))

      assert image_part["inlineData"]["mimeType"] == "image/webp"
      assert image_part["inlineData"]["data"] == "UklGRlYAAABXRUJQ"
    end

    test "HTTP URL uses fileData" do
      msg =
        Message.user([
          ContentPart.image_url("https://example.com/img.png")
        ])

      {_sys, [formatted]} = Gemini.to_format([msg])
      file_part = Enum.find(formatted["parts"], &Map.has_key?(&1, "fileData"))

      assert file_part["fileData"]["fileUri"] == "https://example.com/img.png"
      assert file_part["fileData"]["mimeType"] == "image/png"
    end
  end

  # ── MIME Type Handling ────────────────────────────────────────────────

  describe "MIME type handling across providers" do
    for {format, mime} <- [
          {"jpeg", "image/jpeg"},
          {"png", "image/png"},
          {"webp", "image/webp"},
          {"gif", "image/gif"}
        ] do
      test "#{format} data URL: all providers parse media type correctly" do
        data_url = "data:#{unquote(mime)};base64,dGVzdA=="

        msg = Message.user([ContentPart.image_url(data_url)])

        # OpenAI: passes URL through
        [openai] = OpenAI.to_format([msg])
        openai_img = Enum.find(openai["content"], &(&1["type"] == "image_url"))
        assert openai_img["image_url"]["url"] == data_url

        # Anthropic: extracts media_type
        {_sys, [anthropic]} = Anthropic.to_format([msg])
        anthropic_img = Enum.find(anthropic["content"], &(&1["type"] == "image"))
        assert anthropic_img["source"]["media_type"] == unquote(mime)
        assert anthropic_img["source"]["data"] == "dGVzdA=="

        # Gemini: extracts mimeType
        {_sys, [gemini]} = Gemini.to_format([msg])
        gemini_img = Enum.find(gemini["parts"], &Map.has_key?(&1, "inlineData"))
        assert gemini_img["inlineData"]["mimeType"] == unquote(mime)
        assert gemini_img["inlineData"]["data"] == "dGVzdA=="
      end
    end
  end

  # ── Edge Cases ────────────────────────────────────────────────────────

  describe "edge cases" do
    test "message with only images (no text) is formatted correctly" do
      msg =
        Message.user([
          ContentPart.image_url("data:image/jpeg;base64,abc")
        ])

      # OpenAI
      [openai] = OpenAI.to_format([msg])
      assert length(openai["content"]) == 1
      assert hd(openai["content"])["type"] == "image_url"

      # Anthropic
      {_sys, [anthropic]} = Anthropic.to_format([msg])
      assert length(anthropic["content"]) == 1
      assert hd(anthropic["content"])["type"] == "image"

      # Gemini
      {_sys, [gemini]} = Gemini.to_format([msg])
      assert length(gemini["parts"]) == 1
      assert Map.has_key?(hd(gemini["parts"]), "inlineData")
    end

    test "message with many content parts preserves order" do
      msg =
        Message.user([
          ContentPart.text("First"),
          ContentPart.image_url("data:image/jpeg;base64,img1"),
          ContentPart.text("Second"),
          ContentPart.image_url("data:image/png;base64,img2"),
          ContentPart.text("Third")
        ])

      [openai] = OpenAI.to_format([msg])
      types = Enum.map(openai["content"], & &1["type"])
      assert types == ["text", "image_url", "text", "image_url", "text"]
    end

    test "real image file round-trips through all provider formats" do
      {:ok, part} = ContentPart.from_file(@parthenon_path)
      msg = Message.user([ContentPart.text("Describe"), part])

      # OpenAI - verify data URL is intact
      [openai] = OpenAI.to_format([msg])
      openai_img = Enum.find(openai["content"], &(&1["type"] == "image_url"))
      assert String.starts_with?(openai_img["image_url"]["url"], "data:image/jpeg;base64,")

      # Anthropic - verify base64 is extracted (no data: prefix)
      {_sys, [anthropic]} = Anthropic.to_format([msg])
      anthropic_img = Enum.find(anthropic["content"], &(&1["type"] == "image"))
      assert anthropic_img["source"]["media_type"] == "image/jpeg"
      refute String.starts_with?(anthropic_img["source"]["data"], "data:")
      # Verify base64 decodes back to original file
      {:ok, decoded} = Base.decode64(anthropic_img["source"]["data"])
      assert decoded == File.read!(@parthenon_path)

      # Gemini - verify inlineData
      {_sys, [gemini]} = Gemini.to_format([msg])
      gemini_img = Enum.find(gemini["parts"], &Map.has_key?(&1, "inlineData"))
      assert gemini_img["inlineData"]["mimeType"] == "image/jpeg"
      {:ok, decoded} = Base.decode64(gemini_img["inlineData"]["data"])
      assert decoded == File.read!(@parthenon_path)
    end

    test "PNG file round-trips through all provider formats" do
      {:ok, part} = ContentPart.from_file(@png_path)
      msg = Message.user([part])

      {_sys, [anthropic]} = Anthropic.to_format([msg])
      anthropic_img = hd(anthropic["content"])
      assert anthropic_img["source"]["media_type"] == "image/png"

      {_sys, [gemini]} = Gemini.to_format([msg])
      gemini_img = hd(gemini["parts"])
      assert gemini_img["inlineData"]["mimeType"] == "image/png"
    end

    test "WebP file round-trips through all provider formats" do
      {:ok, part} = ContentPart.from_file(@webp_path)
      msg = Message.user([part])

      {_sys, [anthropic]} = Anthropic.to_format([msg])
      anthropic_img = hd(anthropic["content"])
      assert anthropic_img["source"]["media_type"] == "image/webp"

      {_sys, [gemini]} = Gemini.to_format([msg])
      gemini_img = hd(gemini["parts"])
      assert gemini_img["inlineData"]["mimeType"] == "image/webp"
    end

    test "plain text user message still works (no content_parts in metadata)" do
      msg = Message.user("Hello world")

      [openai] = OpenAI.to_format([msg])
      assert openai["content"] == "Hello world"

      {_sys, [anthropic]} = Anthropic.to_format([msg])
      assert anthropic["content"] == "Hello world"

      {_sys, [gemini]} = Gemini.to_format([msg])
      assert gemini["parts"] == [%{"text" => "Hello world"}]
    end
  end

  # ── LLM Integration Tests ────────────────────────────────────────────

  describe "LM Studio vision integration" do
    @moduletag :llm
    @moduletag :vision
    @moduletag timeout: 180_000

    setup do
      case Nous.LLMTestHelper.check_model_available() do
        :ok -> :ok
        {:error, reason} -> {:skip, "LLM not available: #{reason}"}
      end
    end

    test "JPEG image from file via Agent.run" do
      {:ok, image_part} = ContentPart.from_file(@parthenon_path)

      message =
        Message.user([
          ContentPart.text(
            "What famous building or structure is shown in this image? Answer briefly in one sentence."
          ),
          image_part
        ])

      agent =
        Nous.Agent.new(Nous.LLMTestHelper.test_model(),
          instructions:
            "You are a helpful assistant that describes images accurately. Be concise."
        )

      {:ok, result} = Nous.Agent.run(agent, messages: [message])
      output = String.downcase(result.output)

      assert output =~ "parthenon" or output =~ "greece" or output =~ "athens" or
               output =~ "temple" or output =~ "ancient" or output =~ "column" or
               output =~ "acropolis"
    end

    test "PNG image from binary via Agent.run" do
      binary = File.read!(@png_path)
      data_url = ContentPart.to_data_url(binary, "image/png")

      message =
        Message.user([
          ContentPart.text("What color is this solid square? Answer with one word."),
          ContentPart.image_url(data_url)
        ])

      agent =
        Nous.Agent.new(Nous.LLMTestHelper.test_model(),
          instructions: "Answer questions briefly in one word."
        )

      {:ok, result} = Nous.Agent.run(agent, messages: [message])
      output = String.downcase(result.output)

      assert output =~ "red" or output =~ "scarlet" or output =~ "crimson"
    end

    test "multiple images in single message" do
      {:ok, jpeg_part} = ContentPart.from_file(@parthenon_path)
      {:ok, png_part} = ContentPart.from_file(@png_path)

      message =
        Message.user([
          ContentPart.text(
            "I'm showing you two images. How many images do you see? Answer with just the number."
          ),
          jpeg_part,
          png_part
        ])

      agent =
        Nous.Agent.new(Nous.LLMTestHelper.test_model(),
          instructions: "Answer questions briefly."
        )

      {:ok, result} = Nous.Agent.run(agent, messages: [message])

      assert result.output =~ "2" or result.output =~ "two"
    end

    test "different image formats produce valid responses" do
      for {path, description} <- [
            {@parthenon_path, "building"},
            {@png_path, "square"}
          ] do
        {:ok, image_part} = ContentPart.from_file(path)

        message =
          Message.user([
            ContentPart.text("Briefly describe what you see in this image in one sentence."),
            image_part
          ])

        agent =
          Nous.Agent.new(Nous.LLMTestHelper.test_model(),
            instructions: "Describe images concisely."
          )

        {:ok, result} = Nous.Agent.run(agent, messages: [message])

        assert String.length(result.output) > 5,
               "Expected description for #{description}, got: #{result.output}"
      end
    end
  end
end

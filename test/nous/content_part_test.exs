defmodule Nous.Message.ContentPartTest do
  use ExUnit.Case, async: true

  alias Nous.Message.ContentPart

  @fixtures_path "test/support/fixtures/images"
  @parthenon_path "#{@fixtures_path}/parthenon.jpg"

  describe "from_file/1" do
    test "converts local image file to base64 data URL" do
      {:ok, content_part} = ContentPart.from_file(@parthenon_path)

      assert content_part.type == :image_url
      assert String.starts_with?(content_part.content, "data:image/jpeg;base64,")

      # Verify base64 is valid
      "data:image/jpeg;base64," <> base64_data = content_part.content
      assert {:ok, _binary} = Base.decode64(base64_data)
    end

    test "returns error for non-existent file" do
      assert {:error, :enoent} = ContentPart.from_file("/nonexistent/image.jpg")
    end

    test "detects correct MIME type for different extensions" do
      # Create temp files with different extensions
      tmp_dir = System.tmp_dir!()

      for {ext, expected_mime} <- [
            {".jpg", "image/jpeg"},
            {".jpeg", "image/jpeg"},
            {".png", "image/png"},
            {".gif", "image/gif"},
            {".webp", "image/webp"}
          ] do
        path = Path.join(tmp_dir, "test_image#{ext}")
        # Copy parthenon as test file
        File.cp!(@parthenon_path, path)

        {:ok, content_part} = ContentPart.from_file(path)
        assert String.starts_with?(content_part.content, "data:#{expected_mime};base64,")

        File.rm!(path)
      end
    end
  end

  describe "from_file!/1" do
    test "returns content part for valid file" do
      content_part = ContentPart.from_file!(@parthenon_path)

      assert content_part.type == :image_url
      assert String.starts_with?(content_part.content, "data:image/jpeg;base64,")
    end

    test "raises for non-existent file" do
      assert_raise RuntimeError, ~r/Failed to read image file/, fn ->
        ContentPart.from_file!("/nonexistent/image.jpg")
      end
    end
  end

  describe "to_data_url/2" do
    test "converts binary to data URL" do
      binary = File.read!(@parthenon_path)
      data_url = ContentPart.to_data_url(binary, "image/jpeg")

      assert String.starts_with?(data_url, "data:image/jpeg;base64,")

      # Verify round-trip
      "data:image/jpeg;base64," <> base64 = data_url
      assert {:ok, decoded} = Base.decode64(base64)
      assert decoded == binary
    end
  end

  describe "base64_to_data_url/2" do
    test "wraps base64 string in data URL format" do
      base64 = Base.encode64("test data")
      data_url = ContentPart.base64_to_data_url(base64, "image/png")

      assert data_url == "data:image/png;base64,#{base64}"
    end
  end

  describe "from_binary/2" do
    test "converts binary data to content part with auto-detected MIME" do
      binary = File.read!(@parthenon_path)
      content_part = ContentPart.from_binary(binary, "photo.jpg")

      assert content_part.type == :image_url
      assert String.starts_with?(content_part.content, "data:image/jpeg;base64,")
    end

    test "uses default filename hint when not provided" do
      binary = File.read!(@parthenon_path)
      content_part = ContentPart.from_binary(binary)

      assert content_part.type == :image_url
      assert String.starts_with?(content_part.content, "data:image/png;base64,")
    end
  end

  describe "detect_mime_type/1" do
    test "detects common image MIME types" do
      assert ContentPart.detect_mime_type("photo.jpg") == "image/jpeg"
      assert ContentPart.detect_mime_type("photo.jpeg") == "image/jpeg"
      assert ContentPart.detect_mime_type("photo.png") == "image/png"
      assert ContentPart.detect_mime_type("photo.gif") == "image/gif"
      assert ContentPart.detect_mime_type("photo.webp") == "image/webp"
      assert ContentPart.detect_mime_type("photo.svg") == "image/svg+xml"
      assert ContentPart.detect_mime_type("photo.bmp") == "image/bmp"
      assert ContentPart.detect_mime_type("photo.tiff") == "image/tiff"
      assert ContentPart.detect_mime_type("photo.tif") == "image/tiff"
      assert ContentPart.detect_mime_type("photo.ico") == "image/x-icon"
    end

    test "returns octet-stream for unknown extensions" do
      assert ContentPart.detect_mime_type("file.xyz") == "application/octet-stream"
      assert ContentPart.detect_mime_type("file.unknown") == "application/octet-stream"
    end

    test "handles case insensitive extensions" do
      assert ContentPart.detect_mime_type("photo.JPG") == "image/jpeg"
      assert ContentPart.detect_mime_type("photo.PNG") == "image/png"
    end
  end

  describe "test_image/0" do
    test "returns a valid 1x1 test image" do
      test_img = ContentPart.test_image()

      assert test_img.type == :image_url
      assert String.starts_with?(test_img.content, "data:image/png;base64,")

      # Verify it's valid base64
      "data:image/png;base64," <> base64 = test_img.content
      assert {:ok, _binary} = Base.decode64(base64)
    end
  end

  describe "constructors" do
    test "text/1 creates text content part" do
      part = ContentPart.text("Hello world")
      assert part.type == :text
      assert part.content == "Hello world"
    end

    test "image_url/1 creates image URL content part" do
      url = "https://example.com/image.jpg"
      part = ContentPart.image_url(url)
      assert part.type == :image_url
      assert part.content == url
    end

    test "image_url/1 accepts data URLs" do
      data_url = "data:image/png;base64,iVBORw0KGgo="
      part = ContentPart.image_url(data_url)
      assert part.type == :image_url
      assert part.content == data_url
    end

    test "image/2 creates image content part with options" do
      part = ContentPart.image("base64data", media_type: "image/jpeg")
      assert part.type == :image
      assert part.content == "base64data"
      assert part.options == %{media_type: "image/jpeg"}
    end

    test "thinking/1 creates thinking content part" do
      part = ContentPart.thinking("Let me think...")
      assert part.type == :thinking
      assert part.content == "Let me think..."
    end
  end

  describe "utility functions" do
    test "extract_text/1 extracts text from content parts" do
      parts = [
        ContentPart.text("Hello "),
        ContentPart.image_url("https://example.com/img.jpg"),
        ContentPart.text("world")
      ]

      assert ContentPart.extract_text(parts) == "Hello world"
    end

    test "to_text/1 converts all parts to text representation" do
      parts = [
        ContentPart.text("Look: "),
        ContentPart.image_url("https://example.com/img.jpg"),
        ContentPart.thinking("hmm")
      ]

      result = ContentPart.to_text(parts)
      assert result == "Look: [Image: https://example.com/img.jpg][Thinking: hmm]"
    end

    test "merge/2 merges content parts of same type" do
      part1 = ContentPart.text("Hello ")
      part2 = ContentPart.text("world")

      merged = ContentPart.merge(part1, part2)
      assert merged.type == :text
      assert merged.content == "Hello world"
    end

    test "merge/2 returns error for different types" do
      part1 = ContentPart.text("Hello")
      part2 = ContentPart.image_url("https://example.com/img.jpg")

      assert {:error, :incompatible_types} = ContentPart.merge(part1, part2)
    end
  end
end

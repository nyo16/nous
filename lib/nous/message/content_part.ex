defmodule Nous.Message.ContentPart do
  @moduledoc """
  Represents a part of message content supporting multi-modal inputs.

  ContentPart enables rich message composition with text, images, files,
  and other content types. Each part has a type and content, with optional
  provider-specific metadata.

  ## Content Types

  - `:text` - Plain text content
  - `:image_url` - Image from URL or data URI
  - `:image` - Image with base64 data and metadata
  - `:file` - File attachment
  - `:file_url` - File from URL
  - `:thinking` - Reasoning/thinking content (for models that support it)

  ## Examples

      # Text content
      iex> ContentPart.text("Hello, world!")
      %ContentPart{type: :text, content: "Hello, world!", options: %{}}

      # Image from URL
      iex> ContentPart.image_url("https://example.com/image.jpg")
      %ContentPart{type: :image_url, content: "https://example.com/image.jpg", options: %{}}

      # Image with metadata
      iex> ContentPart.image("base64data", media_type: "image/jpeg")
      %ContentPart{type: :image, content: "base64data", options: %{media_type: "image/jpeg"}}

  """

  use Ecto.Schema
  import Ecto.Changeset

  @content_types ~w(text image_url image file file_url thinking)a

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: @content_types
    field :content, :string
    field :options, :map, default: %{}
  end

  @type t :: %__MODULE__{
          type: atom(),
          content: String.t(),
          options: map()
        }

  @doc """
  Create a new content part.

  Returns `{:ok, content_part}` on success or `{:error, changeset}` on validation failure.

  ## Examples

      iex> ContentPart.new(%{type: :text, content: "Hello"})
      {:ok, %ContentPart{type: :text, content: "Hello"}}

      iex> ContentPart.new(%{type: :invalid})
      {:error, %Ecto.Changeset{}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> case do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, Ecto.Changeset.apply_changes(changeset)}

      invalid_changeset ->
        {:error, invalid_changeset}
    end
  end

  @doc """
  Create a new content part, raising on validation failure.

  ## Examples

      iex> ContentPart.new!(%{type: :text, content: "Hello"})
      %ContentPart{type: :text, content: "Hello"}

  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, content_part} -> content_part
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  # Convenience constructors

  @doc """
  Create a text content part.

  ## Examples

      iex> ContentPart.text("Hello, world!")
      %ContentPart{type: :text, content: "Hello, world!"}

  """
  @spec text(String.t()) :: t()
  def text(content) when is_binary(content) do
    new!(%{type: :text, content: content})
  end

  @doc """
  Create an image URL content part.

  ## Examples

      iex> ContentPart.image_url("https://example.com/image.jpg")
      %ContentPart{type: :image_url, content: "https://example.com/image.jpg"}

      iex> ContentPart.image_url("data:image/jpeg;base64,/9j/4AAQ...")
      %ContentPart{type: :image_url, content: "data:image/jpeg;base64,/9j/4AAQ..."}

  """
  @spec image_url(String.t()) :: t()
  def image_url(url) when is_binary(url) do
    new!(%{type: :image_url, content: url})
  end

  @doc """
  Create an image content part with metadata.

  ## Options

  - `:media_type` - MIME type (e.g., "image/jpeg", "image/png")
  - `:cache_control` - Caching hints for providers that support it

  ## Examples

      iex> ContentPart.image("base64data", media_type: "image/jpeg")
      %ContentPart{type: :image, content: "base64data", options: %{media_type: "image/jpeg"}}

  """
  @spec image(String.t(), keyword()) :: t()
  def image(data, opts \\ []) when is_binary(data) do
    new!(%{type: :image, content: data, options: Map.new(opts)})
  end

  @doc """
  Create a file content part.

  ## Examples

      iex> ContentPart.file("/path/to/file.pdf", media_type: "application/pdf")
      %ContentPart{type: :file, content: "/path/to/file.pdf", options: %{media_type: "application/pdf"}}

  """
  @spec file(String.t(), keyword()) :: t()
  def file(path_or_data, opts \\ []) when is_binary(path_or_data) do
    new!(%{type: :file, content: path_or_data, options: Map.new(opts)})
  end

  @doc """
  Create a file URL content part.

  ## Examples

      iex> ContentPart.file_url("https://example.com/document.pdf")
      %ContentPart{type: :file_url, content: "https://example.com/document.pdf"}

  """
  @spec file_url(String.t()) :: t()
  def file_url(url) when is_binary(url) do
    new!(%{type: :file_url, content: url})
  end

  @doc """
  Create a thinking content part for models that support reasoning.

  ## Examples

      iex> ContentPart.thinking("Let me think about this step by step...")
      %ContentPart{type: :thinking, content: "Let me think about this step by step..."}

  """
  @spec thinking(String.t()) :: t()
  def thinking(content) when is_binary(content) do
    new!(%{type: :thinking, content: content})
  end

  # Utility functions

  @doc """
  Extract text content from a list of content parts.

  ## Examples

      iex> parts = [ContentPart.text("Hello"), ContentPart.text(" world")]
      iex> ContentPart.extract_text(parts)
      "Hello world"

  """
  @spec extract_text([t()]) :: String.t()
  def extract_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.content)
    |> Enum.join("")
  end

  @doc """
  Convert content parts to plain text representation.

  ## Examples

      iex> parts = [
      ...>   ContentPart.text("Look at this: "),
      ...>   ContentPart.image_url("https://example.com/img.jpg"),
      ...>   ContentPart.text(" Amazing!")
      ...> ]
      iex> ContentPart.to_text(parts)
      "Look at this: [Image: https://example.com/img.jpg] Amazing!"

  """
  @spec to_text([t()]) :: String.t()
  def to_text(parts) when is_list(parts) do
    parts
    |> Enum.map(&part_to_text/1)
    |> Enum.join("")
  end

  @doc """
  Merge content parts of the same type.

  Useful for streaming where deltas arrive incrementally.

  ## Examples

      iex> part1 = ContentPart.text("Hello")
      iex> part2 = ContentPart.text(" world")
      iex> ContentPart.merge(part1, part2)
      %ContentPart{type: :text, content: "Hello world"}

  """
  @spec merge(t(), t()) :: t() | {:error, :incompatible_types}
  def merge(%__MODULE__{type: type} = part1, %__MODULE__{type: type} = part2) do
    merged_options = Map.merge(part1.options, part2.options, fn _key, v1, v2 ->
      case {v1, v2} do
        {s1, s2} when is_binary(s1) and is_binary(s2) -> s1 <> s2
        {_, v2} -> v2
      end
    end)

    %__MODULE__{
      type: type,
      content: part1.content <> part2.content,
      options: merged_options
    }
  end

  def merge(%__MODULE__{type: type1}, %__MODULE__{type: type2}) when type1 != type2 do
    {:error, :incompatible_types}
  end

  # Image conversion utilities

  @doc """
  Create an image content part from a local file path.

  Reads the file, detects the MIME type, and converts to base64 data URL.

  ## Examples

      iex> ContentPart.from_file("/path/to/image.jpg")
      {:ok, %ContentPart{type: :image_url, content: "data:image/jpeg;base64,..."}}

      iex> ContentPart.from_file("/nonexistent.jpg")
      {:error, :enoent}

  """
  @spec from_file(String.t()) :: {:ok, t()} | {:error, atom()}
  def from_file(file_path) when is_binary(file_path) do
    case File.read(file_path) do
      {:ok, binary_data} ->
        mime_type = detect_mime_type(file_path)
        data_url = to_data_url(binary_data, mime_type)
        {:ok, image_url(data_url)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create an image content part from a local file path, raising on error.

  ## Examples

      iex> ContentPart.from_file!("/path/to/image.jpg")
      %ContentPart{type: :image_url, content: "data:image/jpeg;base64,..."}

  """
  @spec from_file!(String.t()) :: t()
  def from_file!(file_path) when is_binary(file_path) do
    case from_file(file_path) do
      {:ok, content_part} -> content_part
      {:error, reason} -> raise "Failed to read image file #{file_path}: #{reason}"
    end
  end

  @doc """
  Convert binary image data to a data URL.

  ## Examples

      iex> binary_data = <<137, 80, 78, 71, 13, 10, 26, 10>>
      iex> ContentPart.to_data_url(binary_data, "image/png")
      "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"

  """
  @spec to_data_url(binary(), String.t()) :: String.t()
  def to_data_url(binary_data, mime_type) when is_binary(binary_data) and is_binary(mime_type) do
    base64_data = Base.encode64(binary_data)
    "data:#{mime_type};base64,#{base64_data}"
  end

  @doc """
  Convert base64 string to a data URL.

  ## Examples

      iex> base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
      iex> ContentPart.base64_to_data_url(base64, "image/png")
      "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"

  """
  @spec base64_to_data_url(String.t(), String.t()) :: String.t()
  def base64_to_data_url(base64_string, mime_type) when is_binary(base64_string) and is_binary(mime_type) do
    "data:#{mime_type};base64,#{base64_string}"
  end

  @doc """
  Detect MIME type from file extension.

  ## Examples

      iex> ContentPart.detect_mime_type("/path/to/image.jpg")
      "image/jpeg"

      iex> ContentPart.detect_mime_type("photo.png")
      "image/png"

      iex> ContentPart.detect_mime_type("unknown.xyz")
      "application/octet-stream"

  """
  @spec detect_mime_type(String.t()) :: String.t()
  def detect_mime_type(file_path) when is_binary(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".bmp" -> "image/bmp"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".ico" -> "image/x-icon"
      ".tiff" -> "image/tiff"
      ".tif" -> "image/tiff"
      _ -> "application/octet-stream"
    end
  end

  @doc """
  Create a 1x1 pixel test image as base64 data URL.

  Useful for testing multi-modal functionality.

  ## Examples

      iex> test_image = ContentPart.test_image()
      iex> test_image.type
      :image_url
      iex> String.starts_with?(test_image.content, "data:image/png;base64,")
      true

  """
  @spec test_image() :: t()
  def test_image do
    # 1x1 transparent PNG
    data_url = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    image_url(data_url)
  end

  @doc """
  Create an image content part from binary data with automatic MIME detection.

  ## Examples

      iex> {:ok, image_data} = File.read("photo.jpg")
      iex> ContentPart.from_binary(image_data, "photo.jpg")
      %ContentPart{type: :image_url, content: "data:image/jpeg;base64,..."}

  """
  @spec from_binary(binary(), String.t()) :: t()
  def from_binary(binary_data, filename_hint \\ "image.png") when is_binary(binary_data) do
    mime_type = detect_mime_type(filename_hint)
    data_url = to_data_url(binary_data, mime_type)
    image_url(data_url)
  end

  # Private functions

  defp changeset(content_part, attrs) do
    content_part
    |> cast(attrs, [:type, :content, :options])
    |> validate_required([:type])
    |> validate_content()
  end

  defp validate_content(%Ecto.Changeset{} = changeset) do
    type = get_field(changeset, :type)
    content = get_field(changeset, :content)

    case {type, content} do
      {nil, _} ->
        changeset

      {_, nil} ->
        add_error(changeset, :content, "content is required")

      {_, ""} ->
        add_error(changeset, :content, "content cannot be empty")

      {:image_url, content} ->
        validate_image_url(changeset, content)

      {:file_url, content} ->
        validate_url(changeset, content)

      _ ->
        changeset
    end
  end

  defp validate_image_url(changeset, content) do
    cond do
      String.starts_with?(content, "data:image/") ->
        changeset

      String.starts_with?(content, "http://") or String.starts_with?(content, "https://") ->
        changeset

      true ->
        add_error(changeset, :content, "image_url must be a valid URL or data URI")
    end
  end

  defp validate_url(changeset, content) do
    if String.starts_with?(content, "http://") or String.starts_with?(content, "https://") do
      changeset
    else
      add_error(changeset, :content, "must be a valid URL")
    end
  end

  defp part_to_text(%__MODULE__{type: :text, content: content}), do: content
  defp part_to_text(%__MODULE__{type: :image_url, content: url}), do: "[Image: #{url}]"
  defp part_to_text(%__MODULE__{type: :image, content: _}), do: "[Image]"
  defp part_to_text(%__MODULE__{type: :file, content: path}), do: "[File: #{path}]"
  defp part_to_text(%__MODULE__{type: :file_url, content: url}), do: "[File: #{url}]"
  defp part_to_text(%__MODULE__{type: :thinking, content: content}), do: "[Thinking: #{content}]"
end
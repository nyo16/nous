defmodule Nous.Tools.FileWrite do
  @moduledoc """
  File writing tool.

  Creates or overwrites files. Automatically creates parent directories
  if they don't exist.
  """

  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata do
    %{
      name: "file_write",
      description: "Write content to a file. Creates parent directories if needed.",
      category: :write,
      requires_approval: true,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to write"
          },
          "content" => %{
            "type" => "string",
            "description" => "The content to write to the file"
          }
        },
        "required" => ["file_path", "content"]
      }
    }
  end

  @impl true
  def execute(_ctx, %{"file_path" => file_path, "content" => content}) do
    dir = Path.dirname(file_path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(file_path, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{file_path}"}
    else
      {:error, reason} ->
        {:error, "Failed to write #{file_path}: #{inspect(reason)}"}
    end
  end
end

defmodule Nous.Tools.FileRead do
  @moduledoc """
  File reading tool with line numbers.

  Returns file content with `cat -n` style line numbers, supporting
  offset and limit for reading specific sections of large files.
  """

  @behaviour Nous.Tool.Behaviour

  @default_limit 2000

  @impl true
  def metadata do
    %{
      name: "file_read",
      description: "Read a file from the filesystem. Returns content with line numbers.",
      category: :read,
      requires_approval: false,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to read"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start reading from (1-based). Defaults to 1."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Number of lines to read. Defaults to 2000."
          }
        },
        "required" => ["file_path"]
      }
    }
  end

  @impl true
  def execute(ctx, %{"file_path" => file_path} = args) do
    offset = Map.get(args, "offset", 1) |> max(1)
    limit = Map.get(args, "limit", @default_limit)

    with {:ok, safe_path} <- Nous.Tools.PathGuard.validate(file_path, ctx),
         {:ok, content} <- File.read(safe_path) do
      result =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.drop(offset - 1)
        |> Enum.take(limit)
        |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
        |> Enum.join("\n")

      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to read #{file_path}: #{inspect(reason)}"}
    end
  end
end

defmodule Coderex.Tools.FileTools do
  @moduledoc """
  File operation tools for the code agent.

  Provides tools for reading, writing, listing, and searching files.
  """

  alias Coderex.Diff
  alias Coderex.DiffFormatter

  @doc """
  Read the contents of a file.

  Parameters:
    - path: The file path to read (relative to working directory)
  """
  def read_file(ctx, %{"path" => path}) do
    full_path = resolve_path(ctx, path)

    case File.read(full_path) do
      {:ok, content} ->
        %{
          path: path,
          content: content,
          lines: length(String.split(content, "\n"))
        }

      {:error, :enoent} ->
        %{error: "File not found: #{path}"}

      {:error, reason} ->
        %{error: "Failed to read file: #{inspect(reason)}"}
    end
  end

  @doc """
  Write content to a file, creating it if it doesn't exist.

  Parameters:
    - path: The file path to write to
    - content: The complete content to write
  """
  def write_file(ctx, %{"path" => path, "content" => content}) do
    full_path = resolve_path(ctx, path)

    # Ensure directory exists
    full_path |> Path.dirname() |> File.mkdir_p()

    case File.write(full_path, content) do
      :ok ->
        %{
          success: true,
          path: path,
          bytes_written: byte_size(content)
        }

      {:error, reason} ->
        %{error: "Failed to write file: #{inspect(reason)}"}
    end
  end

  @doc """
  Apply a SEARCH/REPLACE diff to modify a file.

  Parameters:
    - path: The file path to modify
    - diff: The SEARCH/REPLACE block(s) to apply

  The diff format:
      ------- SEARCH
      [exact content to find]
      =======
      [replacement content]
      +++++++ REPLACE
  """
  def edit_file(ctx, %{"path" => path, "diff" => diff}) do
    full_path = resolve_path(ctx, path)
    show_diff = Map.get(ctx.deps, :show_diff, true)

    with {:ok, original} <- File.read(full_path),
         {:ok, new_content} <- Diff.construct_new_content(diff, original, true),
         :ok <- File.write(full_path, new_content) do

      # Format the diff for display
      diff_output = if show_diff do
        DiffFormatter.format_edit_result(path, original, new_content, color: true)
      else
        nil
      end

      %{
        success: true,
        path: path,
        original_lines: length(String.split(original, "\n")),
        new_lines: length(String.split(new_content, "\n")),
        diff_output: diff_output
      }
    else
      {:error, :enoent} ->
        %{error: "File not found: #{path}"}

      {:error, reason} when is_binary(reason) ->
        %{error: "Diff error: #{reason}"}

      {:error, reason} ->
        %{error: "Failed to edit file: #{inspect(reason)}"}
    end
  end

  @doc """
  Preview a SEARCH/REPLACE diff without applying it.

  Parameters:
    - path: The file path to preview changes for
    - diff: The SEARCH/REPLACE block(s) to preview
  """
  def preview_edit(ctx, %{"path" => path, "diff" => diff}) do
    full_path = resolve_path(ctx, path)

    with {:ok, original} <- File.read(full_path),
         {:ok, new_content} <- Diff.construct_new_content(diff, original, true) do

      diff_output = DiffFormatter.format_edit_result(path, original, new_content, color: true)

      %{
        success: true,
        path: path,
        preview: diff_output,
        original_lines: length(String.split(original, "\n")),
        new_lines: length(String.split(new_content, "\n"))
      }
    else
      {:error, :enoent} ->
        %{error: "File not found: #{path}"}

      {:error, reason} when is_binary(reason) ->
        %{error: "Diff error: #{reason}"}

      {:error, reason} ->
        %{error: "Failed to preview edit: #{inspect(reason)}"}
    end
  end

  @doc """
  List files in a directory.

  Parameters:
    - path: The directory path (defaults to working directory)
    - pattern: Optional glob pattern to filter files (e.g., "*.ex")
    - recursive: Whether to list recursively (default: false)
  """
  def list_files(ctx, args) do
    path = Map.get(args, "path", ".")
    pattern = Map.get(args, "pattern", "*")
    recursive = Map.get(args, "recursive", false)

    full_path = resolve_path(ctx, path)

    files = if recursive do
      Path.wildcard(Path.join([full_path, "**", pattern]))
    else
      Path.wildcard(Path.join(full_path, pattern))
    end

    # Filter to regular files and make paths relative
    cwd = get_cwd(ctx)
    relative_files = files
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn f -> Path.relative_to(f, cwd) end)
    |> Enum.sort()

    %{
      path: path,
      pattern: pattern,
      recursive: recursive,
      files: relative_files,
      count: length(relative_files)
    }
  end

  @doc """
  Search for text pattern in files.

  Parameters:
    - pattern: The regex pattern to search for
    - path: Directory to search in (defaults to working directory)
    - glob: File pattern to search (e.g., "*.ex")
    - max_results: Maximum number of results (default: 50)
  """
  def search_files(ctx, args) do
    pattern = Map.fetch!(args, "pattern")
    path = Map.get(args, "path", ".")
    glob = Map.get(args, "glob", "*")
    max_results = Map.get(args, "max_results", 50)

    full_path = resolve_path(ctx, path)
    cwd = get_cwd(ctx)

    regex = case Regex.compile(pattern) do
      {:ok, r} -> r
      {:error, _} -> ~r/#{Regex.escape(pattern)}/
    end

    files = Path.wildcard(Path.join([full_path, "**", glob]))
    |> Enum.filter(&File.regular?/1)

    results = files
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {line, line_num} ->
            %{
              file: Path.relative_to(file, cwd),
              line: line_num,
              content: String.trim(line)
            }
          end)
        _ -> []
      end
    end)
    |> Enum.take(max_results)

    %{
      pattern: pattern,
      path: path,
      glob: glob,
      results: results,
      count: length(results),
      truncated: length(results) >= max_results
    }
  end

  @doc """
  Get file information (exists, size, type, etc.)

  Parameters:
    - path: The file path to check
  """
  def file_info(ctx, %{"path" => path}) do
    full_path = resolve_path(ctx, path)

    case File.stat(full_path) do
      {:ok, stat} ->
        %{
          path: path,
          exists: true,
          type: stat.type,
          size: stat.size,
          mtime: stat.mtime
        }

      {:error, :enoent} ->
        %{path: path, exists: false}

      {:error, reason} ->
        %{error: "Failed to get file info: #{inspect(reason)}"}
    end
  end

  @doc """
  Create a directory.

  Parameters:
    - path: The directory path to create
  """
  def create_directory(ctx, %{"path" => path}) do
    full_path = resolve_path(ctx, path)

    case File.mkdir_p(full_path) do
      :ok ->
        %{success: true, path: path}

      {:error, reason} ->
        %{error: "Failed to create directory: #{inspect(reason)}"}
    end
  end

  @doc """
  Delete a file.

  Parameters:
    - path: The file path to delete
  """
  def delete_file(ctx, %{"path" => path}) do
    full_path = resolve_path(ctx, path)

    case File.rm(full_path) do
      :ok ->
        %{success: true, path: path}

      {:error, :enoent} ->
        %{error: "File not found: #{path}"}

      {:error, reason} ->
        %{error: "Failed to delete file: #{inspect(reason)}"}
    end
  end

  # Helper functions

  defp resolve_path(ctx, path) do
    cwd = get_cwd(ctx)
    Path.expand(path, cwd)
  end

  defp get_cwd(ctx) do
    ctx.deps[:cwd] || File.cwd!()
  end
end

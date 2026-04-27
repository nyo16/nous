defmodule Nous.Tools.FileGlob do
  @moduledoc """
  File pattern matching tool.

  Finds files matching glob patterns using `Path.wildcard/2`.
  Results are sorted by modification time (most recent first).
  """

  @behaviour Nous.Tool.Behaviour

  @default_limit 200

  @impl true
  def metadata do
    %{
      name: "file_glob",
      description: "Find files matching a glob pattern (e.g. \"**/*.ex\", \"lib/**/*.exs\").",
      category: :search,
      requires_approval: false,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to match files (e.g. \"**/*.ex\")"
          },
          "path" => %{
            "type" => "string",
            "description" => "Base directory to search from. Defaults to current directory."
          }
        },
        "required" => ["pattern"]
      }
    }
  end

  @impl true
  def execute(ctx, %{"pattern" => pattern} = args) do
    base = Map.get(args, "path", ".")

    case Nous.Tools.PathGuard.validate(base, ctx) do
      {:ok, safe_base} ->
        full_pattern = Path.join(safe_base, pattern)

        files =
          full_pattern
          |> Path.wildcard(match_dot: false)
          # Keep regular files inside the workspace (rejects directories,
          # special files, and matches that escaped the workspace via symlink).
          |> Enum.filter(fn f ->
            File.regular?(f) and match?({:ok, _}, Nous.Tools.PathGuard.validate(f, ctx))
          end)
          |> sort_by_mtime()
          |> Enum.take(@default_limit)

        if files == [] do
          {:ok, "No files matched pattern: #{pattern}"}
        else
          {:ok, Enum.join(files, "\n")}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sort_by_mtime(files) do
    Enum.sort_by(files, fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %{mtime: mtime}} -> -mtime
        _ -> 0
      end
    end)
  end
end

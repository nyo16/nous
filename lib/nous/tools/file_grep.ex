defmodule Nous.Tools.FileGrep do
  @moduledoc """
  Content search tool.

  Searches file contents using regex patterns. Uses `ripgrep` (rg)
  when available for performance, falls back to pure Elixir regex.
  """

  @behaviour Nous.Tool.Behaviour

  @default_limit 250

  @impl true
  def metadata do
    %{
      name: "file_grep",
      description: "Search file contents using regex patterns. Uses ripgrep when available.",
      category: :search,
      requires_approval: false,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regular expression pattern to search for"
          },
          "path" => %{
            "type" => "string",
            "description" => "File or directory to search in. Defaults to current directory."
          },
          "glob" => %{
            "type" => "string",
            "description" => "Glob filter for files (e.g. \"*.ex\", \"*.{ts,tsx}\")"
          },
          "output_mode" => %{
            "type" => "string",
            "description" =>
              "Output mode: \"content\" (matching lines), \"files_with_matches\" (file paths only), \"count\" (match counts). Defaults to \"files_with_matches\"."
          }
        },
        "required" => ["pattern"]
      }
    }
  end

  @impl true
  def execute(_ctx, %{"pattern" => pattern} = args) do
    path = Map.get(args, "path", ".")
    glob = Map.get(args, "glob")
    output_mode = Map.get(args, "output_mode", "files_with_matches")

    if rg_available?() do
      run_rg(pattern, path, glob, output_mode)
    else
      run_elixir_grep(pattern, path, glob, output_mode)
    end
  end

  defp rg_available? do
    case System.cmd("which", ["rg"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp run_rg(pattern, path, glob, output_mode) do
    args =
      [pattern, path] ++
        mode_flag(output_mode) ++
        glob_flag(glob) ++
        ["--max-count", "#{@default_limit}"]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, "rg failed: #{String.trim(output)}"}
    end
  end

  defp mode_flag("content"), do: ["-n"]
  defp mode_flag("count"), do: ["--count"]
  defp mode_flag(_), do: ["--files-with-matches"]

  defp glob_flag(nil), do: []
  defp glob_flag(glob), do: ["--glob", glob]

  defp run_elixir_grep(pattern, path, glob, output_mode) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        files = find_files(path, glob)
        results = search_files(files, regex, output_mode)
        result = Enum.join(results, "\n")
        {:ok, if(result == "", do: "No matches found", else: result)}

      {:error, {reason, _}} ->
        {:error, "Invalid regex: #{reason}"}
    end
  end

  defp find_files(path, nil) do
    if File.regular?(path) do
      [path]
    else
      Path.wildcard(Path.join(path, "**/*"))
      |> Enum.filter(&File.regular?/1)
    end
  end

  defp find_files(path, glob) do
    Path.wildcard(Path.join(path, glob))
    |> Enum.filter(&File.regular?/1)
  end

  defp search_files(files, regex, output_mode) do
    files
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, content} ->
          lines = String.split(content, "\n")

          matches =
            lines
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)

          case output_mode do
            "files_with_matches" ->
              if matches != [], do: [file], else: []

            "count" ->
              if matches != [], do: ["#{file}:#{length(matches)}"], else: []

            _ ->
              Enum.map(matches, fn {line, num} -> "#{file}:#{num}:#{line}" end)
          end

        _ ->
          []
      end
    end)
    |> Enum.take(@default_limit)
  end
end

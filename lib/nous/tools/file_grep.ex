defmodule Nous.Tools.FileGrep do
  @moduledoc """
  Content search tool.

  Searches file contents using regex patterns. Uses `ripgrep` (rg)
  when available for performance, falls back to pure Elixir regex.
  """

  use Nous.Tool.Schema

  @default_limit 250

  tool "file_grep",
    description: "Search file contents using regex patterns. Uses ripgrep when available.",
    category: :search do
    param(:pattern, :string, required: true, doc: "Regular expression pattern to search for")

    param(:path, :string, doc: "File or directory to search in. Defaults to current directory.")

    param(:glob, :string, doc: "Glob filter for files (e.g. \"*.ex\", \"*.{ts,tsx}\")")

    param(:output_mode, :string,
      doc:
        "Output mode: \"content\" (matching lines), \"files_with_matches\" (file paths only), \"count\" (match counts). Defaults to \"files_with_matches\"."
    )
  end

  @impl true
  def execute(ctx, %{"pattern" => pattern} = args) do
    path = Map.get(args, "path", ".")
    glob = Map.get(args, "glob")
    output_mode = Map.get(args, "output_mode", "files_with_matches")

    case Nous.Tools.PathGuard.validate(path, ctx) do
      {:ok, safe_path} ->
        if rg_available?() do
          run_rg(pattern, safe_path, glob, output_mode)
        else
          run_elixir_grep(pattern, safe_path, glob, output_mode, ctx)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve rg's absolute path once at module load to avoid PATH-poisoning
  # (a user-controlled `rg` binary earlier on PATH would shadow the real one).
  # Returns nil if rg isn't installed.
  defp rg_path do
    case System.find_executable("rg") do
      nil -> nil
      path -> path
    end
  end

  defp rg_available?, do: not is_nil(rg_path())

  defp run_rg(pattern, path, glob, output_mode) do
    # SECURITY: the LLM controls `pattern`/`glob`. Pass the pattern with an
    # explicit `--regexp` flag (rg consumes the following token as its value
    # even if it starts with `-`) and terminate option parsing with `--` before
    # the positional `path`. Without this, a pattern like `-f/etc/passwd` or
    # `--pre=/bin/sh` would be reinterpreted as an rg flag and escape PathGuard.
    args =
      ["--regexp", pattern] ++
        mode_flag(output_mode) ++
        glob_flag(glob) ++
        ["--max-count", "#{@default_limit}", "--", path]

    # `env -i` wrapping, not an `env:` option: System.cmd/3's `:env` MERGES into
    # the inherited environment, so it can never remove OPENAI_API_KEY et al.
    # See `Nous.Tools.Env`.
    [cmd | cmd_args] = Nous.Tools.Env.scrub_argv([rg_path() | args])

    case System.cmd(cmd, cmd_args, stderr_to_stdout: true) do
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

  # The pure-Elixir fallback runs an LLM-controlled regex (`:re` has no ReDoS
  # backstop) over file contents. Bound the worst case with a hard timeout so a
  # catastrophically-backtracking pattern aborts instead of hanging the agent.
  # (The preferred rg engine is immune; this only guards the fallback path.)
  @elixir_grep_timeout 5_000

  defp run_elixir_grep(pattern, path, glob, output_mode, ctx) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        search = fn ->
          files = find_files(path, glob, ctx)
          results = search_files(files, regex, output_mode)
          Enum.join(results, "\n")
        end

        case Nous.Tasks.async_nolink(search) do
          {:ok, task} -> await_grep(task)
          {:error, :saturated} -> saturated_error()
        end

      {:error, {reason, _}} ->
        {:error, "Invalid regex: #{reason}"}
    end
  end

  defp await_grep(task) do
    case Task.yield(task, @elixir_grep_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, if(result == "", do: "No matches found", else: result)}

      _ ->
        {:error,
         "search timed out after #{@elixir_grep_timeout}ms (the pattern may be " <>
           "pathological); install ripgrep for a fast, ReDoS-immune engine"}
    end
  end

  # The task IS the ReDoS guard here, so there is nothing to degrade to: running
  # the fallback inline would put an LLM-supplied regex with NO timeout in the
  # calling process — trading a refused search for a hung agent turn. Refuse
  # instead. `run_rg/4` is a plain System.cmd with no task, so this can only be
  # reached on a host without ripgrep.
  defp saturated_error do
    Nous.Tasks.warn_saturated("a pure-Elixir file_grep fallback")

    {:error,
     "search could not start: the task supervisor is at capacity. Retry shortly, " <>
       "or install ripgrep so searches run without a task"}
  end

  # Re-validate every matched file against the workspace root (mirrors
  # Nous.Tools.FileGlob). `Path.wildcard` follows directory symlinks and the
  # `glob` arg is LLM-controlled, so a wildcard result can otherwise resolve
  # outside the root.
  defp find_files(path, nil, ctx) do
    if File.regular?(path) do
      [path]
    else
      Path.wildcard(Path.join(path, "**/*"))
      |> Enum.filter(&within_workspace?(&1, ctx))
    end
  end

  defp find_files(path, glob, ctx) do
    Path.wildcard(Path.join(path, glob))
    |> Enum.filter(&within_workspace?(&1, ctx))
  end

  defp within_workspace?(file, ctx) do
    File.regular?(file) and match?({:ok, _}, Nous.Tools.PathGuard.validate(file, ctx))
  end

  defp search_files(files, regex, output_mode) do
    files
    |> Enum.flat_map(&file_matches(&1, regex, output_mode))
    |> Enum.take(@default_limit)
  end

  # One file's contribution to the result set. An unreadable file contributes
  # nothing rather than aborting the whole search.
  defp file_matches(file, regex, output_mode) do
    case File.read(file) do
      {:ok, content} -> format_matches(file, matching_lines(content, regex), output_mode)
      _ -> []
    end
  end

  defp matching_lines(content, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
  end

  defp format_matches(_file, [], "files_with_matches"), do: []
  defp format_matches(file, _matches, "files_with_matches"), do: [file]

  defp format_matches(_file, [], "count"), do: []
  defp format_matches(file, matches, "count"), do: ["#{file}:#{length(matches)}"]

  defp format_matches(file, matches, _mode) do
    Enum.map(matches, fn {line, num} -> "#{file}:#{num}:#{line}" end)
  end
end

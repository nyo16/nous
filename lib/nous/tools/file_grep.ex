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

  # `rg` is resolved per call, against the BEAM's own PATH. That PATH is
  # operator-owned — no tool can alter the BEAM's environment, and
  # `Env.scrub_argv/1` re-establishes only that same PATH for the child while
  # dropping everything else — so nothing the model supplies takes part in the
  # lookup. Per call and not a compile-time attribute on purpose: a baked path
  # is the *build* image's, so a release run elsewhere, or a host that installs
  # rg after the build, would exec a stale path or take the pure-Elixir
  # fallback forever. The `stat` is free next to the fork/exec that follows it
  # (the same trade as `Env.env_executable/0`). Returns nil if rg isn't
  # installed.
  defp rg_path, do: System.find_executable("rg")

  defp rg_available?, do: not is_nil(rg_path())

  # SECURITY: the LLM controls `pattern`/`glob`. Pass the pattern with an
  # explicit `--regexp` flag (rg consumes the following token as its value
  # even if it starts with `-`) and terminate option parsing with `--` before
  # the positional `path`. Without this, a pattern like `-f/etc/passwd` or
  # `--pre=/bin/sh` would be reinterpreted as an rg flag and escape PathGuard.
  #
  # Public but `@doc false` (like `PathGuard.canonical_root/1`) so each
  # hardening can be pinned on its own. Measured against rg 15.1.0: dropping
  # `--regexp` reddens the end-to-end `--pre` canary (the pattern sits *before*
  # the terminator, so `--` cannot shield it), but dropping the `--` reddens
  # nothing — it only shields the trailing positional, and
  # `PathGuard.validate/2` hands back an absolute path that can never start
  # with `-`. The argv assertions in `coding_tools_test.exs` are the only thing
  # that can tell the `--` present from absent.
  @doc false
  @spec rg_argv(String.t(), String.t(), String.t() | nil, String.t()) :: [String.t()]
  def rg_argv(pattern, path, glob, output_mode) do
    ["--regexp", pattern] ++
      mode_flag(output_mode) ++
      glob_flag(glob) ++
      ["--max-count", "#{@default_limit}", "--", path]
  end

  defp run_rg(pattern, path, glob, output_mode) do
    args = rg_argv(pattern, path, glob, output_mode)

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

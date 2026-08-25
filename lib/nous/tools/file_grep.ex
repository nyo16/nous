defmodule Nous.Tools.FileGrep do
  @moduledoc """
  Content search tool.

  Searches file contents using regex patterns. Uses `ripgrep` (rg)
  when available for performance, falls back to pure Elixir regex.

  ## Sandbox exemption

  `ripgrep` is spawned with `System.cmd/3`, outside `NetRunner`, and is
  deliberately **not** confined by `Nous.Sandbox`. This is the documented
  exception to "NetRunner is the single execution path". The reasoning:

    * Neither provider restricts reads. Seatbelt's profile is
      `(allow default) (deny file-write*)` and bwrap binds `/` read-only, so
      confining a process that only ever reads adds exactly zero enforcement.
    * The argv is already hardened: the pattern goes through `--regexp` and a
      `--` terminator ends option parsing before the positional path, and the
      environment is scrubbed via `Nous.Tools.Env.scrubbed_overrides/0`.
    * The environment is genuinely scrubbed rather than merged: Erlang's
      `{env, _}` option *adds to* the inherited environment, so the allowlist
      is passed as `scrubbed_overrides/0`, which also emits `{name, false}` for
      every other currently-set variable and thereby actually unsets it.
    * Every matched path is re-validated through `Nous.Tools.PathGuard` before
      it reaches the caller.
    * `Nous.Sandbox` fails closed, so routing this tool through it would delete
      a working read-only search tool on every host with no provider installed
      — for no security gain whatsoever.
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
          run_rg(pattern, safe_path, glob, output_mode, ctx)
        else
          run_elixir_grep(pattern, safe_path, glob, output_mode, ctx)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve rg's absolute path once (memoized in :persistent_term at first
  # use, not at module load — compile-time resolution would bake the build
  # host's PATH into the beam). Passing the absolute path to System.cmd/3
  # avoids re-walking PATH per call; the memoized value also keeps the
  # rg_available?/run_rg pair from resolving twice per search.
  # Returns nil if rg isn't installed.
  defp rg_path do
    case :persistent_term.get({__MODULE__, :rg_path}, :unresolved) do
      :unresolved ->
        path = System.find_executable("rg")
        :persistent_term.put({__MODULE__, :rg_path}, path)
        path

      path ->
        path
    end
  end

  defp rg_available?, do: not is_nil(rg_path())

  defp run_rg(pattern, path, glob, output_mode, ctx) do
    # SECURITY: the LLM controls `pattern`/`glob`. Pass the pattern with an
    # explicit `--regexp` flag (rg consumes the following token as its value
    # even if it starts with `-`) and terminate option parsing with `--` before
    # the positional `path`. Without this, a pattern like `-f/etc/passwd` or
    # `--pre=/bin/sh` would be reinterpreted as an rg flag and escape PathGuard.
    # `--with-filename` forces every output line to start with the matched
    # path (even for a single-file target) so it can be re-validated below.
    args =
      ["--regexp", pattern] ++
        mode_flag(output_mode) ++
        glob_flag(glob) ++
        ["--max-count", "#{@default_limit}", "--with-filename", "--", path]

    rg = rg_path()

    # Scrubbed env keeps API keys out of the rg subprocess. `scrubbed_overrides/0`
    # rather than `scrubbed/0`: `System.cmd/3`'s `:env` merges into the inherited
    # environment, and `{name, false}` is the only way to remove a variable.
    case System.cmd(rg, args, stderr_to_stdout: true, env: Nous.Tools.Env.scrubbed_overrides()) do
      {output, 0} -> {:ok, output |> String.trim() |> filter_rg_output(output_mode, ctx)}
      {_output, 1} -> {:ok, "No matches found"}
      {output, _} -> {:error, "rg failed: #{String.trim(output)}"}
    end
  end

  # Re-validate every path rg reports against the workspace root, mirroring the
  # fallback path's `within_workspace?/2` filtering, so the moduledoc invariant
  # ("every matched path is re-validated") holds regardless of engine.
  # Validation is memoized per unique path: `content` mode emits up to
  # @default_limit lines PER FILE, and within_workspace?/2 costs a stat plus a
  # symlink-resolving PathGuard walk — per-line validation would multiply that
  # by the match count for no additional safety.
  defp filter_rg_output(output, output_mode, ctx) do
    lines = String.split(output, "\n")

    verdicts =
      lines
      |> Enum.map(&rg_line_path(&1, output_mode))
      |> Enum.uniq()
      |> Map.new(fn path -> {path, within_workspace?(path, ctx)} end)

    lines
    |> Enum.filter(&Map.fetch!(verdicts, rg_line_path(&1, output_mode)))
    |> case do
      [] -> "No matches found"
      lines -> Enum.join(lines, "\n")
    end
  end

  # `content` lines are `path:line:text` and `count` lines are `path:count`;
  # files-with-matches lines are the bare path.
  defp rg_line_path(line, mode) when mode in ["content", "count"] do
    line |> String.split(":", parts: 2) |> hd()
  end

  defp rg_line_path(line, _files_with_matches), do: line

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
        task =
          Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
            files = find_files(path, glob, ctx)
            results = search_files(files, regex, output_mode)
            Enum.join(results, "\n")
          end)

        case Task.yield(task, @elixir_grep_timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            {:ok, if(result == "", do: "No matches found", else: result)}

          {:exit, reason} ->
            {:error, "search failed: the search task crashed (#{inspect(reason)})"}

          nil ->
            {:error,
             "search timed out after #{@elixir_grep_timeout}ms (the pattern may be " <>
               "pathological); install ripgrep for a fast, ReDoS-immune engine"}
        end

      {:error, {reason, _}} ->
        {:error, "Invalid regex: #{reason}"}
    end
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

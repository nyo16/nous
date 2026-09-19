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

  # Total bytes either engine may hand back. Same ceiling and marker as
  # `Nous.Tools.Bash`: `--max-count` bounds matches per FILE, so a tree with
  # thousands of matching files still produced megabytes.
  @max_output_size 1_000_000
  @truncation_marker "\n\n[Output truncated at #{@max_output_size} bytes]"

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
      {output, 0} ->
        # Cut BEFORE re-validation: the cut lands on a line boundary, so every
        # line the validator sees is a complete rg record with its path intact,
        # and bounding the input here also bounds the stat + PathGuard walk per
        # unique path (thousands of files otherwise). Filtering only removes
        # lines, so the result stays within the cap; the marker goes on last.
        {output, truncated?} = output |> String.trim() |> truncate_lines()
        result = filter_rg_output(output, output_mode, ctx)
        {:ok, if(truncated?, do: result <> @truncation_marker, else: result)}

      {_output, 1} ->
        {:ok, "No matches found"}

      {output, _} ->
        {:error, "rg failed: #{String.trim(output)}"}
    end
  end

  # Trim `text` to @max_output_size bytes on a line boundary. Returns the
  # prefix and whether anything was dropped; callers append @truncation_marker
  # themselves because the rg path filters between the cut and the marker.
  defp truncate_lines(text) when byte_size(text) <= @max_output_size, do: {text, false}

  defp truncate_lines(text) do
    prefix = binary_part(text, 0, @max_output_size)

    # Drop the partial last line. A single line longer than the cap has no
    # boundary to cut at; keep the raw prefix — the path sits at its head, so
    # re-validation still sees it whole.
    case :binary.matches(prefix, "\n") do
      [] ->
        {prefix, true}

      matches ->
        {pos, _} = List.last(matches)
        {binary_part(prefix, 0, pos), true}
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

  # Directories the fallback never descends into. rg gets the same effect from
  # .gitignore; the fallback has no ignore-file support, and build output plus
  # vendored deps is where an unbounded walk actually spends its time. Hidden
  # entries (`.git`, `.elixir_ls`, dotfiles) are dropped by `skip_entry?/1`'s
  # dot rule, matching both rg's default and `Path.wildcard`'s `match_dot: false`.
  @skip_dirs ~w(_build deps node_modules)

  # Per-file ceiling (10 MB). Files are streamed line by line, but a minified
  # bundle or data dump is one line the size of the file; skip it rather than
  # let a single file eat the timeout budget and the output cap.
  @max_file_bytes 10 * 1024 * 1024

  defp run_elixir_grep(pattern, path, glob, output_mode, ctx) do
    with {:ok, regex} <- compile_regex(pattern),
         {:ok, glob_regex} <- compile_glob(glob) do
      task =
        Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
          path
          |> find_files(glob_regex, ctx)
          |> collect_matches(regex, output_mode)
          |> Enum.join("\n")
        end)

      case Task.yield(task, @elixir_grep_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, ""} ->
          {:ok, "No matches found"}

        {:ok, result} ->
          {:ok, cap_output(result)}

        {:exit, reason} ->
          {:error, "search failed: the search task crashed (#{inspect(reason)})"}

        nil ->
          {:error,
           "search timed out after #{@elixir_grep_timeout}ms (the pattern may be " <>
             "pathological); install ripgrep for a fast, ReDoS-immune engine"}
      end
    end
  end

  defp cap_output(text) do
    case truncate_lines(text) do
      {text, false} -> text
      {prefix, true} -> prefix <> @truncation_marker
    end
  end

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "Invalid regex: #{reason}"}
    end
  end

  defp compile_glob(nil), do: {:ok, nil}

  defp compile_glob(glob) do
    case Regex.compile("^" <> glob_source(glob, 0) <> "$") do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "Invalid glob: #{reason}"}
    end
  end

  # `Path.wildcard` semantics, matched against the path relative to the search
  # root (so `*.ex` is top-level only and `**/*.ex` recurses, exactly as the
  # `Path.wildcard(Path.join(path, glob))` this replaces): `*` and `?` stop at
  # `/`, `**` spans directories, `{a,b}` alternates, `[...]` is a character
  # class. Everything else is literal. Second arg is the open-brace depth, so
  # a comma outside braces stays literal.
  defp glob_source(<<>>, _depth), do: ""
  defp glob_source(<<"**/", rest::binary>>, depth), do: "(?:.*/)?" <> glob_source(rest, depth)
  defp glob_source(<<"**", rest::binary>>, depth), do: ".*" <> glob_source(rest, depth)
  defp glob_source(<<"*", rest::binary>>, depth), do: "[^/]*" <> glob_source(rest, depth)
  defp glob_source(<<"?", rest::binary>>, depth), do: "[^/]" <> glob_source(rest, depth)
  defp glob_source(<<"{", rest::binary>>, depth), do: "(?:" <> glob_source(rest, depth + 1)

  defp glob_source(<<"}", rest::binary>>, depth) when depth > 0,
    do: ")" <> glob_source(rest, depth - 1)

  defp glob_source(<<",", rest::binary>>, depth) when depth > 0,
    do: "|" <> glob_source(rest, depth)

  defp glob_source(<<"[", rest::binary>>, depth) do
    case :binary.match(rest, "]") do
      {pos, 1} ->
        class = binary_part(rest, 0, pos + 1)
        after_class = binary_part(rest, pos + 1, byte_size(rest) - pos - 1)
        "[" <> class <> glob_source(after_class, depth)

      :nomatch ->
        "\\[" <> glob_source(rest, depth)
    end
  end

  defp glob_source(<<c, rest::binary>>, depth),
    do: Regex.escape(<<c>>) <> glob_source(rest, depth)

  # Lazy depth-first walk so `collect_matches/3` can halt at the limit without
  # the whole tree being listed first. Symlinked directories are not descended
  # (`lstat`), which also rules out symlink cycles; a symlinked file is still
  # emitted and then resolved through PathGuard by `within_workspace?/2`, so
  # every file opened has been re-validated against the workspace root.
  defp find_files(path, glob_regex, ctx) do
    if File.regular?(path) do
      # An explicit file target is searched as given; the glob filters a walk.
      Stream.filter([path], &within_workspace?(&1, ctx))
    else
      path
      |> children()
      |> Stream.unfold(&next_file/1)
      |> Stream.filter(&glob_match?(&1, path, glob_regex))
      |> Stream.filter(&within_workspace?(&1, ctx))
      |> Stream.filter(&searchable_size?/1)
    end
  end

  defp next_file([]), do: nil

  defp next_file([entry | rest]) do
    case File.lstat(entry) do
      {:ok, %File.Stat{type: :directory}} -> next_file(children(entry) ++ rest)
      _ -> {entry, rest}
    end
  end

  # Sorted so output order is stable across runs, like `Path.wildcard`'s.
  defp children(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names |> Enum.reject(&skip_entry?/1) |> Enum.sort() |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp skip_entry?("." <> _), do: true
  defp skip_entry?(name), do: name in @skip_dirs

  defp glob_match?(_file, _root, nil), do: true
  defp glob_match?(file, root, regex), do: Regex.match?(regex, Path.relative_to(file, root))

  defp within_workspace?(file, ctx) do
    File.regular?(file) and match?({:ok, _}, Nous.Tools.PathGuard.validate(file, ctx))
  end

  defp searchable_size?(file) do
    match?({:ok, %File.Stat{size: size}} when size <= @max_file_bytes, File.stat(file))
  end

  # Stops at @default_limit output lines, so a match-heavy tree is neither
  # walked nor read past what the caller can receive.
  defp collect_matches(files, regex, output_mode) do
    files
    |> Enum.reduce_while({[], @default_limit}, fn file, {acc, remaining} ->
      lines = search_file(file, regex, output_mode, remaining)
      remaining = remaining - length(lines)
      acc = Enum.reverse(lines, acc)
      if remaining > 0, do: {:cont, {acc, remaining}}, else: {:halt, {acc, 0}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Streamed by line rather than read whole: files-with-matches stops at the
  # first hit and content mode stops at `remaining`, so a large file costs no
  # more than the part actually needed. An unreadable file is skipped, as
  # before. A killed task (timeout) closes the port with the process.
  defp search_file(file, regex, output_mode, remaining) do
    case File.open(file, [:read, :binary, :read_ahead]) do
      {:ok, device} ->
        try do
          device
          |> IO.binstream(:line)
          |> Stream.map(&String.trim_trailing(&1, "\n"))
          |> matches(regex, output_mode, file, remaining)
        after
          File.close(device)
        end

      {:error, _} ->
        []
    end
  end

  defp matches(lines, regex, "files_with_matches", file, _remaining) do
    if Enum.any?(lines, &Regex.match?(regex, &1)), do: [file], else: []
  end

  defp matches(lines, regex, "count", file, _remaining) do
    case Enum.count(lines, &Regex.match?(regex, &1)) do
      0 -> []
      n -> ["#{file}:#{n}"]
    end
  end

  defp matches(lines, regex, _content, file, remaining) do
    lines
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Stream.map(fn {line, num} -> "#{file}:#{num}:#{line}" end)
    |> Enum.take(remaining)
  end
end

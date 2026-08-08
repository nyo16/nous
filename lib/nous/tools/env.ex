defmodule Nous.Tools.Env do
  @moduledoc """
  Scrubbed environment for tool subprocesses.

  Tools that spawn OS processes (`bash`, ripgrep in `file_grep`, command hooks)
  must not inherit the BEAM's environment: it routinely holds API keys, OAuth
  tokens, and vault credentials, and an LLM is one `printenv` away from leaking
  them. Shell-loader hooks (LD_PRELOAD, DYLD_INSERT_LIBRARIES) are dropped for
  the same reason.

  Every subprocess-spawning tool must build its argv through `scrub_argv/1` so
  the allowlist has exactly one definition.

  ## Why argv wrapping and not an `:env` spawn option

  Neither spawn API this library uses can *remove* an inherited variable, so
  passing `env: scrubbed()` was a no-op in both places it was used:

    * `NetRunner` has no `:env` option in any version. `run_impl/3` keeps only
      `:input`/`:timeout`/`:max_output_size`, the port spec passes no `env:`,
      and the NIF's `execvp` inherits `environ` unconditionally. The option was
      accepted by the keyword list and silently dropped.
    * `System.cmd/3`'s `:env` *merges into* the inherited environment rather
      than replacing it, so it can add and override but never scrub.

  `scrub_argv/1` therefore prefixes `env -i NAME=VALUE ...` to the argv.
  `env -i` starts the child from a genuinely empty environment and re-adds only
  the allowlist. This works identically for `NetRunner.run/2` and
  `System.cmd/3`, and — unlike re-implementing the spawn on `Port.open/2` — it
  preserves NetRunner's process-tree kill / zero-zombie guarantee, which is the
  documented reason it was chosen over `System.cmd`/`Port` in the first place.
  """

  # Whitelist of env vars safe to forward to subprocesses. Everything else
  # is dropped.
  @allowlist ~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM)

  @doc """
  The environment to pass to tool subprocesses: allowlisted variables that
  are currently set, as `{name, value}` tuples.

  This is the allowlist's single definition. Callers spawning a subprocess want
  `scrub_argv/1` instead — a bare `env:` option cannot unset anything.
  """
  @spec scrubbed() :: [{String.t(), String.t()}]
  def scrubbed do
    Enum.flat_map(@allowlist, fn name ->
      case System.get_env(name) do
        nil -> []
        value -> [{name, value}]
      end
    end)
  end

  @doc """
  Wraps `argv` so the spawned process starts from a scrubbed environment.

  Returns a new argv that runs `argv` under `env -i` with only the allowlisted
  variables re-established. Pass the result straight to `NetRunner.run/2` or
  split it for `System.cmd/3`; do not also pass an `:env` option.

      iex> ["env", "-i" | _] = Nous.Tools.Env.scrub_argv(["/bin/sh", "-c", "id"]) |> then(&[Path.basename(hd(&1)) | tl(&1)])

  Raises if no `env(1)` can be located, which fails the spawn closed rather
  than silently running with an unscrubbed environment.
  """
  @spec scrub_argv([String.t(), ...]) :: [String.t(), ...]
  def scrub_argv([_ | _] = argv) do
    assignments = Enum.map(scrubbed(), fn {name, value} -> name <> "=" <> value end)

    # No `--` terminator: `env` stops option parsing at the first operand, and
    # the `NAME=VALUE` assignments are already operands. A trailing `--` after
    # them is taken as the *utility name* by BSD env (verified: exit 127), so
    # adding one breaks the spawn instead of hardening it.
    [env_executable(), "-i" | assignments] ++ argv
  end

  # Resolved per call rather than memoized: a `stat` is free next to the fork
  # and exec that immediately follows it.
  defp env_executable do
    cond do
      File.regular?("/usr/bin/env") -> "/usr/bin/env"
      path = System.find_executable("env") -> path
      true -> raise "no env(1) executable found; cannot scrub the subprocess environment"
    end
  end
end

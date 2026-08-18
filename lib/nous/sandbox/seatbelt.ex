defmodule Nous.Sandbox.Seatbelt do
  @moduledoc """
  macOS confinement via `sandbox-exec` and an inline SBPL profile.

  `confine/2` wraps the caller's argv as

      /usr/bin/sandbox-exec -p <profile> -- <argv...>

  The executable is the absolute `/usr/bin/sandbox-exec`, never a bare name, so
  a poisoned `PATH` cannot substitute a different binary.

  ## The profile fences writes, not reads

  The profile opens with `(allow default)`. That is deliberate and it is the
  honest description of what this provider buys you: it denies every
  `file-write*` **performed by the confined process**, then re-allows the
  console `/dev` nodes and — under `:workspace_write` — every directory in
  `Nous.Sandbox.writable_roots/1`. Reads, network, and process spawning are
  **not** restricted. This is a write fence against a prompt-injected
  `rm -rf`, not a confidentiality boundary.

  `Nous.Sandbox.writable_roots/1` is the single owner of the writable set; this
  module never recomputes it, so the profile cannot drift from the rest of the
  system's idea of what is writable.

  ## Writes delegated to a running daemon are out of scope

  "Denied" above is exactly as narrow as it reads: the *confined process* may
  not perform the write. It does not mean no byte can land outside the writable
  set. `(allow default)` permits `mach-lookup`, so the confined process can ask
  an **already-running, unconfined** system daemon to write on its behalf, and
  seatbelt checks the *daemon's* credentials, not ours. Executed, under the real
  `:workspace_write` profile:

      sandbox-exec -p <profile> -- sh -c 'defaults write com.nous.esc pwned yes'

  exits 0, prints no denial signature, and leaves a 56-byte plist in `$HOME` —
  outside every entry of `writable_roots/1` — because `cfprefsd` performed the
  write. Anything reachable over XPC/launchd that writes on a client's behalf
  is the same class; where the Docker CLI is present, `docker run -v /:/host`
  is that class with a much larger blast radius (reasoned, not executed).
  Closing this would take a `deny mach-lookup (global-name ...)` list that
  grows with every macOS release, so the boundary is named rather than patched.

  Two things that look like this and are not: `osascript -e 'do shell script'`
  (the process it spawns inherits our sandbox) and a nested `sandbox-exec`
  (it cannot widen the profile — `sandbox_apply` fails with EPERM).

  ## The `/dev` write nodes are not a hole

  `base_profile/0` re-allows `/dev/null`, `/dev/stdout`, `/dev/stderr`,
  `/dev/tty` and `(subpath "/dev/fd")` in every mode, `:read_only` included.
  Those are the caller's own already-open descriptors: the confined process can
  write *through* an fd its unconfined parent opened, and it still cannot
  `open()` a new path outside the writable set (verified under the real
  `:workspace_write` profile — `exec 9> "$HOME/x"` is EPERM, and
  `/dev/fd/<non-numeric>` is ENOENT, so nothing can be created there). Without
  them `cmd > /dev/stdout`, `tee /dev/stderr`, `tee /dev/tty` and `> /dev/fd/1`
  all failed with "Operation not permitted" — ordinary idioms in model-authored
  shell — while all four succeed under `Nous.Sandbox.Bwrap`, whose `--dev /dev`
  tmpfs makes those nodes writable. The two providers now tell the caller the
  same story.

  ## On `sandbox-exec` being deprecated

  Apple has marked `sandbox-exec` deprecated and has shipped no replacement for
  sandboxing an arbitrary CLI process. It nevertheless still works on current
  macOS and is what OpenAI's Codex CLI, Anthropic's Claude Code, and Chrome all
  use for exactly this job. Depending on it is an accepted risk: if Apple
  removes it, `Nous.Sandbox.chain/0` gains a replacement provider and nothing
  above the seam changes. That is what the seam is for.
  """

  @behaviour Nous.Sandbox

  alias Nous.Sandbox
  alias Nous.Sandbox.{Confined, Policy, RunnerFailureRule}

  @executable "/usr/bin/sandbox-exec"

  # SBPL refuses a write with EPERM, so every tool that surfaces `strerror`
  # verbatim prints "Operation not permitted"; a few paths surface EACCES
  # ("Permission denied") instead. Past that, per-tool wording is unfixable:
  # `curl -o` prints "Failure writing output to destination", `tar -cf` prints
  # "Failed to open", `sqlite3` prints "unable to open database file", and
  # anything the model writes with `2>/dev/null` prints nothing at all. Around
  # 4 of 15 everyday commands produce a denial no signature list can see, so an
  # `:ok` verdict from `Nous.Sandbox.classify/3` means "no denial *observed*",
  # never "no denial occurred". Enforcement never depends on this list — only
  # the report back to the model does.
  @denial_signatures ["operation not permitted", "permission denied"]

  # `$0` carries the refused path so no path is ever spliced into shell source.
  # `!` inverts the second command: the probe *wants* that write to fail.
  @probe_script ~s(echo x > /dev/null && ! : > "$0")

  @doc """
  Wrap `argv` in `sandbox-exec` under an SBPL profile derived from `policy`.

  Pure — it builds strings and returns data. The profile denies all writes
  except the `/dev` console nodes and, under `:workspace_write`, the subpaths
  reported by `Nous.Sandbox.writable_roots/1`.
  """
  @impl Nous.Sandbox
  @spec confine([String.t()], Policy.t()) :: {:ok, Confined.t()}
  def confine([_ | _] = argv, %Policy{} = policy) do
    confined = %Confined{
      argv: [@executable, "-p", profile(policy), "--" | argv],
      mode: policy.mode,
      enforcement: :sandbox_exec,
      denial_signatures: @denial_signatures,
      runner_failure_rules: [%RunnerFailureRule{fatal_signatures: ["sandbox-exec: "]}]
    }

    {:ok, confined}
  end

  @doc """
  Check that `sandbox-exec` exists and that the kernel actually *enforces*
  `base_profile/0`.

  The probe runs the real `base_profile/0` — the same string `:read_only` gets,
  which grants no writable root at all — and asserts both directions in one
  spawn:

      /bin/sh -c 'echo x > /dev/null && ! : > "$0"' <path under System.tmp_dir!/0>

  Exit 0 therefore means "a permitted write succeeded **and** a write outside
  every writable root was actually refused". The previous probe ran
  `/usr/bin/true` under `(version 1) (allow default)`, a profile with no deny
  clause: it proved the binary exists and the parser was happy, never that one
  write is stopped.

  Exit 0 is `{:ok, :full}`; a missing binary, a nonzero exit, a timeout, or any
  other runner error is `{:error, :unusable}`. Seatbelt has no partial grade —
  either the kernel applies the profile or it does not — and anything ambiguous
  fails closed.
  """
  @impl Nous.Sandbox
  @spec probe(pos_integer()) :: {:ok, :full} | {:error, :unusable}
  def probe(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    if File.exists?(@executable) do
      probe_run(timeout_ms)
    else
      {:error, :unusable}
    end
  end

  # ---------------------------------------------------------------------------

  defp probe_run(timeout_ms) do
    refused = Path.join(System.tmp_dir!(), "nous-seatbelt-probe")
    argv = [@executable, "-p", base_profile(), "--", "/bin/sh", "-c", @probe_script, refused]

    # No `:stderr` option. The probe reads the exit status only, and `:redirect`
    # does not exist in net_runner 1.0 — passing it disables the `:consume`
    # drain and leaves the stderr pipe unread. The one line the shell prints
    # when the refused write fails is drained by the default.
    result = NetRunner.run(argv, timeout: timeout_ms)

    # Only reachable on a host where the write was *not* refused, in which case
    # the probe is about to report :unusable. Do not leave the file behind.
    File.rm(refused)

    case result do
      {_output, 0} -> {:ok, :full}
      _nonzero_or_error -> {:error, :unusable}
    end
  end

  defp profile(%Policy{mode: :workspace_write} = policy) do
    case Sandbox.writable_roots(policy) do
      [] -> base_profile()
      roots -> base_profile() <> " " <> writable_clause(roots)
    end
  end

  defp profile(%Policy{}), do: base_profile()

  # `(subpath "/dev/fd")` is the clause that does the work: `/dev/stdout`,
  # `/dev/stderr` and `/dev/fd/N` all resolve through it, and without it all
  # three stay EPERM even with the literals present (verified). The
  # `(literal "/dev/tty")` is independently load-bearing: without it a write to
  # the controlling terminal is EPERM (verified over a real pty). The
  # `/dev/stdout` and `/dev/stderr` literals are kept for the day Apple stops
  # symlinking them into `/dev/fd`.
  @dev_write_nodes ~s[(literal "/dev/null") (literal "/dev/stdout") ] <>
                     ~s[(literal "/dev/stderr") (literal "/dev/tty") (subpath "/dev/fd")]

  defp base_profile do
    "(version 1) (allow default) (deny file-write*) (allow file-write* #{@dev_write_nodes})"
  end

  defp writable_clause(roots) do
    "(allow file-write* " <>
      Enum.map_join(roots, " ", &"(subpath #{literal(&1)})") <> ")"
  end

  # SBPL strings are double-quoted with backslash escapes. A workspace root is
  # attacker-influencable often enough (it is just a path the caller passed)
  # that unescaped interpolation would be a profile-injection hole.
  defp literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end
end

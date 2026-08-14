defmodule Nous.Tools.Bash do
  @moduledoc """
  Shell command execution tool.

  Uses `NetRunner` for safe process execution with automatic timeout
  handling and output size limits. Zero zombie processes guaranteed.

  ## Security

  Commands run as the current OS user. Use `Nous.Permissions` to gate access to
  this tool in production.

  ### Environment

  The spawned shell gets **only** `Nous.Tools.Env.scrubbed/0`, applied via
  `Nous.Tools.Env.with_scrubbed_env/1` — an `/usr/bin/env -i` prefix on the
  argv — so it cannot `printenv` its way to `OPENAI_API_KEY` and friends.

  The argv detour is not stylistic. `NetRunner` has **no `:env` option**: it
  forwards unknown options to a port layer that ignores them and the shepherd
  `execvp`s, so the child inherits the BEAM's entire environment. This tool
  passed `env: Nous.Tools.Env.scrubbed()` for its whole existence and that
  option was silently discarded the entire time — `printenv` returned every key.
  Do not "restore" it.

  ### Sandbox

  Every command is wrapped by `Nous.Sandbox` before it is spawned. The
  effective policy comes from `Nous.Sandbox.Policy.resolve/2`, which reads (in
  order) the run context's `:sandbox` field, `ctx.deps[:workspace_root]`, and
  the application environment.

  The default is **`:danger_full_access`** — no confinement, with a one-time
  warning logged per VM. That default stays until the next release so upgrading
  cannot silently break a working deployment; it is not a recommendation. Opt
  in with either:

      # application-wide
      config :nous, :sandbox_mode, :workspace_write

      # or per agent / per run
      Nous.new("openai:gpt-4", sandbox: :workspace_write)
      Nous.run(agent, prompt, sandbox: :read_only)

  Under `:read_only` the OS refuses every write; under `:workspace_write` it
  permits writes only under `Nous.Sandbox.writable_roots/1` (the workspace
  root, `/tmp`, and the system temp dir). When no provider can confine the
  requested mode on this host, `execute/2` **refuses to spawn** and returns
  `{:error, _}` — running unconfined is never a silent fallback.

  What confinement does **not** give you, on either provider: reads are
  unrestricted, network egress is unrestricted, and only writes performed *by
  the confined process* are fenced — a write it delegates to an already-running
  system daemon over XPC (macOS `defaults write`, a container daemon) is
  performed with that daemon's credentials and is out of scope. `Nous.Sandbox`
  raises the cost of a prompt-injected `rm -rf`; it is not a boundary to hand an
  adversary.

  Sandbox denials come back as ordinary tool output with a
  `[sandbox: file access denied under <mode> mode]` marker appended, so the
  model can adapt. Treat the absence of that marker as "no denial observed",
  not as proof a write landed — see `Nous.Sandbox.classify/3`. A failure of the
  sandbox *runner itself* is reported as an error saying the command never ran,
  because "bwrap could not create a namespace" must never read as "confinement
  worked".

  ### stderr

  stderr is **merged into the returned output** via
  `Nous.Sandbox.merge_stderr/1`, which wraps the confined argv in
  `/bin/sh -c 'exec "$@" 2>&1'`.

  Do not "simplify" this into `NetRunner`'s `stderr: :redirect` option. That
  mode is documented but unimplemented in net_runner 1.0 — nothing branches on
  it — and passing it is *worse* than the default, because it also switches off
  the `:consume` drain and leaves a live stderr pipe with no reader, so a child
  writing more than a pipe buffer to stderr blocks forever. This tool therefore
  passes no `:stderr` option at all and keeps the default.

  Merging matters twice over: without it the model never sees a compiler error
  or a stack trace, and `Nous.Sandbox.classify/3` has nothing to classify.
  Because `exec` replaces the wrapper shell, fd 2 is redirected for the sandbox
  runner *itself*, so `sandbox-exec:` / `bwrap:` runner failures are captured
  too — a `2>&1` inside the inner command would miss exactly those.
  """

  use Nous.Tool.Schema

  alias Nous.Sandbox
  alias Nous.Sandbox.{Confined, Policy}

  require Logger

  @default_timeout 120_000
  @max_output_size 1_000_000

  # Absolute: a relative `sh` would resolve through PATH, which the scrubbed
  # env does not pin.
  @shell "/bin/sh"

  @cgroup_key {__MODULE__, :cgroup_v2_delegated?}
  @cgroup_root "/sys/fs/cgroup"

  tool "bash",
    description: "Execute a shell command and return its output.",
    category: :execute,
    requires_approval: true do
    param(:command, :string, required: true, doc: "The shell command to execute")

    param(:timeout, :integer, doc: "Timeout in milliseconds. Defaults to 120000 (2 minutes).")
  end

  @impl true
  def execute(ctx, %{"command" => command} = args) when is_binary(command) do
    # A NUL is invisible in an approval prompt, an audit log and a terminal, and
    # the port layer TRUNCATES argv at it rather than rejecting it — verified:
    # `Port.open(..., args: ["a" <> <<0>> <> "b"])` execs with just "a". So
    # `git push origin main\0 --dry-run` is approved as a dry run and executed as
    # a push. Reject it here, the way PathGuard rejects it in paths.
    if String.contains?(command, <<0>>) do
      {:error, "command contains a NUL byte; refusing to run"}
    else
      confine_and_run(ctx, command, Map.get(args, "timeout", @default_timeout))
    end
  end

  # ---------------------------------------------------------------------------

  defp confine_and_run(ctx, command, timeout) do
    policy = Policy.resolve(ctx)

    # `/bin/sh` absolute: a relative `sh` would resolve through PATH. `env -i`
    # inside the confinement, so the scrubbing applies to the model's shell while
    # the sandbox runner keeps a normal environment.
    argv = Nous.Tools.Env.with_scrubbed_env([@shell, "-c", command])

    case Sandbox.confine(argv, policy) do
      {:ok, confined} ->
        run_confined(confined, timeout)

      {:error, {:sandbox_unavailable, mode, detail}} ->
        {:error,
         "Refusing to run: no OS sandbox can enforce #{mode} mode on this host" <>
           detail_suffix(detail) <>
           ". The command was NOT executed. Install a sandbox provider " <>
           "(bubblewrap on Linux; sandbox-exec ships with macOS), or set " <>
           "`config :nous, :sandbox_mode, :danger_full_access` to run unconfined. " <>
           "If a provider IS installed and this host was merely busy when it was " <>
           "probed, call `Nous.Sandbox.reset_backend_cache/0` to re-probe."}

      {:error, reason} ->
        {:error,
         "Refusing to run: sandbox rejected the command (#{inspect(reason)}). " <>
           "The command was NOT executed."}
    end
  end

  # ---------------------------------------------------------------------------

  defp run_confined(%Confined{argv: [runner | _]} = confined, timeout) do
    # Erlang ports report a failed exec as an ordinary nonzero exit; there is no
    # `{code, path, syscall}` triple to tell "runner missing" from "command
    # failed". Take the weaker signal explicitly, before spawning, so a missing
    # /bin/sh or a vanished sandbox binary is named instead of surfacing as a
    # mystery exit code.
    case require_binary(runner) do
      :ok ->
        spawn_confined(confined, timeout)

      {:missing, reason} ->
        {:error,
         "Command never ran: #{runner_label(confined)} `#{runner}` is unusable " <>
           "(#{:file.format_error(reason)})."}
    end
  end

  defp spawn_confined(%Confined{} = confined, timeout) do
    # No `:env` option: NetRunner has none, and passing one was how this tool
    # spent its whole existence believing it had scrubbed the environment. The
    # scrubbing is in the argv (`Nous.Tools.Env.with_scrubbed_env/1`).
    # No `:stderr` option either — the merge wrapper does that job, and
    # `max_output_size` bounds the merged stream, which is what we want.
    opts =
      [
        timeout: timeout,
        max_output_size: @max_output_size
      ] ++ cgroup_opts()

    case NetRunner.run(Sandbox.merge_stderr(confined.argv), opts) do
      {:error, :timeout} ->
        {:error, "Command timed out after #{timeout}ms"}

      {:error, {:max_output_exceeded, partial}} ->
        # Classify the partial output too: a chatty command can also be a denied
        # one, and dropping the marker here would hide it.
        truncated = "#{partial}\n\n[Output truncated at #{@max_output_size} bytes]"
        annotate(confined, 1, partial, truncated)

      {:error, reason} ->
        {:error, "Command failed: #{inspect(reason)}"}

      {output, exit_status} when is_integer(exit_status) ->
        annotate(confined, exit_status, output, render(output, exit_status))
    end
  end

  # Annotate, never replace. `rendered` is what the caller would have received
  # with no sandbox in play; a verdict only ever appends to it.
  #
  # That matters because the classified stream is the command's own merged
  # output, so a verdict is forgeable by the command. Forgery cannot weaken
  # enforcement (nothing retries or widens a policy on a denial), but replacing
  # the output with an error message would let a forged verdict launder real side
  # effects out of the transcript. Appending cannot.
  defp annotate(%Confined{} = confined, exit_status, scanned, rendered) do
    case Sandbox.classify(confined, exit_status, scanned) do
      :ok ->
        {:ok, rendered}

      {:sandbox_denied, mode, _enforcement} ->
        {:ok, rendered <> "\n[sandbox: file access denied under #{mode} mode]"}

      {:runner_failed, enforcement, line} ->
        Logger.warning("Sandbox runner (#{enforcement}) reported a failure: #{line}")

        {:ok,
         rendered <>
           "\n[sandbox: the #{enforcement} runner reported an error, so the command " <>
           "may never have run: #{String.trim(line)}. Treat this output as " <>
           "untrustworthy and do not assume the command was prevented.]"}
    end
  end

  defp render(output, 0), do: output
  defp render(output, exit_status), do: "Exit code: #{exit_status}\n#{output}"

  defp runner_label(%Confined{enforcement: :none}), do: "the shell"
  defp runner_label(%Confined{enforcement: enforcement}), do: "the #{enforcement} sandbox runner"

  defp detail_suffix(nil), do: ""
  defp detail_suffix(detail) when is_binary(detail), do: " (#{detail})"

  # A name without a separator is a PATH lookup, not a path; File.stat would
  # resolve it against the cwd and report a spurious :enoent.
  defp require_binary(path) do
    if String.contains?(path, "/") do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} -> :ok
        {:ok, %File.Stat{type: _other}} -> {:missing, :eftype}
        {:error, reason} -> {:missing, reason}
      end
    else
      if System.find_executable(path), do: :ok, else: {:missing, :enoent}
    end
  end

  # Free cgroup-v2 resource confinement, Linux only: net_runner's shepherd
  # creates the cgroup, migrates the child into it, then `cgroup.kill`s the whole
  # tree and rmdirs on exit, so a command that forks into the background cannot
  # outlive the tool call. macOS has no equivalent — there, confinement is the
  # write fence and nothing else, and a backgrounded child survives the call
  # (still fenced, but alive).
  #
  # The name is deliberately FLAT. The shepherd creates the cgroup with a single
  # non-recursive `mkdir("/sys/fs/cgroup/<path>")` (shepherd.c), so a nested
  # `nous/bash/<n>` could never be created: it would fail with ENOENT, the
  # shepherd would log and carry on, and the whole feature would be a silent
  # no-op. One level, or nothing.
  #
  # Gated on cgroup v2 actually being delegated to us, so we do not attempt a
  # mkdir that cannot work and do not spray shepherd error logs on hosts without
  # delegation. The path is relative and `..`-free; the shepherd re-validates.
  defp cgroup_opts do
    if cgroup_v2_delegated?() do
      [cgroup_path: "nous_bash_#{System.unique_integer([:positive, :monotonic])}"]
    else
      []
    end
  end

  defp cgroup_v2_delegated? do
    case :persistent_term.get(@cgroup_key, nil) do
      nil ->
        delegated? = detect_cgroup_v2_delegation()
        :persistent_term.put(@cgroup_key, delegated?)
        delegated?

      cached ->
        cached
    end
  end

  defp detect_cgroup_v2_delegation do
    :os.type() == {:unix, :linux} and
      File.exists?(Path.join(@cgroup_root, "cgroup.controllers")) and
      writable_cgroup_root?()
  end

  # Mode bits lie about cgroupfs delegation (which depends on the delegation
  # ownership the container runtime or systemd handed us), so ask the only
  # question that matters: can we actually create a cgroup here? One mkdir per
  # VM, memoized, and removed immediately.
  defp writable_cgroup_root? do
    probe = Path.join(@cgroup_root, "nous-probe-#{System.unique_integer([:positive])}")

    case File.mkdir(probe) do
      :ok ->
        _ = File.rmdir(probe)
        true

      {:error, _reason} ->
        false
    end
  end
end

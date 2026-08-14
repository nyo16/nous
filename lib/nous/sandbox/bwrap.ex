defmodule Nous.Sandbox.Bwrap do
  @moduledoc """
  Linux confinement via `bwrap` (bubblewrap).

  `confine/2` wraps the caller's argv as

      bwrap <base args> <mode args> -- <argv...>

  which is the invocation shape bubblewrap documents:
  `bwrap [OPTIONS...] [--] COMMAND [ARGS...]`.

  ## The fence is on writes, not reads

  The base binds `/` read-only over itself (`--ro-bind / /`), so the child can
  read the entire host filesystem exactly as it could unconfined. What it
  cannot do is write outside the mounts re-bound read-write below. Like
  `Nous.Sandbox.Seatbelt`, this is a write fence, not a confidentiality
  boundary.

  ## Grades

  `grade/0` is `:full` on a host that can mount `/dev` and `/proc` and unshare
  the pid namespace:

      --ro-bind / / --dev /dev --proc /proc --unshare-pid --die-with-parent

  Some hosts — unprivileged containers, hardened kernels — run `bwrap` but
  cannot create those mounts. `probe/1` retries there with the reduced base and
  memoizes `:partial`:

      --ro-bind / / --die-with-parent

  `--unshare-pid` is deliberately absent from the reduced base: a host that is
  not allowed to mount `/proc` is unlikely to be allowed to unshare pid either,
  so keeping the two together lets one probe failure cover both.

  ## Which namespaces are shared with the host

  Two namespaces are ours: **mount** (implicit — it is what every `--ro-bind`,
  `--bind` and `--tmpfs` operates in) and, at `:full`, **pid**. Bubblewrap also
  creates a **user** namespace when it is not setuid, purely to obtain the
  privilege to build the mount namespace; it maps our uid to itself, so it
  isolates nothing on its own. **net, ipc, uts and cgroup are shared with the
  host**: the child sees the host's interfaces and reaches the network, shares
  abstract unix sockets and SysV IPC, and reports the host's hostname.

  Sharing the network namespace is the deliberate one. This provider is a write
  fence, and so is `Nous.Sandbox.Seatbelt`, which does not restrict network
  either; unsharing net here would make the same `curl` succeed on macOS and
  fail on Linux, which is the divergence the seam exists to prevent. `ipc` and
  `uts` stay shared because nothing above the seam depends on them and every
  extra `--unshare-*` is one more way for a restricted host to fail the probe
  and drop to `:partial`.

  ## Why `--proc` requires `--unshare-pid`

  `--proc /proc` mounts a *fresh* procfs, but the pid namespace it describes is
  still the host's unless pid is unshared. The child then sees every same-uid
  process on the box — including the BEAM that spawned it — and resolution of
  `/proc/<pid>/root/...` happens in *that process's* mount namespace, which is
  the host's, where `/` is read-write. So
  `echo x > /proc/<beam-pid>/root/$HOME/.bashrc` writes straight through the
  fence: `ptrace_may_access` gates it on uid only, and the implicit user
  namespace maps our uid to itself. `/proc/self/root` is *not* an escape (it is
  our own namespace); another PID's is. Mounting `--proc` without
  `--unshare-pid` is a documented bubblewrap footgun, not a subtlety of this
  module.

  `--unshare-pid` also repairs `--die-with-parent`, which sets
  `PR_SET_PDEATHSIG` on **bwrap itself** rather than on the tree: with no
  pid-namespace init, a backgrounded grandchild outlives both bwrap's death and
  a `SIGKILL` of the BEAM. As namespace init, bwrap takes the whole tree with
  it.

  ## Honest divergence from `Nous.Sandbox.writable_roots/1`

  Under `:workspace_write` this appends `--tmpfs /tmp --bind <root> <root>`.
  That is deliberately *not* the same set as `Nous.Sandbox.writable_roots/1`:

    * `/tmp` is a **fresh, empty tmpfs**, not the host's `/tmp`. Writes there
      are writable and ephemeral, and the host's temporary files are invisible
      to the child.
    * `System.tmp_dir!/0` is **not** separately bound. Where it differs from
      `/tmp` (it usually does not on Linux), it stays read-only.

  Seatbelt's profile enumerates the canonical roots directly; bwrap's mount
  namespace gives a stronger, differently shaped guarantee. Neither is wrong,
  but the argv here cannot be compared element-wise against `writable_roots/1`.

  ## Discovery lives in `probe/1`

  `confine/2` must stay pure, so it never calls `System.find_executable/1`.
  `probe/1` resolves the absolute path and the grade once and memoizes both in
  `:persistent_term`; `executable/0` and `grade/0` are the pure reads, with
  defaults (`"/usr/bin/bwrap"`, `:full`) for a caller that confines before
  anything probed — which is exactly what pinning `:sandbox_backend` in config
  does, since that path never calls `probe/1`. See `executable/0` for why that
  default must be an absolute path.
  """

  @behaviour Nous.Sandbox

  alias Nous.Sandbox.{Confined, Policy, RunnerFailureRule}

  @base_full [
    "--ro-bind",
    "/",
    "/",
    "--dev",
    "/dev",
    "--proc",
    "/proc",
    "--unshare-pid",
    "--die-with-parent"
  ]
  @base_partial ["--ro-bind", "/", "/", "--die-with-parent"]

  @default_executable "/usr/bin/bwrap"

  # `--ro-bind` refuses writes with EROFS, so "read-only file system" is the
  # common case, but it is not the only one: a write into a directory owned by
  # another uid is EACCES ("Permission denied") and a metadata write such as
  # chown or a link into a read-only tree is EPERM ("Operation not permitted").
  # Per-tool wording stays unfixable either way — `curl -o` prints "Failure
  # writing output to destination", `tar -cf` prints "Failed to open", and
  # anything the model writes with `2>/dev/null` prints nothing at all. So an
  # `:ok` verdict from `Nous.Sandbox.classify/3` means "no denial *observed*",
  # never "no denial occurred". Enforcement never depends on this list — only
  # the report back to the model does.
  @denial_signatures [
    "read-only file system",
    "permission denied",
    "operation not permitted"
  ]

  # Both grades run the same two-directional probe. `/dev/null` is writable even
  # at `:partial`, where `--ro-bind / /` covers it and there is no fresh `--dev`:
  # the kernel's read-only check in `inode_permission/2` returns EROFS for
  # regular files, directories and symlinks only, never for device nodes. The
  # refused target is a regular file under `System.tmp_dir!/0`, which no *base*
  # arg re-binds read-write (`--tmpfs /tmp` is a `:workspace_write` mode arg),
  # so it must fail. `$0` carries that path so nothing is spliced into shell
  # source, and `!` inverts: the probe *wants* the write refused. Anything
  # ambiguous fails the probe, which walks full -> partial -> :unusable, i.e.
  # closed.
  @probe_script ~s(echo x > /dev/null && ! : > "$0")

  @executable_key {__MODULE__, :executable}
  @grade_key {__MODULE__, :grade}

  @typedoc """
  How much fencing this host's `bwrap` can actually apply. See the moduledoc.
  """
  @type grade :: :full | :partial

  @doc """
  Wrap `argv` in `bwrap` under `policy`. Pure — reads memoized discovery
  results, builds a list, and returns.
  """
  @impl Nous.Sandbox
  @spec confine([String.t()], Policy.t()) :: {:ok, Confined.t()}
  def confine([_ | _] = argv, %Policy{} = policy) do
    confined = %Confined{
      argv: [executable() | base_args(grade()) ++ mode_args(policy) ++ ["--"] ++ argv],
      mode: policy.mode,
      enforcement: :bwrap,
      denial_signatures: @denial_signatures,
      runner_failure_rules: [%RunnerFailureRule{fatal_signatures: ["bwrap: "]}]
    }

    {:ok, confined}
  end

  @doc """
  Locate `bwrap`, determine its grade, and memoize both.

  Each candidate base is probed with `@probe_script`, which asserts that a
  permitted write to `/dev/null` succeeds **and** that a write to a path under
  `System.tmp_dir!/0` — which no base arg re-binds read-write — is refused. Exit
  0 therefore means the mounts were actually applied, not merely that `bwrap`
  accepted the flags.

  Returns `{:ok, :full}` when the full base works, `{:ok, :partial}` when only
  the reduced base does, and `{:error, :unusable}` when `bwrap` is absent or
  neither base enforces.
  """
  @impl Nous.Sandbox
  @spec probe(pos_integer()) :: {:ok, grade()} | {:error, :unusable}
  def probe(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case System.find_executable("bwrap") do
      nil ->
        {:error, :unusable}

      path ->
        :persistent_term.put(@executable_key, path)
        probe_grade(path, timeout_ms)
    end
  end

  @doc """
  The absolute path to `bwrap` discovered by `probe/1`, or `"/usr/bin/bwrap"`
  before any probe has run. Pure `:persistent_term` read.

  The default is absolute on purpose. A bare `"bwrap"` is resolved by the port
  through the `PATH` the child inherits, and that `PATH` routinely carries
  user-writable entries (`~/.asdf/shims`, `~/.bun/bin`, `~/.cargo/bin`,
  `~/.local/bin` — 30-odd on a developer machine). A security runner that a
  poisoned `PATH` can substitute is not a security runner, which is the same
  reason `Nous.Sandbox.Seatbelt` pins `/usr/bin/sandbox-exec`. This default is
  reachable in practice: pinning `:sandbox_backend` in config skips `probe/1`,
  so nothing ever memoizes a resolved path. `probe/1` still memoizes whatever
  `System.find_executable/1` finds, which is what a distro-packaged or Nix-store
  `bwrap` needs.
  """
  @spec executable() :: String.t()
  def executable, do: :persistent_term.get(@executable_key, @default_executable)

  @doc """
  The grade discovered by `probe/1`, or `:full` before any probe has run. Pure
  `:persistent_term` read.
  """
  @spec grade() :: grade()
  def grade, do: :persistent_term.get(@grade_key, :full)

  # ---------------------------------------------------------------------------

  defp probe_grade(path, timeout_ms) do
    cond do
      probe_base?(path, @base_full, timeout_ms) -> memoize_grade(:full)
      probe_base?(path, @base_partial, timeout_ms) -> memoize_grade(:partial)
      true -> {:error, :unusable}
    end
  end

  defp probe_base?(path, base, timeout_ms) do
    refused = Path.join(System.tmp_dir!(), "nous-bwrap-probe")
    argv = [path | base ++ ["--", "/bin/sh", "-c", @probe_script, refused]]

    # No `:stderr` option: the probe reads the exit status only, and `:redirect`
    # does not exist in net_runner 1.0 — passing it disables the `:consume`
    # drain and leaves the stderr pipe unread.
    result = NetRunner.run(argv, timeout: timeout_ms)

    # Only reachable on a host where the write was *not* refused, in which case
    # this base is about to be rejected. Do not leave the file behind.
    File.rm(refused)

    case result do
      {_output, 0} -> true
      _nonzero_or_error -> false
    end
  end

  defp memoize_grade(grade) do
    :persistent_term.put(@grade_key, grade)
    {:ok, grade}
  end

  defp base_args(:full), do: @base_full
  defp base_args(:partial), do: @base_partial

  defp mode_args(%Policy{mode: :workspace_write, workspace_root: root}) do
    ["--tmpfs", "/tmp", "--bind", root, root]
  end

  defp mode_args(%Policy{}), do: []
end

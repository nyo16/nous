defmodule Nous.Sandbox do
  @moduledoc """
  OS-level confinement for subprocesses spawned by tools.

  `Nous.Tools.Bash` hands the model a shell. `Nous.Permissions` decides *whether*
  it may run and `Nous.Tools.PathGuard` fences the *file tools*, but neither
  constrains what the shell itself touches once it is running. This module is
  that constraint: a provider behaviour that **wraps argv** so the OS enforces
  the policy.

  ## The shape

      {:ok, confined} = Nous.Sandbox.confine(["/bin/sh", "-c", cmd], policy)
      {output, status} = NetRunner.run(Nous.Sandbox.merge_stderr(confined.argv))
      Nous.Sandbox.classify(confined, status, output)

  Three properties are load-bearing:

    * **`confine/2` builds argv and nothing else.** It never spawns, never
      mutates, and performs no filesystem access once the canonical temp roots
      are memoized (warmed at application start; see `writable_roots/1`). Path
      canonicalisation happens when the policy is built, not per call. Only
      `c:probe/1` (backend selection) and the caller's own spawn touch the OS.
    * **Fail closed.** With no usable provider, `confine/2` returns
      `{:error, {:sandbox_unavailable, mode, detail}}`. Silently running the
      command unconfined is never legal. `:danger_full_access` is the *explicit*
      way to ask for no confinement.
    * **Runner failure is classified before denial.** "bwrap could not create a
      namespace, so the command never ran" must not read as "confinement
      worked". See `Nous.Sandbox.RunnerFailureRule`.

  ## Providers

    * `Nous.Sandbox.Seatbelt` — macOS, `sandbox-exec` + an SBPL profile
    * `Nous.Sandbox.Bwrap` — Linux, `bwrap` from bubblewrap
    * `Nous.Sandbox.Unavailable` — the fail-closed default when nothing else
      probes clean (including all of Windows, where `chain/0` is `[]`)

  `backend/0` probes `chain/0` once and memoizes the winner in
  `:persistent_term`. Set `config :nous, :sandbox_backend, Module` to pin one
  and skip probing entirely.

  ## Scope: subprocesses only

  This confines processes Nous spawns. It is deliberately *not* the isolation
  story for in-process evaluation — that is bounded by its own runtime guest.
  The two are siblings, not nested.

  `Nous.Tools.FileGrep` is a documented exemption: it spawns `ripgrep`, but
  neither provider restricts reads (Seatbelt's profile is `(allow default)
  (deny file-write*)`, bwrap binds `/` read-only), so confining a process that
  only ever reads adds no enforcement — while fail-closed refusal would take a
  working search tool away on hosts with no provider. See the note in that
  module.

  ## What this is not

  It is not a kernel boundary you may lean on for multi-tenant isolation, and
  the TOCTOU window between `Nous.Tools.PathGuard.resolve_real/1` and the
  child's own syscalls is exactly as open as it is in `PathGuard` today. It
  raises the cost of a prompt-injected `rm -rf`; it does not make the host safe
  to hand to an adversary.
  """

  alias Nous.Sandbox.{Confined, Policy, RunnerFailureRule, Unavailable}

  @typedoc """
  A provider module implementing this behaviour.
  """
  @type backend :: module()

  @typedoc """
  Return values — **not** raises. `Nous.Errors` exceptions are for the agent
  loop; confinement failures are ordinary data a tool decides what to do with.

    * `{:sandbox_unavailable, mode, detail}` — no provider can confine this
      mode on this host. The caller MUST refuse to spawn.
    * `{:runner_failed, enforcement, fatal_line}` — the sandbox runner errored
       out; the command never ran.
    * `{:sandbox_denied, mode, enforcement}` — the command ran and the OS denied
      it something.

  Every variant has a producer and a consumer. Speculative vocabulary is
  deliberately absent: an unused tuple in a security type reads as an enforcement
  point that exists, and the next caller will assume it does.
  """
  @type error ::
          {:sandbox_unavailable, Policy.mode(), String.t() | nil}
          | {:runner_failed, Confined.enforcement(), String.t()}
          | {:sandbox_denied, Policy.mode(), Confined.enforcement()}

  @doc """
  Wrap `argv` so the OS enforces `policy`. Pure: MUST NOT spawn.
  """
  @callback confine(argv :: [String.t()], policy :: Policy.t()) ::
              {:ok, Confined.t()} | {:error, error()}

  @doc """
  Check whether this provider actually works on this host, within
  `timeout_ms`. This is the one callback that may spawn.

  `{:ok, :full}` means the provider enforces everything it claims;
  `{:ok, :partial}` means it runs but with reduced fencing (a bwrap that cannot
  mount `/proc`, say); `{:error, :unusable}` means do not select it.
  """
  @callback probe(timeout_ms :: pos_integer()) ::
              {:ok, :full | :partial} | {:error, :unusable}

  @probe_timeout 2_000
  @backend_key {__MODULE__, :backend}

  @doc """
  Confine `argv` under `policy` using the selected backend.

  `:danger_full_access` never reaches a provider: it returns the argv untouched
  with `enforcement: :none` and no signatures, so `classify/3` on the result can
  only ever answer `:ok`.
  """
  @spec confine([String.t()], Policy.t()) :: {:ok, Confined.t()} | {:error, error()}
  def confine(argv, policy)

  def confine([_ | _] = argv, %Policy{mode: :danger_full_access} = policy) do
    {:ok, %Confined{argv: argv, mode: policy.mode, enforcement: :none}}
  end

  def confine([_ | _] = argv, %Policy{} = policy) do
    backend().confine(argv, policy)
  end

  @doc """
  Interpret a finished confined process. Pure.

  Returns `:ok`, `{:runner_failed, enforcement, line}`, or
  `{:sandbox_denied, mode, enforcement}`.

  Order is deliberate: runner failure first, denial second — "the runner broke,
  so the command never ran" must never read as "confinement worked". Three
  constraints keep that ordering from misfiring, all of them learned from real
  output:

    * **Exit 0 is never anything but `:ok`.** A denial fails the command, so a
      successful command that merely *mentions* a signature — `cat`ting a log,
      grepping this very file — is not a denial.
    * **A fatal signature only counts at the start of a line.** A runner
      prefixes its own name (`bwrap: `, `sandbox-exec: `); a quoted mention
      inside a message does not sit at column 0.
    * **A line that matches both a fatal and a denial signature is a denial.**
      `sandbox-exec: sandbox_apply: Operation not permitted` — macOS refusing a
      nested-sandbox escape — is definitionally both, and it is a denial: the
      escape was *prevented*.

  Within a runner failure rule, `informational_lines` are dropped by exact
  case-insensitive full-line equality before `fatal_signatures` are matched, and
  the **original** line is returned so the caller reports what the runner
  actually printed.

  Signatures come from the `Nous.Sandbox.Confined` itself, so one backend's
  wording can never classify another backend's output.

  ## `:ok` means "no denial observed"

  It does not mean "no denial occurred". The scan is over process output, and
  denial wording is per-tool: `curl` says `Failure writing output to
  destination`, `tar` says `Failed to open`, `sqlite3` says `unable to open
  database file`, and anything the model writes with `2>/dev/null` says nothing
  at all. Enforcement still held in every one of those cases — only the report
  is silent. Treat the verdict as advisory, never as proof a write landed.

  `output` is what the caller captured. With `NetRunner` that means spawning
  through `merge_stderr/1`; its `stderr: :redirect` option does not exist.
  """
  @spec classify(Confined.t(), integer(), String.t()) :: :ok | error()
  def classify(%Confined{} = confined, exit_status, output)
      when is_integer(exit_status) and is_binary(output) do
    case runner_failure(confined, exit_status, output) do
      {:ok, fatal_line} ->
        {:runner_failed, confined.enforcement, fatal_line}

      :none ->
        if denied?(confined, exit_status, output) do
          {:sandbox_denied, confined.mode, confined.enforcement}
        else
          :ok
        end
    end
  end

  @doc """
  Wrap `argv` so the child's stderr is merged into its stdout.

  `NetRunner` documents a `stderr: :redirect` option that does not exist: no
  code branches on it, and passing it also disables the `:consume` drain, so a
  child writing more than a pipe buffer to stderr would block forever. Without
  a merge, `NetRunner.run/2` returns stdout only and every denial signature is
  invisible — `classify/3` would answer `:ok` for a command the kernel refused.

  The wrapper is a fixed literal script with the real argv passed as positional
  arguments, so it adds no injection surface. `exec` replaces the outer shell,
  which means fd2→fd1 is inherited by the *sandbox runner itself* — that is what
  makes `{:runner_failed, _, _}` observable, since the runner prints its own
  errors to its own stderr, not the confined command's.

  ## Examples

      iex> Nous.Sandbox.merge_stderr(["echo", "hi"])
      ["/bin/sh", "-c", "exec \\"$@\\" 2>&1", "sh", "echo", "hi"]

  """
  @spec merge_stderr([String.t()]) :: [String.t()]
  def merge_stderr([_ | _] = argv) do
    ["/bin/sh", "-c", ~s(exec "$@" 2>&1), "sh" | argv]
  end

  @doc """
  The canonical directories a confined process may write to.

  `[]` under `:read_only`. Otherwise three sources — the workspace root,
  `/tmp`, and `System.tmp_dir!/0` — canonicalised through
  `Nous.Tools.PathGuard.resolve_real/1` and deduplicated, so hosts where they
  coincide (`/tmp` on Linux) return fewer than three entries.

  No `$HOME`, no git directory, no session state directory. This is the **one**
  owner of that set: the Seatbelt profile builder and any future filesystem
  fence both call it, so they cannot drift apart.

  The workspace root arrives already canonical from
  `Nous.Sandbox.Policy.new/1`, and the two temp roots are canonicalised once per
  VM (see `warm/0`), which is what keeps `confine/2` off the filesystem.
  """
  @spec writable_roots(Policy.t()) :: [Path.t()]
  def writable_roots(%Policy{mode: :read_only}), do: []

  def writable_roots(%Policy{workspace_root: root}) do
    Enum.uniq([root | temp_roots()])
  end

  @doc """
  Canonicalise and memoize the temp roots.

  Called from the application's own `start` callback so the one filesystem read
  this module needs happens at boot rather than inside `confine/2`. Idempotent.
  """
  @spec warm() :: :ok
  def warm do
    _roots = temp_roots()
    :ok
  end

  @doc """
  Candidate providers for this platform, best first. `[]` where no provider
  exists (Windows), which resolves to `Nous.Sandbox.Unavailable`.
  """
  @spec chain() :: [backend()]
  def chain do
    case :os.type() do
      {:unix, :darwin} -> [Nous.Sandbox.Seatbelt]
      {:unix, :linux} -> [Nous.Sandbox.Bwrap]
      _other -> []
    end
  end

  @doc """
  The selected provider.

  Resolution order: the `:sandbox_backend` application setting, then the memoized
  probe result, then a fresh probe of `chain/0`. Falls back to
  `Nous.Sandbox.Unavailable`.

  A **pinned** provider is never probed — pinning is the operator asserting the
  host is capable, which also means the provider's `c:probe/1` side effects
  (`Nous.Sandbox.Bwrap` discovers and memoizes its absolute path there) do not
  happen. Pin for tests and for hosts you control; otherwise let the probe run.
  """
  @spec backend() :: backend()
  def backend do
    case Application.get_env(:nous, :sandbox_backend) do
      nil -> memoized_backend()
      pinned when is_atom(pinned) -> pinned
    end
  end

  @doc """
  Drop the memoized probe result. For tests and for hosts that install a
  provider while the VM is running.
  """
  @spec reset_backend_cache() :: :ok
  def reset_backend_cache do
    :persistent_term.erase(@backend_key)
    :ok
  end

  # ---------------------------------------------------------------------------

  defp memoized_backend do
    case :persistent_term.get(@backend_key, nil) do
      nil -> select_backend(chain())
      cached -> cached
    end
  end

  # A platform with no provider at all (Windows) is a permanent fact, so cache it.
  # A platform that HAS a candidate which failed to probe is not: the probe has a
  # 2s budget and a loaded host can miss it, and memoizing that would fail closed
  # for the rest of the VM's life — every later `Bash` call refusing on a host
  # where the sandbox actually works. Only a positive selection is cached.
  defp select_backend([]) do
    :persistent_term.put(@backend_key, Unavailable)
    Unavailable
  end

  defp select_backend(candidates) do
    case probe_chain(candidates) do
      Unavailable ->
        Unavailable

      selected ->
        :persistent_term.put(@backend_key, selected)
        selected
    end
  end

  defp probe_chain([]), do: Unavailable

  defp probe_chain([candidate | rest]) do
    case candidate.probe(@probe_timeout) do
      {:ok, _full_or_partial} -> candidate
      {:error, :unusable} -> probe_chain(rest)
    end
  end

  defp runner_failure(_confined, 0, _output), do: :none

  defp runner_failure(%Confined{} = confined, exit_status, output) do
    lines = String.split(output, "\n")

    Enum.find_value(confined.runner_failure_rules, :none, fn rule ->
      if candidate_exit?(rule, exit_status) do
        lines
        |> drop_informational(rule.informational_lines)
        |> find_fatal(rule.fatal_signatures, confined.denial_signatures)
      end
    end)
  end

  defp candidate_exit?(%RunnerFailureRule{allowed_exit_codes: nil}, _exit_status), do: true

  defp candidate_exit?(%RunnerFailureRule{allowed_exit_codes: allowed}, exit_status),
    do: exit_status not in allowed

  defp drop_informational(lines, []), do: lines

  defp drop_informational(lines, informational) do
    noise = MapSet.new(informational, &normalize/1)
    Enum.reject(lines, &MapSet.member?(noise, normalize(&1)))
  end

  defp find_fatal(_lines, [], _denial_signatures), do: nil

  defp find_fatal(lines, signatures, denial_signatures) do
    Enum.find_value(lines, fn line ->
      if fatal_line?(line, signatures) and not contains_any?(line, denial_signatures) do
        {:ok, line}
      end
    end)
  end

  # Anchored, not a substring search: a runner PREFIXES its own diagnostics with
  # its name, so `bwrap: ` at column 0 is the runner talking, while the same text
  # quoted inside a message — a failing test suite, a `grep` hit, a `cat` of this
  # file — is the command talking about the runner. Trimmed because output is
  # commonly indented or CR-terminated.
  defp fatal_line?(line, signatures) do
    normalized = normalize(line)
    Enum.any?(signatures, &String.starts_with?(normalized, String.downcase(&1)))
  end

  # A line that is BOTH is a denial. `sandbox-exec: sandbox_apply: Operation not
  # permitted` is macOS refusing a nested-sandbox escape: the runner did fail to
  # start, but reporting that as "broken sandbox, effects were not prevented"
  # inverts the truth — the escape was prevented.
  defp contains_any?(line, signatures) do
    downcased = String.downcase(line)
    Enum.any?(signatures, &String.contains?(downcased, String.downcase(&1)))
  end

  # Exit 0 is never a denial: a denied operation fails the command. Without this
  # gate, `echo 'the log said Operation not permitted'` classified as a denial,
  # which is prompt-injectable — a hostile file could make every successful
  # command look blocked and train the reader to ignore the marker.
  defp denied?(_confined, 0, _output), do: false
  defp denied?(%Confined{denial_signatures: []}, _exit_status, _output), do: false

  defp denied?(%Confined{denial_signatures: signatures}, _exit_status, output) do
    contains_any?(output, signatures)
  end

  defp normalize(line), do: line |> String.trim() |> String.downcase()

  @temp_roots_key {__MODULE__, :temp_roots}

  defp temp_roots do
    case :persistent_term.get(@temp_roots_key, nil) do
      nil ->
        roots = Enum.uniq([Policy.canonical("/tmp"), Policy.canonical(System.tmp_dir!())])
        :persistent_term.put(@temp_roots_key, roots)
        roots

      cached ->
        cached
    end
  end
end

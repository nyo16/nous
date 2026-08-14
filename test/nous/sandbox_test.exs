defmodule Nous.SandboxTest do
  # async: false — these tests pin the `:nous, :sandbox_backend` application env
  # and the `:persistent_term` discovery state that `Nous.Sandbox` and
  # `Nous.Sandbox.Bwrap` memoize. All of that is VM-global.
  use ExUnit.Case, async: false

  alias Nous.Sandbox
  alias Nous.Sandbox.{Bwrap, Confined, Policy, RunnerFailureRule, Seatbelt, Unavailable}
  alias Nous.Tools.PathGuard

  doctest Nous.Sandbox

  @seatbelt_executable "/usr/bin/sandbox-exec"

  # One line, tokens separated by exactly one space, asserted as a literal on
  # purpose: to the kernel a stray space or a reordered clause is a different
  # profile, so "close enough" is not a passing grade.
  @base_profile ~S[(version 1) (allow default) (deny file-write*) (allow file-write* (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr") (literal "/dev/tty") (subpath "/dev/fd"))]

  # Documented discovery keys. `Bwrap.confine/2` stays pure by reading what
  # `Bwrap.probe/1` memoized here, which is also how a macOS host asserts
  # bwrap's argv for both grades without a Linux kernel.
  @bwrap_executable_key {Nous.Sandbox.Bwrap, :executable}
  @bwrap_grade_key {Nous.Sandbox.Bwrap, :grade}

  # Same rationale for `Nous.Sandbox`'s own memo: reading the key is the only
  # way the memoization test can fail, since a `backend/0` with no memo at all
  # re-probes and returns the very same module.
  @backend_key {Nous.Sandbox, :backend}

  # `--unshare-pid` is load-bearing, not decoration: `--proc` without it leaves
  # the HOST pid namespace, so `/proc/<other-pid>/root/...` resolves in that
  # process's mount namespace where `/` is still read-write — a write escape.
  @bwrap_base_full [
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

  @bwrap_base_partial ["--ro-bind", "/", "/", "--die-with-parent"]

  # Everything a provider could reach for to start a process, stat a file, or
  # talk to the network. `confine/2` promises none of it.
  @impure_mfas [
    {:erlang, :open_port, 2},
    {Port, :_, :_},
    {:os, :_, :_},
    {System, :_, :_},
    {File, :_, :_},
    # The raw Erlang layer under `File`/`Path`: without these a provider that
    # called `:file.read_file_info/1` or `:filelib.is_dir/1` directly was
    # invisible to the trace.
    {:file, :_, :_},
    {:filelib, :_, :_},
    {NetRunner, :_, :_}
  ]

  defmodule ExplodingBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    @impl Nous.Sandbox
    def confine(_argv, _policy), do: raise("a provider was consulted and must not have been")

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: raise("a pinned backend must never be probed")
  end

  defmodule MarkerBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    @impl Nous.Sandbox
    def confine(argv, policy) do
      {:ok, %Confined{argv: ["MARKER" | argv], mode: policy.mode, enforcement: :none}}
    end

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: raise("a pinned backend must never be probed")
  end

  setup do
    original_backend = Application.fetch_env(:nous, :sandbox_backend)

    # `Nous.Application` calls warm/0 at boot. Doing the same here means the one
    # filesystem read `writable_roots/1` needs has already happened, so the
    # purity assertions measure `confine/2` in the state it actually runs in.
    Sandbox.warm()
    Sandbox.reset_backend_cache()

    workspace = Path.join(System.tmp_dir!(), "sandbox_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)

      case original_backend do
        {:ok, backend} -> Application.put_env(:nous, :sandbox_backend, backend)
        :error -> Application.delete_env(:nous, :sandbox_backend)
      end

      :persistent_term.erase(@bwrap_executable_key)
      :persistent_term.erase(@bwrap_grade_key)
      Sandbox.reset_backend_cache()
    end)

    {:ok, workspace: workspace, canonical_workspace: canonical!(workspace)}
  end

  describe "confine/2 purity" do
    test "no provider spawns, stats, or opens a port while building argv", %{
      workspace: workspace
    } do
      argv = ["/bin/sh", "-c", "echo hi"]

      # Policy construction is where the filesystem is legitimately touched:
      # `Policy.new/1` canonicalises the workspace root precisely so that
      # `confine/2` does not have to. Build the policies first, then trace only
      # the argv builders.
      policies = Enum.map(Policy.modes(), &Policy.new(mode: &1, workspace_root: workspace))

      calls =
        impure_calls_during(fn ->
          for %Policy{mode: mode} = policy <- policies do
            if mode == :danger_full_access do
              # This mode never reaches a provider; the dispatcher answers it.
              assert {:ok, %Confined{}} = Sandbox.confine(argv, policy)
            else
              assert {:ok, %Confined{}} = Seatbelt.confine(argv, policy)
              assert {:ok, %Confined{}} = Bwrap.confine(argv, policy)
            end
          end
        end)

      assert calls == []
    end

    test "Seatbelt.confine/2 does not require the workspace root to exist" do
      root = "/nonexistent-nous-workspace-#{System.unique_integer([:positive])}"
      refute File.exists?(root)

      policy = Policy.new(mode: :workspace_write, workspace_root: root)
      assert policy.workspace_root == root

      assert {:ok, confined} = Seatbelt.confine(["/bin/echo", "hi"], policy)
      assert profile(confined) =~ ~s[(subpath "#{root}")]
    end

    test "Bwrap.confine/2 never probes the binary: a pinned path that cannot exist is used as is" do
      :persistent_term.put(@bwrap_executable_key, "/nonexistent/bin/bwrap")
      assert Bwrap.executable() == "/nonexistent/bin/bwrap"

      assert {:ok, confined} = Bwrap.confine(["/bin/echo", "hi"], Policy.new(:read_only))
      assert hd(confined.argv) == "/nonexistent/bin/bwrap"
    end

    test "confine/2 is deterministic", %{workspace: workspace} do
      policy = Policy.new(mode: :workspace_write, workspace_root: workspace)
      argv = ["/bin/sh", "-c", "echo hi"]

      assert Seatbelt.confine(argv, policy) == Seatbelt.confine(argv, policy)
      assert Bwrap.confine(argv, policy) == Bwrap.confine(argv, policy)
    end

    test "the purity harness itself detects an impure function" do
      # The guard on the guard. `:erlang.trace_pattern/3` arms only an ALREADY
      # code-loaded module and silently matches 0 functions otherwise, which
      # turns `assert calls == []` into a tautology — the state this file
      # shipped in. Nothing but a positive control stops it rotting again.
      calls = impure_calls_during(fn -> File.stat("/") end)

      assert {File, :stat, ["/"]} in calls
      # And the raw Erlang layer underneath is traced too, so a provider that
      # bypasses the `File` wrapper is still seen.
      assert Enum.any?(calls, &match?({:file, _fun, _args}, &1))
    end

    test "the purity harness sees a spawn that happens in another process" do
      # This is the exact mutation the purity assertion exists to catch: a
      # `confine/2` that shells out. `NetRunner` opens its port from a process
      # it spawns, so without `:set_on_spawn` both `{NetRunner, :run, 2}` and
      # `{:erlang, :open_port, 2}` stay silent and the assertion passes.
      calls = impure_calls_during(fn -> NetRunner.run(["/bin/echo", "hi"], timeout: 10_000) end)

      assert Enum.any?(calls, &match?({NetRunner, :run, _args}, &1))
      assert Enum.any?(calls, &match?({:erlang, :open_port, _args}, &1))
    end
  end

  describe "Seatbelt.confine/2 argv" do
    test "read_only wraps argv with the base profile and no writable subpath", %{
      workspace: workspace
    } do
      policy = Policy.new(mode: :read_only, workspace_root: workspace)
      assert Sandbox.writable_roots(policy) == []

      assert {:ok, confined} = Seatbelt.confine(["/bin/sh", "-c", "echo hi"], policy)

      assert confined.argv == [
               @seatbelt_executable,
               "-p",
               @base_profile,
               "--",
               "/bin/sh",
               "-c",
               "echo hi"
             ]

      assert confined.mode == :read_only
      assert confined.enforcement == :sandbox_exec
      # EPERM is the common case, but a few paths surface EACCES instead.
      assert confined.denial_signatures == ["operation not permitted", "permission denied"]

      assert [
               %RunnerFailureRule{
                 fatal_signatures: ["sandbox-exec: "],
                 allowed_exit_codes: nil,
                 informational_lines: []
               }
             ] = confined.runner_failure_rules
    end

    test "workspace_write appends exactly one clause listing every writable root in order", %{
      workspace: workspace
    } do
      policy = Policy.new(mode: :workspace_write, workspace_root: workspace)
      roots = Sandbox.writable_roots(policy)

      clause = "(allow file-write* " <> Enum.map_join(roots, " ", &~s[(subpath "#{&1}")]) <> ")"

      assert {:ok, confined} = Seatbelt.confine(["/bin/sh", "-c", "true"], policy)

      assert confined.argv == [
               @seatbelt_executable,
               "-p",
               @base_profile <> " " <> clause,
               "--",
               "/bin/sh",
               "-c",
               "true"
             ]

      # One added clause, not one clause per root: the base profile's /dev/null
      # literal plus exactly one more.
      assert length(String.split(profile(confined), "(allow file-write*")) == 3
    end

    test "the profile is a single line of single-space-separated tokens", %{workspace: workspace} do
      for mode <- [:read_only, :workspace_write] do
        {:ok, confined} =
          Seatbelt.confine(
            ["/bin/sh", "-c", "true"],
            Policy.new(mode: mode, workspace_root: workspace)
          )

        profile = profile(confined)
        refute profile =~ "\n"
        refute profile =~ ~r/\s\s/
      end
    end

    test "SBPL string literals escape backslashes and quotes, backslash first" do
      root = ~S(/nonexistent-nous "quoted"\dir)
      policy = Policy.new(mode: :workspace_write, workspace_root: root)

      assert {:ok, confined} = Seatbelt.confine(["/bin/echo", "hi"], policy)

      # A `"` becomes `\"` and a `\` becomes `\\`. Order matters: escaping the
      # quote first would yield `\\"` and re-open the string to injection.
      assert profile(confined) =~ ~S[(subpath "/nonexistent-nous \"quoted\"\\dir")]
      refute profile(confined) =~ ~S[(subpath "/nonexistent-nous "quoted"\dir")]
    end

    test "a provider handed :danger_full_access still fences: no writable subpath clause" do
      # The dispatcher short circuits this mode, so a provider only sees it when
      # a caller bypassed `Nous.Sandbox.confine/2`. Fail closed, never wider.
      policy = Policy.new(mode: :danger_full_access, workspace_root: "/srv/ws")

      assert {:ok, confined} = Seatbelt.confine(["/bin/echo", "hi"], policy)
      assert profile(confined) == @base_profile
      refute profile(confined) =~ "/srv/ws"
      # The base profile carries exactly one `(allow file-write*` clause — the
      # /dev nodes, which include `(subpath "/dev/fd")`, so a bare "subpath"
      # refute would now be about the wrong thing. What must not appear is a
      # SECOND clause: that is the one that grants the workspace.
      assert length(String.split(profile(confined), "(allow file-write*")) == 2
    end
  end

  describe "Bwrap.confine/2 argv" do
    setup do
      :persistent_term.put(@bwrap_grade_key, :full)
      :ok
    end

    test "read_only binds / read-only with no writable bind pair" do
      policy = Policy.new(mode: :read_only, workspace_root: "/srv/ws")

      assert {:ok, confined} = Bwrap.confine(["/bin/sh", "-c", "echo hi"], policy)

      assert confined.argv ==
               [Bwrap.executable() | @bwrap_base_full] ++ ["--", "/bin/sh", "-c", "echo hi"]

      assert confined.mode == :read_only
      assert confined.enforcement == :bwrap

      assert confined.denial_signatures == [
               "read-only file system",
               "permission denied",
               "operation not permitted"
             ]

      assert [
               %RunnerFailureRule{
                 fatal_signatures: ["bwrap: "],
                 allowed_exit_codes: nil,
                 informational_lines: []
               }
             ] = confined.runner_failure_rules
    end

    test "workspace_write adds an ephemeral /tmp and binds the workspace root" do
      policy = Policy.new(mode: :workspace_write, workspace_root: "/srv/ws")

      assert {:ok, confined} = Bwrap.confine(["/bin/sh", "-c", "echo hi"], policy)

      assert confined.argv ==
               [Bwrap.executable() | @bwrap_base_full] ++
                 ["--tmpfs", "/tmp", "--bind", "/srv/ws", "/srv/ws"] ++
                 ["--", "/bin/sh", "-c", "echo hi"]
    end

    test "grade :partial drops --dev, --proc and --unshare-pid together" do
      :persistent_term.put(@bwrap_grade_key, :partial)
      assert Bwrap.grade() == :partial

      policy = Policy.new(mode: :workspace_write, workspace_root: "/srv/ws")
      assert {:ok, confined} = Bwrap.confine(["/bin/sh", "-c", "echo hi"], policy)

      assert confined.argv ==
               [Bwrap.executable() | @bwrap_base_partial] ++
                 ["--tmpfs", "/tmp", "--bind", "/srv/ws", "/srv/ws"] ++
                 ["--", "/bin/sh", "-c", "echo hi"]

      refute "--dev" in confined.argv
      refute "--proc" in confined.argv
      # Pinned in both directions, because the unsafe intermediate state is
      # `--proc` kept while `--unshare-pid` is dropped: that leaves the host pid
      # namespace mounted, and `/proc/<other-pid>/root/...` is then a write
      # escape. The `:full` ladder asserts the flag present; this asserts the
      # reduced grade drops the pair as a unit.
      refute "--unshare-pid" in confined.argv
      assert "--unshare-pid" in @bwrap_base_full
    end

    test "the caller's argv is separated by -- and left untouched" do
      argv = ["/bin/sh", "-c", "echo --die-with-parent"]
      policy = Policy.new(mode: :read_only, workspace_root: "/srv/ws")

      assert {:ok, confined} = Bwrap.confine(argv, policy)

      # bwrap documents `bwrap [OPTIONS...] [--] COMMAND [ARGS...]`: everything
      # after the first `--` is the command, so an argument that looks like an
      # option cannot be reinterpreted as one.
      assert [_runner | rest] = confined.argv
      assert Enum.drop_while(rest, &(&1 != "--")) == ["--" | argv]
    end
  end

  describe "confine/2 with :danger_full_access" do
    test "returns the argv untouched and never consults a provider" do
      Application.put_env(:nous, :sandbox_backend, ExplodingBackend)
      argv = ["/bin/sh", "-c", "echo hi"]

      assert {:ok, confined} = Sandbox.confine(argv, Policy.new(:danger_full_access))

      assert confined.argv == argv
      assert confined.mode == :danger_full_access
      assert confined.enforcement == :none
      assert confined.denial_signatures == []
      assert confined.runner_failure_rules == []
    end

    test "the resulting Confined can only ever classify :ok" do
      assert {:ok, confined} = Sandbox.confine(["/bin/true"], Policy.new(:danger_full_access))

      output = """
      bwrap: Creating new namespace failed
      sandbox-exec: could not parse profile
      cannot create /etc/x: Read-only file system
      /etc/x: Operation not permitted
      """

      assert Sandbox.classify(confined, 1, output) == :ok
      assert Sandbox.classify(confined, 255, output) == :ok
    end
  end

  describe "classify/3" do
    test "a runner failure wins over a denial in the same output" do
      confined = bwrap_confined()
      # The fatal line must carry no denial wording of its own: a line matching
      # BOTH is a denial by design (next test), so a fatal line saying
      # "Operation not permitted" would be exercising the opposite rule.
      fatal = "bwrap: Creating new namespace failed"
      denial = "/bin/sh: 1: cannot create /etc/x: Read-only file system"

      assert {:runner_failed, :bwrap, ^fatal} =
               Sandbox.classify(confined, 1, fatal <> "\n" <> denial)

      # Control: with the runner's own line gone the very same output is a
      # denial, so the assertion above cannot pass for the wrong reason.
      assert Sandbox.classify(confined, 1, denial) == {:sandbox_denied, :read_only, :bwrap}

      # And the combined output genuinely satisfies BOTH tests, so the answer is
      # decided by the order alone: inverting it flips the first assertion.
      combined = fatal <> "\n" <> denial

      assert Sandbox.classify(%{confined | runner_failure_rules: []}, 1, combined) ==
               {:sandbox_denied, :read_only, :bwrap}

      assert {:runner_failed, :bwrap, ^fatal} =
               Sandbox.classify(%{confined | denial_signatures: []}, 1, combined)
    end

    test "a single line matching both a fatal and a denial signature is a denial" do
      # Pinned independently of the sandbox-exec case below, because the rule is
      # generic: a runner that refused to start BECAUSE the kernel denied it did
      # prevent the effect, so "the runner broke, the command may have run"
      # inverts the truth.
      confined = bwrap_confined()
      both = "bwrap: setting up uid map: Permission denied"

      # The line really is both, so the assertion is about precedence.
      assert String.starts_with?(String.downcase(both), "bwrap: ")
      assert Enum.any?(confined.denial_signatures, &String.contains?(String.downcase(both), &1))

      assert Sandbox.classify(confined, 1, both) == {:sandbox_denied, :read_only, :bwrap}

      # Control: the same column-0 prefix with the denial wording removed IS a
      # runner failure.
      only_fatal = "bwrap: setting up uid map: no free uid available"

      assert {:runner_failed, :bwrap, ^only_fatal} = Sandbox.classify(confined, 1, only_fatal)

      # And with the denial vocabulary emptied the overlapping line falls back to
      # a runner failure, so precedence — not matchability — decides it.
      assert {:runner_failed, :bwrap, ^both} =
               Sandbox.classify(%{confined | denial_signatures: []}, 1, both)
    end

    test "an informational line is dropped before fatal matching, signature and all" do
      noise = "bwrap: Note: locking is not available on this filesystem"
      confined = with_rule(bwrap_confined(), informational_lines: [noise])

      assert Sandbox.classify(confined, 1, noise) == :ok
      # Case-insensitive equality, so a runner that shouts is still just chatty.
      assert Sandbox.classify(confined, 1, String.upcase(noise)) == :ok

      # Control: the same line is fatal without the informational entry.
      assert {:runner_failed, :bwrap, ^noise} = Sandbox.classify(bwrap_confined(), 1, noise)

      # Full-line equality, not substring: a line that merely starts with the
      # informational text is still a runner failure.
      longer = noise <> " and then it died"
      assert {:runner_failed, :bwrap, ^longer} = Sandbox.classify(confined, 1, longer)
    end

    test "the original, non-downcased line is returned" do
      fatal = "BWRAP: Creating New Namespace Failed"

      assert {:runner_failed, :bwrap, ^fatal} =
               Sandbox.classify(bwrap_confined(), 1, "starting\n" <> fatal <> "\ngiving up")
    end

    test "one backend's fatal signatures never classify another backend's output" do
      # A fatal signature is the runner's own name, so it is genuinely
      # backend-specific. Denial signatures are NOT: they are `strerror`
      # strings, and both providers list "permission denied" and "operation not
      # permitted" because EACCES/EPERM are what either kernel returns. That
      # overlap is asserted at the bottom rather than wished away.
      seatbelt_fatal = "sandbox-exec: could not parse profile"
      bwrap_fatal = "bwrap: Creating new namespace failed"
      bwrap_only_denial = "/bin/sh: 1: cannot create /etc/x: Read-only file system"

      assert Sandbox.classify(bwrap_confined(), 1, seatbelt_fatal) == :ok
      assert Sandbox.classify(seatbelt_confined(), 1, bwrap_fatal) == :ok

      # `read-only file system` is bwrap's alone — SBPL refuses with EPERM, so
      # seatbelt never lists EROFS wording.
      refute "read-only file system" in seatbelt_confined().denial_signatures
      assert Sandbox.classify(seatbelt_confined(), 1, bwrap_only_denial) == :ok

      # Controls: each backend does recognise its own wording, so the results
      # above are about provenance, not about unmatchable strings.
      assert {:runner_failed, :bwrap, _} = Sandbox.classify(bwrap_confined(), 1, bwrap_fatal)

      assert {:runner_failed, :sandbox_exec, _} =
               Sandbox.classify(seatbelt_confined(), 1, seatbelt_fatal)

      assert Sandbox.classify(bwrap_confined(), 1, bwrap_only_denial) ==
               {:sandbox_denied, :read_only, :bwrap}

      # The shared strerror wording IS shared, deliberately: a seatbelt-worded
      # denial classifies under bwrap too. Pinned so that narrowing either list
      # is a decision someone makes, not a side effect someone discovers.
      shared_denial = "/bin/sh: /etc/x: Operation not permitted"

      assert Sandbox.classify(bwrap_confined(), 1, shared_denial) ==
               {:sandbox_denied, :read_only, :bwrap}

      assert Sandbox.classify(seatbelt_confined(), 1, shared_denial) ==
               {:sandbox_denied, :read_only, :sandbox_exec}
    end

    test "a real sandbox-exec denial is a denial, not a runner failure" do
      # Captured VERBATIM from macOS refusing a nested sandbox — the single line
      # `sandbox-exec` prints at exit 71 when `sandbox_apply` is itself denied.
      # It satisfies the fatal signature ("sandbox-exec: " at column 0) and the
      # denial signature ("operation not permitted") simultaneously, and it is a
      # DENIAL: the escape was PREVENTED. Reporting it as "the sandbox is broken
      # and did not prevent this" inverted the truth, and every string in this
      # describe block used to be invented, which is exactly how that shipped.
      output = "sandbox-exec: sandbox_apply: Operation not permitted\n"

      assert Sandbox.classify(seatbelt_confined(), 71, output) ==
               {:sandbox_denied, :read_only, :sandbox_exec}

      refute match?({:runner_failed, _, _}, Sandbox.classify(seatbelt_confined(), 71, output))
    end

    test "a fatal signature only counts at the start of a trimmed line" do
      # `classify/3` scans merged stdout+stderr, so every byte it reads is
      # model-controlled. Anchoring is what stops a `cat` of a log, a `grep`
      # hit, or this very file from making the tool tell the model "the command
      # never ran".
      mid_line = "error: the log mentions sandbox-exec: here"

      assert Sandbox.classify(seatbelt_confined(), 1, mid_line) == :ok

      # Control: the same wording at column 0 IS a runner failure, so the :ok
      # above is bought by the anchor and not by an unmatchable string.
      column_zero = "sandbox-exec: nothing is wrong, I just printed this"

      assert {:runner_failed, :sandbox_exec, ^column_zero} =
               Sandbox.classify(seatbelt_confined(), 1, column_zero)

      # Leading whitespace is trimmed before anchoring, because runners and
      # shells indent their diagnostics.
      assert {:runner_failed, :sandbox_exec, "   sandbox-exec: boom"} =
               Sandbox.classify(seatbelt_confined(), 1, "   sandbox-exec: boom")

      # A confined command CAN still forge a column-0 line, and that is accepted
      # by design: the kernel never reads this string, so forgery cannot weaken
      # enforcement — it is self-harm, costing the model its own output's
      # credibility. It is neutralised one layer up, where `Nous.Tools.Bash`
      # ANNOTATES the output with the verdict instead of replacing it, so a
      # forged "runner failed" can no longer launder real side effects out of
      # the transcript.
      assert {:runner_failed, :sandbox_exec, "sandbox-exec: forged"} =
               Sandbox.classify(seatbelt_confined(), 1, "ran fine\nsandbox-exec: forged")
    end

    test "exit 0 is :ok even for output that is verbatim a denial or a fatal" do
      # A denial FAILS the command, so at exit 0 nothing was denied. Without the
      # gate, `cat`ting any file that contains "Operation not permitted" — or
      # grepping this test file — reported a denial. That is prompt-injectable:
      # a hostile file could make every successful command look blocked and
      # train the reader to ignore the marker entirely.
      denial = "the log said: /etc/x: Operation not permitted"
      fatal = "sandbox-exec: sandbox_apply: Operation not permitted"

      assert Sandbox.classify(seatbelt_confined(), 0, denial) == :ok
      assert Sandbox.classify(seatbelt_confined(), 0, fatal) == :ok

      # Controls: the very same bytes at a nonzero exit are classified, so the
      # results above are decided by the status alone.
      assert Sandbox.classify(seatbelt_confined(), 1, denial) ==
               {:sandbox_denied, :read_only, :sandbox_exec}

      assert Sandbox.classify(seatbelt_confined(), 1, fatal) ==
               {:sandbox_denied, :read_only, :sandbox_exec}
    end

    test "allowed_exit_codes: nil makes every nonzero exit a runner-failure candidate" do
      confined = bwrap_confined()
      assert [%RunnerFailureRule{allowed_exit_codes: nil}] = confined.runner_failure_rules

      for status <- [1, 2, 126, 127, 255] do
        assert {:runner_failed, :bwrap, "bwrap: boom"} =
                 Sandbox.classify(confined, status, "bwrap: boom")
      end
    end

    test "allowed_exit_codes exempts the listed statuses and only those" do
      confined = with_rule(bwrap_confined(), allowed_exit_codes: [1])

      assert Sandbox.classify(confined, 1, "bwrap: boom") == :ok

      assert {:runner_failed, :bwrap, "bwrap: boom"} =
               Sandbox.classify(confined, 2, "bwrap: boom")

      # An exempt status is still classified for denial.
      assert Sandbox.classify(confined, 1, "cannot create x: Read-only file system") ==
               {:sandbox_denied, :read_only, :bwrap}
    end

    test "exit status 0 is never a runner failure" do
      assert Sandbox.classify(bwrap_confined(), 0, "bwrap: boom") == :ok
      assert Sandbox.classify(seatbelt_confined(), 0, "sandbox-exec: boom") == :ok
    end

    test "clean output is :ok and empty signature lists can never match" do
      assert Sandbox.classify(bwrap_confined(), 0, "") == :ok
      assert Sandbox.classify(bwrap_confined(), 1, "just a failing command\n") == :ok

      bare = %Confined{argv: ["/bin/true"], mode: :read_only, enforcement: :bwrap}
      assert Sandbox.classify(bare, 1, "bwrap: boom\nRead-only file system") == :ok
    end
  end

  describe "merge_stderr/1" do
    test "wraps argv in a fixed literal script and leaves the inner argv untouched" do
      argv = [@seatbelt_executable, "-p", @base_profile, "--", "/bin/sh", "-c", "echo hi"]

      assert Sandbox.merge_stderr(argv) == ["/bin/sh", "-c", ~S(exec "$@" 2>&1), "sh" | argv]
    end

    test "the script never interpolates argv, so it adds no injection surface" do
      hostile = ["/bin/echo", "$(touch /tmp/nous_pwned)", "; rm -rf /", "'"]

      assert ["/bin/sh", "-c", script, "sh" | inner] = Sandbox.merge_stderr(hostile)
      assert script == ~S(exec "$@" 2>&1)
      assert inner == hostile
    end

    test "the wrapper really merges stderr into stdout and preserves the exit status" do
      argv = ["/bin/sh", "-c", "echo to-stdout; echo to-stderr >&2; exit 7"]

      assert {output, 7} = NetRunner.run(Sandbox.merge_stderr(argv), timeout: 10_000)
      assert output =~ "to-stdout"
      assert output =~ "to-stderr"
    end
  end

  describe "writable_roots/1" do
    test "read_only has no writable roots at all", %{workspace: workspace} do
      assert Sandbox.writable_roots(Policy.new(mode: :read_only, workspace_root: workspace)) == []
    end

    test "otherwise it is the canonical dedup of workspace_root, /tmp and System.tmp_dir!()", %{
      workspace: workspace,
      canonical_workspace: canonical_workspace
    } do
      policy = Policy.new(mode: :workspace_write, workspace_root: workspace)
      roots = Sandbox.writable_roots(policy)

      assert roots == Enum.uniq(Enum.map([workspace, "/tmp", System.tmp_dir!()], &canonical!/1))
      assert canonical_workspace in roots
      assert roots == Enum.uniq(roots)
      # Three sources, deduplicated — on Linux /tmp and System.tmp_dir!() are the
      # same directory and collapse, so the count is a ceiling, not a constant.
      assert length(roots) <= 3
      assert roots != []

      # Every entry is already canonical: canonicalising again is a fixed point.
      for root <- roots, do: assert(PathGuard.resolve_real(root) == {:ok, root})
    end

    test "a symlinked workspace root is canonicalised to its target", %{workspace: workspace} do
      real = Path.join(workspace, "real_root")
      File.mkdir_p!(real)
      link = Path.join(workspace, "link_root")
      File.ln_s!(real, link)

      policy = Policy.new(mode: :workspace_write, workspace_root: link)
      roots = Sandbox.writable_roots(policy)

      assert canonical!(real) in roots
      refute link in roots
      refute canonical!(real) == link
    end
  end

  describe "backend selection" do
    test "chain/0 offers this platform's provider, best first" do
      case :os.type() do
        {:unix, :darwin} -> assert Sandbox.chain() == [Seatbelt]
        {:unix, :linux} -> assert Sandbox.chain() == [Bwrap]
        _other -> assert Sandbox.chain() == []
      end
    end

    test "a pinned backend is dispatched to and never probed" do
      Application.put_env(:nous, :sandbox_backend, MarkerBackend)

      assert Sandbox.backend() == MarkerBackend

      assert {:ok, confined} =
               Sandbox.confine(["/bin/sh", "-c", "echo hi"], Policy.new(:read_only))

      assert confined.argv == ["MARKER", "/bin/sh", "-c", "echo hi"]
    end

    test "with no usable provider, confine/2 refuses instead of passing argv through" do
      Application.put_env(:nous, :sandbox_backend, Unavailable)

      for mode <- [:read_only, :workspace_write] do
        assert Sandbox.confine(["/bin/sh", "-c", "rm -rf /"], Policy.new(mode)) ==
                 {:error, {:sandbox_unavailable, mode, nil}}
      end
    end

    test "a positive probe result is memoized and reset_backend_cache/0 clears it" do
      Application.delete_env(:nous, :sandbox_backend)
      Sandbox.reset_backend_cache()
      assert :persistent_term.get(@backend_key, :absent) == :absent

      selected = Sandbox.backend()
      assert selected in (Sandbox.chain() ++ [Unavailable])

      # Reading the memo directly is the only way this test can fail: a
      # `backend/0` with no memo at all re-probes and answers the same module,
      # so `Sandbox.backend() == selected` holds either way.
      #
      # Negative caching is deliberately absent. A candidate that failed to
      # probe is NOT cached, because the probe has a 2s budget and a loaded host
      # can miss it — memoizing that would fail closed for the VM's whole life,
      # every later `Bash` call refusing on a host where the sandbox works. An
      # empty `chain/0` (Windows) IS cached, being a permanent platform fact.
      # `chain/0` is not injectable, so only the half this host reaches runs;
      # the invariant below is written so either half is a real assertion.
      expected = if selected == Unavailable and Sandbox.chain() != [], do: :absent, else: selected

      assert :persistent_term.get(@backend_key, :absent) == expected

      assert Sandbox.reset_backend_cache() == :ok
      assert :persistent_term.get(@backend_key, :absent) == :absent
      assert Sandbox.backend() == selected
    end

    test "a pinned backend is never memoized, because it was never probed" do
      Sandbox.reset_backend_cache()
      Application.put_env(:nous, :sandbox_backend, MarkerBackend)

      assert Sandbox.backend() == MarkerBackend

      # Nothing was probed, so nothing may be remembered: caching a pin would
      # leave `MarkerBackend` selected for the rest of the VM after the operator
      # removed the setting.
      assert :persistent_term.get(@backend_key, :absent) == :absent
    end
  end

  # ---------------------------------------------------------------------------

  defp profile(%Confined{argv: [_runner, "-p", profile | _]}), do: profile

  defp canonical!(path) do
    assert {:ok, real} = PathGuard.resolve_real(path)
    real
  end

  defp bwrap_confined do
    {:ok, confined} =
      Bwrap.confine(["/bin/true"], Policy.new(mode: :read_only, workspace_root: "/srv/ws"))

    confined
  end

  defp seatbelt_confined do
    {:ok, confined} =
      Seatbelt.confine(["/bin/true"], Policy.new(mode: :read_only, workspace_root: "/srv/ws"))

    confined
  end

  defp with_rule(%Confined{runner_failure_rules: [rule]} = confined, overrides) do
    %{confined | runner_failure_rules: [struct!(rule, overrides)]}
  end

  # "confine/2 MUST NOT spawn" needs an observation, not an argument: trace every
  # call that could start a process or touch the filesystem and assert none
  # happens. The tracer must be a separate process — a process that traces itself
  # receives no trace messages.
  defp impure_calls_during(fun) do
    # `:erlang.trace_pattern/3` arms only functions of an ALREADY code-loaded
    # module: on one that is not loaded it matches 0 functions and the pattern
    # is not retained when the module later loads. After
    # `Application.ensure_all_started(:nous)` neither `NetRunner` nor `Port` is
    # loaded, which is how this harness spent its life passing vacuously — a
    # `confine/2` that shelled out produced an empty trace.
    for {mod, _fun, _arity} <- @impure_mfas, do: Code.ensure_loaded!(mod)

    test = self()
    tracer = spawn(fn -> collect_traces(test, []) end)

    # `:set_on_spawn`, because `NetRunner` opens its port from a process it
    # spawns: without it `{:erlang, :open_port, 2}` is armed and still never
    # fires, so both safety nets miss the same mutation.
    assert :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}]) == 1

    for mfa <- @impure_mfas do
      assert :erlang.trace_pattern(mfa, true, [:global]) > 0,
             "trace pattern #{inspect(mfa)} matched 0 functions, so every assertion " <>
               "resting on this trace would be vacuous"
    end

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call, :set_on_spawn])
      for mfa <- @impure_mfas, do: :erlang.trace_pattern(mfa, false, [:global])
    end

    send(tracer, {:drain, self()})
    assert_receive {:traced_calls, calls}, 10_000
    calls
  end

  defp collect_traces(test, acc) do
    receive do
      {:trace, _pid, :call, mfa} -> collect_traces(test, [mfa | acc])
      {:drain, from} -> send(from, {:traced_calls, Enum.reverse(acc)})
    end
  end
end

defmodule Nous.Tools.BashSandboxTest do
  # async: false — every test here sets `:nous, :sandbox_mode` and
  # `:nous, :sandbox_backend`, and the backend probe result is memoized in
  # `:persistent_term`. All of it is VM-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.{RunContext, Sandbox, Tool, ToolExecutor}
  alias Nous.Sandbox.{Confined, Policy, RunnerFailureRule, Unavailable}
  alias Nous.Tools.Bash

  # The stub backends below carry `Nous.Sandbox.Seatbelt`'s real
  # denial-signature list, verbatim: SBPL refuses with EPERM ("Operation not
  # permitted") and a few paths with EACCES ("Permission denied"). A stub that
  # carried only the first would keep passing after the provider dropped the
  # second — see "the stubs carry the provider's real denial signatures".

  # A denial as the OS actually reports one: on stderr, with a nonzero exit. The
  # tool merges stderr into stdout before classifying, so this stays hermetic —
  # no sandbox binary, no platform assumptions, just /bin/sh.
  defmodule DenyingBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    @impl Nous.Sandbox
    def confine(_argv, policy) do
      {:ok,
       %Confined{
         argv: ["/bin/sh", "-c", "echo 'Operation not permitted' >&2; exit 1"],
         mode: policy.mode,
         enforcement: :sandbox_exec,
         denial_signatures: ["operation not permitted", "permission denied"]
       }}
    end

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: {:error, :unusable}
  end

  # The runner itself breaking, printing BOTH its own fatal signature and a
  # denial signature. Classification must pick the runner failure.
  #
  # The script also produces REAL output and a REAL side effect (a file in the
  # workspace root the policy carries), because the contract under test is that
  # a verdict annotates and never replaces: see the "annotate, never replace"
  # test below.
  defmodule BrokenRunnerBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    # Derived from the policy so the test can predict it without the backend
    # needing any state.
    def side_effect_path(workspace_root), do: Path.join(workspace_root, "broken_runner_wrote")

    @impl Nous.Sandbox
    def confine(_argv, policy) do
      marker = side_effect_path(policy.workspace_root)

      script =
        "touch '#{marker}'; echo 'the command really wrote #{marker}'; " <>
          "echo 'sandbox-exec: could not parse profile' >&2; " <>
          "echo 'Operation not permitted' >&2; exit 1"

      {:ok,
       %Confined{
         argv: ["/bin/sh", "-c", script],
         mode: policy.mode,
         enforcement: :sandbox_exec,
         denial_signatures: ["operation not permitted", "permission denied"],
         runner_failure_rules: [%RunnerFailureRule{fatal_signatures: ["sandbox-exec: "]}]
       }}
    end

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: {:error, :unusable}
  end

  # Spawns the argv the tool built, unchanged, while still reporting
  # `enforcement: :sandbox_exec`. That is the only hermetic way to observe what
  # `Nous.Tools.Bash` actually hands a provider — a real provider would rewrite
  # argv, and `:danger_full_access` skips providers entirely.
  defmodule ArgvCapturingBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    @key {__MODULE__, :observer}

    def observe(pid), do: :persistent_term.put(@key, pid)
    def forget, do: :persistent_term.erase(@key)

    @impl Nous.Sandbox
    def confine(argv, policy) do
      case :persistent_term.get(@key, nil) do
        nil -> :ok
        pid -> send(pid, {:confined_argv, argv})
      end

      {:ok,
       %Confined{
         argv: argv,
         mode: policy.mode,
         enforcement: :sandbox_exec,
         denial_signatures: ["operation not permitted", "permission denied"]
       }}
    end

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: {:error, :unusable}
  end

  # Denied AND over the output ceiling. `NetRunner` reports that as
  # `{:error, {:max_output_exceeded, partial}}` rather than a normal
  # `{output, status}` pair, which used to skip classification entirely — so a
  # chatty denied command lost its marker.
  defmodule ChattyDenyingBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    # The denial goes out FIRST, so it survives truncation the way a real
    # denial-then-keep-going command's would.
    @script "echo 'Operation not permitted' >&2; head -c 1200000 /dev/zero | tr '\\0' 'x'; exit 1"

    @impl Nous.Sandbox
    def confine(_argv, policy) do
      {:ok,
       %Confined{
         argv: ["/bin/sh", "-c", @script],
         mode: policy.mode,
         enforcement: :sandbox_exec,
         denial_signatures: ["operation not permitted", "permission denied"]
       }}
    end

    @impl Nous.Sandbox
    def probe(_timeout_ms), do: {:error, :unusable}
  end

  # A variable that exists in the BEAM's own environment for the duration of
  # each test. The scrubbing tests below assert the spawned shell cannot see it;
  # `System.put_env/2` sets it on the OS process, so an unscrubbed child would
  # inherit it.
  @fake_secret "NOUS_TEST_FAKE_SECRET"

  setup do
    original_mode = Application.fetch_env(:nous, :sandbox_mode)
    original_backend = Application.fetch_env(:nous, :sandbox_backend)
    original_secret = System.get_env(@fake_secret)
    System.put_env(@fake_secret, "sk-live-must-never-reach-a-subprocess")

    Sandbox.warm()
    Sandbox.reset_backend_cache()

    workspace = Path.join(System.tmp_dir!(), "bash_sandbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
      restore(:sandbox_mode, original_mode)
      restore(:sandbox_backend, original_backend)
      ArgvCapturingBackend.forget()

      case original_secret do
        nil -> System.delete_env(@fake_secret)
        value -> System.put_env(@fake_secret, value)
      end

      Sandbox.reset_backend_cache()
    end)

    marker = Path.join(workspace, "bash_ran_marker")

    {
      :ok,
      # What `Nous.Sandbox.Policy` will hand a provider: the workspace root
      # canonicalised (on macOS the tmp dir is behind /var -> /private/var), so a
      # stub backend's path can be predicted from the test.
      workspace: workspace,
      canonical_workspace: Policy.canonical(workspace),
      marker: marker,
      ctx: RunContext.new(%{workspace_root: workspace}, approval_gated?: true),
      touch: %{"command" => "touch '#{marker}'"}
    }
  end

  describe "a fail-closed policy with no usable provider" do
    setup do
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "refuses, and the command observably never runs", ctx do
      assert {:error, message} = Bash.execute(ctx.ctx, ctx.touch)

      assert message =~ "no OS sandbox can enforce"
      assert message =~ "read_only"
      assert message =~ "was NOT executed"

      # The refusal has to be actionable. A provider IS installed on most hosts
      # that hit this: the probe has a 2s budget and a loaded machine can miss
      # it, so the message names the escape hatch instead of leaving the
      # operator to guess.
      assert message =~ "Nous.Sandbox.reset_backend_cache/0"
      assert message =~ "Install a sandbox provider"

      # The load-bearing assertion: silent unconfined passthrough is never legal,
      # so the side effect must not have happened.
      refute File.exists?(ctx.marker)
    end

    test "the refusal survives the real tool entry point", ctx do
      run_ctx =
        RunContext.new(%{workspace_root: ctx.workspace},
          approval_handler: fn %{name: "bash"} -> :approve end
        )

      log =
        capture_log(fn ->
          assert {:error, error} = ToolExecutor.execute(bash_tool(), ctx.touch, run_ctx)
          assert error_message(error) =~ "no OS sandbox can enforce"
        end)

      refute File.exists?(ctx.marker)
      # An approved-but-unconfinable call must not look like an approval problem.
      refute log =~ "requires approval"
    end

    test "the control: the same command does run once confinement is not required", ctx do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)

      assert {:ok, _output} = Bash.execute(ctx.ctx, ctx.touch)
      assert File.exists?(ctx.marker)
    end

    test "a session policy on the context overrides the permissive application default", ctx do
      # App config says "run unconfined"; the session asked for :read_only, and
      # there is no provider, so the tool must still refuse.
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)

      run_ctx =
        RunContext.new(%{workspace_root: ctx.workspace},
          approval_gated?: true,
          sandbox: Policy.new(mode: :read_only, workspace_root: ctx.workspace)
        )

      assert {:error, message} = Bash.execute(run_ctx, ctx.touch)
      assert message =~ "read_only"
      refute File.exists?(ctx.marker)
    end
  end

  describe ":danger_full_access backward compatibility" do
    setup do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "the tool still runs commands and returns their stdout", ctx do
      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo hello"})
      assert output == "hello\n"
    end

    test "merged stderr now reaches the caller", ctx do
      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo boom >&2"})
      assert output =~ "boom"
    end

    test "stdout and stderr arrive together, in one stream", ctx do
      assert {:ok, output} =
               Bash.execute(ctx.ctx, %{"command" => "echo first; echo second >&2"})

      assert output =~ "first"
      assert output =~ "second"
    end

    test "a nonzero exit is still rendered, not raised", ctx do
      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo bye; exit 3"})
      assert output =~ "Exit code: 3"
      assert output =~ "bye"
    end
  end

  describe "classification of a finished confined command" do
    test "a denial is appended to the output", ctx do
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, DenyingBackend)

      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo x > /etc/nope"})

      assert output =~ "Operation not permitted"
      assert String.ends_with?(output, "\n[sandbox: file access denied under read_only mode]")
    end

    test "the mode named in the denial is the resolved mode", ctx do
      Application.put_env(:nous, :sandbox_mode, :workspace_write)
      Application.put_env(:nous, :sandbox_backend, DenyingBackend)

      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo x > /etc/nope"})

      assert String.ends_with?(
               output,
               "\n[sandbox: file access denied under workspace_write mode]"
             )
    end

    test "the denial marker is appended AFTER the exit-code line", ctx do
      # `render/2` puts `Exit code: N` first and the annotation last, so the
      # marker reads as a footnote on the whole transcript rather than as part
      # of the command's own output. Swapping the two would put a
      # model-controlled stream after the framework's verdict.
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, DenyingBackend)

      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo x > /etc/nope"})

      assert output =~ "Exit code: "
      assert output =~ "[sandbox: file access denied under "

      [exit_line_at, marker_at] =
        Enum.map(["Exit code: ", "[sandbox: file access denied under "], fn needle ->
          {at, _len} = :binary.match(output, needle)
          at
        end)

      assert exit_line_at < marker_at
      assert String.ends_with?(output, "mode]")
    end

    test "a broken runner annotates the output; it never replaces it", ctx do
      # The classified stream is the confined COMMAND's own merged output, so a
      # verdict is forgeable by the model. Forgery cannot weaken enforcement,
      # but if a verdict REPLACED the output with an `{:error, _}` the model
      # could launder a real side effect out of the transcript: print
      # `sandbox-exec: ...`, exit nonzero, and the write it just performed
      # disappears from the conversation. Appending cannot do that.
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, BrokenRunnerBackend)

      side_effect = BrokenRunnerBackend.side_effect_path(ctx.canonical_workspace)

      capture_log(fn ->
        assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo x > /etc/nope"})

        # The side effect really happened...
        assert File.exists?(side_effect)
        # ...and the transcript still says so.
        assert output =~ "the command really wrote #{side_effect}"
        assert output =~ "Exit code: 1"

        # Verbatim, because the wording is the whole warning: "may never have
        # run" plus an explicit instruction not to read this as prevention.
        assert String.ends_with?(
                 output,
                 "\n[sandbox: the sandbox_exec runner reported an error, so the command " <>
                   "may never have run: sandbox-exec: could not parse profile. Treat this " <>
                   "output as untrustworthy and do not assume the command was prevented.]"
               )

        # The runner's output carries a denial signature too, on its own line.
        # Reporting this as a denial would let a broken sandbox read as working
        # confinement.
        refute output =~ "file access denied"
      end)
    end

    test "the broken-runner failure is logged as a warning", ctx do
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, BrokenRunnerBackend)

      log =
        capture_log(fn ->
          assert {:ok, _output} = Bash.execute(ctx.ctx, %{"command" => "echo x > /etc/nope"})
        end)

      assert log =~ "Sandbox runner (sandbox_exec) reported a failure"
      assert log =~ "could not parse profile"
    end

    test "output over the size ceiling is still classified", ctx do
      # `NetRunner` reports a blown ceiling as `{:error, {:max_output_exceeded,
      # partial}}`, not as a `{output, status}` pair, so this took its own
      # branch and used to skip classification entirely. A chatty command can
      # also be a denied one, and dropping the marker there teaches the model
      # that "no marker" means "the write landed".
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, ChattyDenyingBackend)

      assert {:ok, output} = Bash.execute(ctx.ctx, %{"command" => "echo x > /etc/nope"})

      assert output =~ "[Output truncated at 1000000 bytes]"
      assert String.ends_with?(output, "\n[sandbox: file access denied under read_only mode]")
    end

    test "the stubs carry the provider's real denial signatures", ctx do
      # Anti-drift: these stubs stand in for Seatbelt, so a provider that gains
      # or loses a signature must not leave them behind. `confine/2` is pure on
      # both providers, so this needs no sandbox binary and runs everywhere.
      policy = Policy.new(mode: :read_only, workspace_root: ctx.workspace)

      assert {:ok, real} = Nous.Sandbox.Seatbelt.confine(["/bin/true"], policy)
      assert {:ok, denying} = DenyingBackend.confine(["/bin/true"], policy)
      assert {:ok, broken} = BrokenRunnerBackend.confine(["/bin/true"], policy)

      assert denying.denial_signatures == real.denial_signatures
      assert broken.denial_signatures == real.denial_signatures
    end
  end

  describe "a NUL byte in the command" do
    setup do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "is refused, and the command observably never runs", ctx do
      # The port layer TRUNCATES argv at a NUL instead of rejecting it
      # (`Port.open(..., args: ["a" <> <<0>> <> "b"])` execs with just "a"), so
      # the command an operator approves and the command the kernel executes are
      # DIFFERENT strings. `git push origin main\0 --dry-run` is approved as a
      # dry run and executed as a push. That is an approval-gate bypass, not a
      # hygiene problem, which is why this refuses before confinement.
      command = "touch '#{ctx.marker}'" <> <<0>> <> " ; rm -rf /tmp/x"

      assert {:error, message} = Bash.execute(ctx.ctx, %{"command" => command})
      assert message =~ ~r/NUL/
      refute File.exists?(ctx.marker)
    end

    test "the control: the same command without the NUL runs", ctx do
      # So the refusal above is the NUL and not the quoting or the tmp path.
      assert {:ok, _output} = Bash.execute(ctx.ctx, %{"command" => "touch '#{ctx.marker}'"})
      assert File.exists?(ctx.marker)
    end

    test "the refusal happens before any provider is consulted", ctx do
      # `:read_only` with a provider that WOULD confine, so the backend is
      # genuinely on the path: without the guard the argv reaches `confine/2`
      # (and then the kernel, truncated at the NUL). `:danger_full_access` could
      # not show this — it short-circuits before any backend, so the refute
      # below would hold for a tool with no NUL guard at all.
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, ArgvCapturingBackend)
      ArgvCapturingBackend.observe(self())

      assert {:error, message} =
               Bash.execute(ctx.ctx, %{"command" => "echo safe" <> <<0>> <> " ; rm -rf /tmp/x"})

      # And it is the NUL, not the mode: this provider confines happily.
      assert message =~ ~r/NUL/
      refute message =~ "no OS sandbox can enforce"
      refute_received {:confined_argv, _}

      # Control: the same mode and provider run a NUL-free command.
      assert {:ok, _} = Bash.execute(ctx.ctx, %{"command" => "touch '#{ctx.marker}'"})
      assert_received {:confined_argv, _}
      assert File.exists?(ctx.marker)
    end
  end

  describe "environment scrubbing" do
    # `NetRunner` has no `:env` option: `run/2` forwards unknown options to a
    # port layer that ignores them and the shepherd `execvp`s, so the child
    # inherits the BEAM's whole environment. This tool passed
    # `env: Nous.Tools.Env.scrubbed()` for its entire existence and that option
    # was silently discarded the whole time — `printenv` returned every API key.
    # The scrubbing is therefore enforced by an `/usr/bin/env -i` prefix on the
    # argv, where nothing can ignore it.
    setup do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "the spawned shell cannot see a secret the BEAM holds", ctx do
      assert {:ok, output} =
               Bash.execute(ctx.ctx, %{
                 "command" => "printenv #{@fake_secret} || echo '<absent>'"
               })

      assert String.trim(output) == "<absent>"
      refute output =~ "sk-live"
    end

    test "the child's whole environment is bounded by the allowlist", ctx do
      assert {:ok, output} =
               Bash.execute(ctx.ctx, %{"command" => "printenv | cut -d= -f1 | sort"})

      names = output |> String.split("\n", trim: true) |> MapSet.new()

      # `Nous.Tools.Env`'s allowlist, plus the three names `/bin/sh` sets in its
      # OWN environment after `env -i` has already cleared everything (they are
      # the shell's values, not the BEAM's).
      allowed =
        MapSet.new(~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM) ++ ~w(_ PWD SHLVL))

      assert MapSet.subset?(names, allowed),
             "unexpected variables reached the child: #{inspect(MapSet.difference(names, allowed))}"

      # A bound, not just set membership: measured, the unscrubbed BEAM
      # environment reaches this shell as 73 names on this machine and the
      # scrubbed one as 9, so a regression that drops the `env -i` prefix blows
      # straight through a ceiling of 11.
      assert MapSet.size(names) <= MapSet.size(allowed)
    end

    test "scrubbing is independent of confinement: the argv carries it", ctx do
      # Under a real provider the argv is rewritten, and under
      # `:danger_full_access` no provider is consulted at all — so the only way
      # to see what the tool hands `Nous.Sandbox.confine/2` is to capture it.
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, ArgvCapturingBackend)
      ArgvCapturingBackend.observe(self())

      assert {:ok, _output} = Bash.execute(ctx.ctx, %{"command" => "true"})

      assert_received {:confined_argv, argv}
      assert Enum.take(argv, 2) == ["/usr/bin/env", "-i"]
      assert List.last(argv, nil) == "true"
      assert "/bin/sh" in argv

      # And no unallowlisted name is spliced into the pairs.
      pairs = argv |> Enum.drop(2) |> Enum.take_while(&(&1 != "/bin/sh"))
      names = Enum.map(pairs, &(&1 |> String.split("=", parts: 2) |> hd()))
      assert names -- ~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM) == []
      refute @fake_secret in names
    end

    test "and it still holds under confinement, end to end", ctx do
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, ArgvCapturingBackend)

      assert {:ok, output} =
               Bash.execute(ctx.ctx, %{
                 "command" => "printenv #{@fake_secret} || echo '<absent>'"
               })

      assert String.trim(output) == "<absent>"
    end
  end

  # ---------------------------------------------------------------------------

  defp bash_tool, do: Tool.from_module(Nous.Tools.Bash)

  defp restore(key, {:ok, value}), do: Application.put_env(:nous, key, value)
  defp restore(key, :error), do: Application.delete_env(:nous, key)

  defp error_message(%{message: message}), do: message
  defp error_message(message) when is_binary(message), do: message
end

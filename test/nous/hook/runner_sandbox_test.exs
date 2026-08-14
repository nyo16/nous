defmodule Nous.Hook.RunnerSandboxTest do
  # async: false — every test here sets `:nous, :sandbox_confine_command_hooks`,
  # `:nous, :sandbox_mode` and `:nous, :sandbox_backend`, and the
  # confine-flag warning latch lives in `:persistent_term`. All of it is
  # VM-global, and a leaked `:sandbox_backend` silently changes
  # `Nous.Tools.Bash` for every other test in the run.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.Hook
  alias Nous.Hook.Runner
  alias Nous.Sandbox
  alias Nous.Sandbox.{Confined, Unavailable}

  # Hands back the argv it was given while reporting `enforcement: :sandbox_exec`.
  # A real provider would rewrite the argv into `sandbox-exec -p ... -- ...`,
  # which needs a macOS host; what `Nous.Hook.Runner` actually branches on is
  # `confined.enforcement`, and this reproduces that faithfully on any host.
  defmodule ConfiningBackend do
    @moduledoc false
    @behaviour Nous.Sandbox

    @impl Nous.Sandbox
    def confine(argv, policy) do
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

  # The once-per-VM latch `warn_confine_flag_without_mode_once/1` uses. Private
  # by convention, reached here on purpose: without erasing it the warning test
  # passes or fails depending on whether an earlier test in the same VM already
  # consumed the latch, which is the worst kind of assertion.
  @confine_flag_warned_key {Nous.Hook.Runner, :confine_flag_without_mode_warned}

  setup do
    original_flag = Application.fetch_env(:nous, :sandbox_confine_command_hooks)
    original_mode = Application.fetch_env(:nous, :sandbox_mode)
    original_backend = Application.fetch_env(:nous, :sandbox_backend)

    Sandbox.warm()
    Sandbox.reset_backend_cache()

    workspace =
      Path.join(System.tmp_dir!(), "hook_sandbox_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
      restore(:sandbox_confine_command_hooks, original_flag)
      restore(:sandbox_mode, original_mode)
      restore(:sandbox_backend, original_backend)
      Sandbox.reset_backend_cache()
    end)

    {:ok, workspace: workspace, marker: Path.join(workspace, "hook_ran")}
  end

  describe "the default: command hooks are NOT confined" do
    setup do
      # The flag unset is the shipped default. `:read_only` + a provider that
      # can confine nothing is the configuration that would refuse the hook if
      # the default were inverted — so the marker below is a real discriminator,
      # not a tautology.
      Application.delete_env(:nous, :sandbox_confine_command_hooks)
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "the hook runs and its side effect lands", ctx do
      hook = command_hook(touch(ctx.marker))

      assert Runner.run_hooks([hook], :pre_tool_use, %{tool_name: "x"}) == :allow
      assert File.exists?(ctx.marker)
    end

    test "and it is not the mode being permissive: the mode really is :read_only", _ctx do
      # Pins WHY the hook ran. `confine_hook_argv/1` builds
      # `Policy.new(:danger_full_access)` for itself rather than resolving the
      # application mode, so an operator's `:read_only` must not reach hooks.
      assert Nous.Sandbox.Policy.resolve(nil).mode == :read_only
    end

    test "the control: the same hook is refused once the flag is on", ctx do
      Application.put_env(:nous, :sandbox_confine_command_hooks, true)

      capture_log(fn ->
        assert Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{}) == :allow
      end)

      refute File.exists?(ctx.marker)
    end
  end

  describe "the flag is on but no provider can confine" do
    setup do
      Application.put_env(:nous, :sandbox_confine_command_hooks, true)
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "the hook does not run unconfined", ctx do
      log =
        capture_log(fn ->
          Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{})
        end)

      # The load-bearing assertion: "no sandbox available" must never degrade
      # into "run it anyway".
      refute File.exists?(ctx.marker)
      assert log =~ "Command hook NOT run"
    end

    test "fail_closed decides the event: the default allows", ctx do
      capture_log(fn ->
        assert Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{}) == :allow
      end)

      refute File.exists?(ctx.marker)
    end

    test "fail_closed: true denies", ctx do
      hook = command_hook(touch(ctx.marker), fail_closed: true)

      capture_log(fn ->
        assert {:deny, reason} = Runner.run_hooks([hook], :pre_tool_use, %{})
        assert reason =~ "fail_closed"
      end)

      refute File.exists?(ctx.marker)
    end
  end

  describe "the flag is on and the hook IS confined" do
    setup do
      Application.put_env(:nous, :sandbox_confine_command_hooks, true)
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, ConfiningBackend)
      :ok
    end

    test "a nonzero exit denies even with the default fail_closed: false" do
      # Previously this fell through to `:allow`, so a security hook that the
      # sandbox denied — or that never started — silently permitted the event.
      # From stdout alone "denied", "runner broke" and "hook failed" are
      # indistinguishable, because all three report on stderr and this path
      # keeps `stderr: :consume` so the JSON protocol stays parseable.
      hook = command_hook(["/bin/sh", "-c", "exit 3"])

      capture_log(fn ->
        assert Runner.run_hooks([hook], :pre_tool_use, %{}) ==
                 {:deny,
                  "confined command hook exited with code 3; " <>
                    "it may have been denied by the sandbox or never run"}
      end)
    end

    test "and with fail_closed: true it denies identically" do
      hook = command_hook(["/bin/sh", "-c", "exit 3"], fail_closed: true)

      capture_log(fn ->
        assert Runner.run_hooks([hook], :pre_tool_use, %{}) ==
                 {:deny,
                  "confined command hook exited with code 3; " <>
                    "it may have been denied by the sandbox or never run"}
      end)
    end

    test "stdout cannot override the exit code" do
      # The nastiest shape: the hook prints a well-formed protocol `allow` and
      # then exits nonzero. If stdout won, a hook killed by the sandbox mid-run
      # (after it had already flushed an optimistic verdict) would permit the
      # event it exists to gate.
      hook = command_hook(["/bin/sh", "-c", ~s(echo '{"result":"allow"}'; exit 3)])

      capture_log(fn ->
        assert {:deny, reason} = Runner.run_hooks([hook], :pre_tool_use, %{})
        assert reason =~ "confined command hook exited with code 3"
      end)
    end

    test "the control: exit 0 is still parsed from stdout" do
      # So the deny above is the exit code, not "confinement denies everything".
      allow = command_hook(["/bin/sh", "-c", ~s(echo '{"result":"allow"}')])
      deny = command_hook(["/bin/sh", "-c", ~s(echo '{"result":"deny","reason":"nope"}')])

      assert Runner.run_hooks([allow], :pre_tool_use, %{}) == :allow
      assert Runner.run_hooks([deny], :pre_tool_use, %{}) == {:deny, "nope"}
    end

    test "the control: the confined hook really does run", ctx do
      # `ConfiningBackend` passes argv through, so a confined hook that exits 0
      # still has its side effect. Without this, every assertion above would
      # also hold for a confinement path that simply never spawns anything.
      assert Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{}) == :allow
      assert File.exists?(ctx.marker)
    end

    test "exit 2 is still the protocol's own deny, not the confinement deny" do
      hook = command_hook(["/bin/sh", "-c", "exit 2"])

      assert Runner.run_hooks([hook], :pre_tool_use, %{}) == :deny
    end
  end

  describe "unconfined regression (the default path must not have changed)" do
    setup do
      Application.delete_env(:nous, :sandbox_confine_command_hooks)
      Application.put_env(:nous, :sandbox_mode, :read_only)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      :ok
    end

    test "exit 3 with fail_closed: false still allows" do
      hook = command_hook(["/bin/sh", "-c", "exit 3"])

      capture_log(fn ->
        assert Runner.run_hooks([hook], :pre_tool_use, %{}) == :allow
      end)
    end

    test "exit 3 with fail_closed: true still denies, with the historical reason" do
      hook = command_hook(["/bin/sh", "-c", "exit 3"], fail_closed: true)

      capture_log(fn ->
        assert Runner.run_hooks([hook], :pre_tool_use, %{}) ==
                 {:deny, "command hook exited with code 3 (fail_closed)"}
      end)
    end

    test "exit 2 still denies" do
      assert Runner.run_hooks([command_hook(["/bin/sh", "-c", "exit 2"])], :pre_tool_use, %{}) ==
               :deny
    end

    test "exit 0 with allow stdout still allows" do
      hook = command_hook(["/bin/sh", "-c", ~s(echo '{"result":"allow"}')])
      assert Runner.run_hooks([hook], :pre_tool_use, %{}) == :allow
    end
  end

  describe "the flag is on but the resolved mode confines nothing" do
    setup do
      :persistent_term.erase(@confine_flag_warned_key)
      Application.put_env(:nous, :sandbox_confine_command_hooks, true)
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      on_exit(fn -> :persistent_term.erase(@confine_flag_warned_key) end)
      :ok
    end

    test "it warns, loudly, naming both settings", ctx do
      log =
        capture_log(fn ->
          assert Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{}) ==
                   :allow
        end)

      assert log =~ "sandbox_confine_command_hooks"
      assert log =~ ":danger_full_access"
      assert log =~ "UNCONFINED"
      assert log =~ "sandbox_mode"

      # Flag on, nothing confined: the hook still ran. That is the whole point
      # of the warning — silence here would read as "confinement is on".
      assert File.exists?(ctx.marker)
    end

    test "and only once per VM", ctx do
      first =
        capture_log(fn ->
          Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{})
        end)

      second =
        capture_log(fn ->
          Runner.run_hooks([command_hook(touch(ctx.marker))], :pre_tool_use, %{})
        end)

      assert first =~ "sandbox_confine_command_hooks"
      refute second =~ "sandbox_confine_command_hooks"
    end
  end

  # ---------------------------------------------------------------------------

  defp command_hook(argv, opts \\ []) do
    %Hook{
      event: :pre_tool_use,
      type: :command,
      handler: argv,
      name: "sandbox_probe",
      timeout: 10_000,
      fail_closed: Keyword.get(opts, :fail_closed, false)
    }
  end

  defp touch(marker), do: ["/bin/sh", "-c", "touch '#{marker}'"]

  defp restore(key, {:ok, value}), do: Application.put_env(:nous, key, value)
  defp restore(key, :error), do: Application.delete_env(:nous, key)
end

defmodule Nous.SandboxIntegrationTest do
  # async: false — these tests spawn real confined processes and touch the
  # `:persistent_term` backend cache.
  use ExUnit.Case, async: false

  @moduletag :sandbox_integration

  # The aliases live inside the `if` below, not here: on a host without the
  # platform binary (CI's Linux runners have no `bwrap`) the whole block compiles
  # out, and aliases at module level would then warn as unused on exactly the
  # platform where the suite is meant to be a silent no-op.

  # The provider for THIS host, or `nil`. Resolved at compile time on purpose:
  # ExUnit offers no runtime skip from `setup`, so on a host without the binary
  # the tests below simply do not exist rather than being faked green.
  platform_provider =
    case :os.type() do
      {:unix, :darwin} -> if System.find_executable("sandbox-exec"), do: Nous.Sandbox.Seatbelt
      {:unix, :linux} -> if System.find_executable("bwrap"), do: Nous.Sandbox.Bwrap
      _other -> nil
    end

  if platform_provider do
    @provider platform_provider

    alias Nous.Sandbox
    alias Nous.Sandbox.Policy

    setup do
      original_backend = Application.fetch_env(:nous, :sandbox_backend)
      Sandbox.warm()
      Sandbox.reset_backend_cache()

      workspace =
        Path.join(System.tmp_dir!(), "sandbox_integration_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      on_exit(fn ->
        File.rm_rf!(workspace)

        case original_backend do
          {:ok, backend} -> Application.put_env(:nous, :sandbox_backend, backend)
          :error -> Application.delete_env(:nous, :sandbox_backend)
        end

        Sandbox.reset_backend_cache()
      end)

      {:ok, workspace: workspace}
    end

    test "this host's provider probes clean and wins backend selection" do
      Application.delete_env(:nous, :sandbox_backend)
      Sandbox.reset_backend_cache()

      assert {:ok, grade} = @provider.probe(2_000)
      assert grade in [:full, :partial]
      assert Sandbox.backend() == @provider
    end

    test "read_only denies a real write and classifies it as a denial, not a runner failure" do
      target = Path.join(System.tmp_dir!(), "nous_sandbox_probe_#{unique()}")
      on_exit(fn -> File.rm_rf!(target) end)

      policy = Policy.new(mode: :read_only, workspace_root: File.cwd!())
      assert Sandbox.writable_roots(policy) == []

      assert {:ok, confined} =
               @provider.confine(["/bin/sh", "-c", "echo x > #{target}"], policy)

      {output, status} = run(confined)

      assert status != 0, "expected the confined write to fail, got #{inspect({output, status})}"

      # The distinction this whole seam exists for: the kernel refused the write
      # (the command DID run), which must never be reported as a broken runner.
      assert {:sandbox_denied, :read_only, enforcement} =
               Sandbox.classify(confined, status, output)

      assert enforcement == confined.enforcement
      refute File.exists?(target)
    end

    test "workspace_write permits a write inside the workspace root", %{workspace: workspace} do
      # Inside the workspace root, not /tmp: bwrap mounts an ephemeral tmpfs over
      # /tmp under this mode, so a successful write there would prove nothing.
      target = Path.join(workspace, "probe")
      policy = Policy.new(mode: :workspace_write, workspace_root: workspace)

      assert {:ok, confined} =
               @provider.confine(["/bin/sh", "-c", "echo x > #{target}"], policy)

      {output, status} = run(confined)

      assert Sandbox.classify(confined, status, output) == :ok
      assert status == 0, output
      assert File.read!(target) == "x\n"
    end

    test "workspace_write still denies a write outside every writable root", %{
      workspace: workspace
    } do
      # The project directory: writable without a sandbox (we are editing it), and
      # not among `writable_roots/1` when the workspace root is a temp dir.
      target = Path.join(File.cwd!(), "nous_sandbox_outside_probe_#{unique()}")
      on_exit(fn -> File.rm_rf!(target) end)

      policy = Policy.new(mode: :workspace_write, workspace_root: workspace)
      roots = Sandbox.writable_roots(policy)

      # That premise is about the HOST, not the code, and it is false when the
      # checkout itself sits inside a writable root: a clone under `/tmp` puts
      # `File.cwd!()` beneath `/private/tmp`, which is writable by policy. Asserting
      # it there produces a red that says nothing about the sandbox, so name the
      # unusable fixture rather than failing the behaviour it cannot exercise.
      if Enum.any?(roots, &String.starts_with?(target, &1 <> "/")) do
        flunk(
          "fixture unusable on this host: the checkout (#{File.cwd!()}) is inside a writable " <>
            "root (#{inspect(roots)}), so no outside-the-fence path exists here. Run from a " <>
            "checkout outside the system temp dir."
        )
      end

      assert {:ok, confined} =
               @provider.confine(["/bin/sh", "-c", "echo x > #{target}"], policy)

      {output, status} = run(confined)

      assert status != 0, "expected the confined write to fail, got #{inspect({output, status})}"
      assert {:sandbox_denied, :workspace_write, _} = Sandbox.classify(confined, status, output)
      refute File.exists?(target)
    end

    test "the /dev write grant works under read_only" do
      # `> /dev/stdout`, `tee /dev/stderr` and `> /dev/fd/1` were ALL denied on
      # macOS while all four succeeded under bwrap — a silent cross-platform
      # split that made every "write your answer to stdout" idiom a denial on
      # one host and not the other. Five `/dev` nodes are now granted
      # explicitly; four of them are exercised below.
      #
      # `/dev/tty` is granted too but is not exercised here: NetRunner gives the
      # child a pipe, not a pty, so a write there fails with ENXIO on any host,
      # sandbox or no sandbox. That is a test-harness limit, not a fence.
      policy = Policy.new(mode: :read_only, workspace_root: File.cwd!())
      assert Sandbox.writable_roots(policy) == []

      script =
        "echo null > /dev/null && echo out > /dev/stdout && " <>
          "echo err > /dev/stderr && echo fd > /dev/fd/1"

      assert {:ok, confined} = @provider.confine(["/bin/sh", "-c", script], policy)

      {output, status} = run(confined)

      assert status == 0, "expected the /dev writes to succeed, got #{inspect({output, status})}"
      assert output =~ "out"
      assert output =~ "err"
      assert output =~ "fd"
      assert Sandbox.classify(confined, status, output) == :ok
    end

    test "the /dev grant did not widen the fence: $HOME is still refused under read_only" do
      # The control for the test above: granting five `/dev` nodes must not
      # widen anything else, and `read_only` still means read only. `/dev`
      # itself cannot serve as that control — devfs refuses a new node to an
      # unprivileged process with or without a sandbox, so such a test would
      # pass against a profile that granted the whole directory.
      target = Path.join(System.user_home!(), "nous_sandbox_home_probe_#{unique()}")
      on_exit(fn -> File.rm_rf!(target) end)

      policy = Policy.new(mode: :read_only, workspace_root: File.cwd!())

      assert {:ok, confined} =
               @provider.confine(["/bin/sh", "-c", "echo x > #{target}"], policy)

      {output, status} = run(confined)

      assert status != 0, "expected the confined write to fail, got #{inspect({output, status})}"
      assert {:sandbox_denied, :read_only, _} = Sandbox.classify(confined, status, output)
      refute File.exists?(target)
    end

    test "Bash under workspace_write: a relative path is written in the workspace", %{
      workspace: workspace
    } do
      # The reported failure: the shell ran in the BEAM's cwd, so this write
      # either landed outside the workspace or was denied by the very fence that
      # should allow it. Through the real tool entry point, with the real
      # provider selected by the probe.
      Application.delete_env(:nous, :sandbox_backend)
      Sandbox.reset_backend_cache()

      ctx =
        Nous.RunContext.new(%{workspace_root: workspace},
          approval_gated?: true,
          sandbox: Policy.new(mode: :workspace_write, workspace_root: workspace)
        )

      assert {:ok, output} =
               Nous.Tools.Bash.execute(ctx, %{"command" => "echo inside > rel_probe.txt"})

      refute output =~ "sandbox: file access denied", output
      assert File.read!(Path.join(workspace, "rel_probe.txt")) == "inside\n"
      refute File.exists?(Path.join(File.cwd!(), "rel_probe.txt"))
    end

    defmodule ScriptedBash do
      @moduledoc false
      # One bash call with a relative path, then a final answer.
      def request(_model, messages, _settings) do
        parts =
          if Enum.any?(messages, &(&1.role == :tool)),
            do: [{:text, "done"}],
            else: [
              {:tool_call,
               %{
                 id: "call_1",
                 name: "bash",
                 arguments: %{"command" => "echo agent > agent_probe.txt"}
               }}
            ]

        {:ok,
         Nous.Message.from_legacy(%{
           parts: parts,
           usage: %Nous.Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2, requests: 1},
           model_name: "scripted",
           timestamp: DateTime.utc_now()
         })}
      end

      def request_stream(_model, _messages, _settings), do: {:ok, []}
      def count_tokens(_messages), do: 10
    end

    test "an agent built with sandbox: :workspace_write confines each run to its deps root",
         %{workspace: workspace} do
      # The consumer-facing shape that 0.18.0 got wrong: the agent's sandbox is
      # a bare mode, built once, and every run supplies its own workspace_root.
      # The root used to be frozen to the BEAM's cwd when the agent was built,
      # so this write went to File.cwd!() (or was denied there).
      Application.delete_env(:nous, :sandbox_backend)
      Sandbox.reset_backend_cache()
      Nous.ModelDispatcher.put_dispatcher(ScriptedBash)

      stray = Path.join(File.cwd!(), "agent_probe.txt")
      on_exit(fn -> File.rm(stray) end)

      agent =
        Nous.new("openai:scripted", tools: [Nous.Tools.Bash], sandbox: :workspace_write)

      assert {:ok, result} =
               Nous.run(agent, "go",
                 deps: %{workspace_root: workspace},
                 approval_handler: fn _ -> :approve end
               )

      tool_msg = Enum.find(result.context.messages, &(&1.role == :tool))
      refute tool_msg.content =~ "sandbox: file access denied", tool_msg.content
      assert File.read!(Path.join(workspace, "agent_probe.txt")) == "agent\n"
      refute File.exists?(stray)
    end

    # `merge_stderr/1` is not optional here: NetRunner's `run/2` collects stdout
    # only, and every denial signature a provider publishes is written to stderr.
    # Without the merge these tests would classify a refused write as `:ok`.
    defp run(confined) do
      assert {output, status} =
               NetRunner.run(Sandbox.merge_stderr(confined.argv), timeout: 10_000)

      {output, status}
    end

    defp unique, do: System.unique_integer([:positive])
  end
end

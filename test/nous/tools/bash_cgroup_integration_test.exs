defmodule Nous.Tools.BashCgroupIntegrationTest do
  # async: false — sets `:nous, :sandbox_mode` / `:sandbox_backend` and resets
  # Bash's memoized cgroup-delegation probe, all VM-global.
  use ExUnit.Case, async: false

  # Excluded by default (test/test_helper.exs). Run on a Linux host with a
  # writable cgroup v2 root (a privileged container, or a delegated cgroup):
  #
  #     mix test --only cgroup_integration
  #
  # The cgroup branch of `Nous.Tools.Bash` is only taken where the tool can
  # create a cgroup, so the tests below exist only on such a host — resolved at
  # compile time, like test/nous/sandbox_integration_test.exs, because ExUnit
  # offers no runtime skip from `setup`.
  @moduletag :cgroup_integration

  cgroup_root = "/sys/fs/cgroup"

  cgroup_v2_writable? =
    :os.type() == {:unix, :linux} and
      File.exists?(Path.join(cgroup_root, "cgroup.controllers")) and
      (fn ->
         probe = Path.join(cgroup_root, "nous-test-probe-#{System.unique_integer([:positive])}")

         case File.mkdir(probe) do
           :ok -> File.rmdir(probe) == :ok
           _ -> false
         end
       end).()

  if cgroup_v2_writable? do
    alias Nous.{RunContext, Sandbox}
    alias Nous.Sandbox.Unavailable
    alias Nous.Tools.Bash

    import ExUnit.CaptureLog

    @cgroup_root cgroup_root

    setup do
      original_mode = Application.fetch_env(:nous, :sandbox_mode)
      original_backend = Application.fetch_env(:nous, :sandbox_backend)

      # Isolate the cgroup branch from the write fence: under a real provider
      # (bwrap --unshare-cgroup) /proc/self/cgroup would read "0::/".
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      Application.put_env(:nous, :sandbox_backend, Unavailable)
      Sandbox.reset_backend_cache()
      # Bash memoizes its delegation probe per VM; make it probe this host.
      :persistent_term.erase({Bash, :cgroup_v2_delegated?})

      workspace =
        Path.join(System.tmp_dir!(), "bash_cgroup_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      on_exit(fn ->
        File.rm_rf!(workspace)

        for {key, original} <- [sandbox_mode: original_mode, sandbox_backend: original_backend] do
          case original do
            {:ok, value} -> Application.put_env(:nous, key, value)
            :error -> Application.delete_env(:nous, key)
          end
        end

        Sandbox.reset_backend_cache()
      end)

      {:ok, ctx: RunContext.new(%{workspace_root: workspace}, approval_gated?: true)}
    end

    test "a Bash command runs inside net_runner/nous_bash_<n>, and the leaf is removed", %{
      ctx: ctx
    } do
      log =
        capture_log(fn ->
          assert {:ok, output} = Bash.execute(ctx, %{"command" => "cat /proc/self/cgroup"})
          send(self(), {:output, output})
        end)

      assert_received {:output, output}

      # net_runner 1.4.1 still accepts a flat path, rewriting it under
      # `net_runner/` with this (once per VM) deprecation warning; 2.0 raises.
      # Bash must pass the prefixed path itself.
      refute log =~ "has no net_runner/ prefix"

      # cgroup v2 has a single "0::<path>" line. The path is relative to this
      # process's cgroup namespace root, which is also what /sys/fs/cgroup
      # shows — so the prefix is the one Bash passed as :cgroup_path.
      assert [_, leaf] = Regex.run(~r{^0::/(net_runner/nous_bash_\d+)$}m, output),
             "expected the child in net_runner/nous_bash_<n>, got: #{inspect(output)}"

      # The shepherd `cgroup.kill`s and rmdirs the leaf as the command ends —
      # possibly just after run/2 returns, so allow it a moment. The shared
      # `net_runner/` parent stays.
      assert eventually(fn -> not File.exists?(Path.join(@cgroup_root, leaf)) end),
             "cgroup leaf #{leaf} was left behind"

      assert File.dir?(Path.join(@cgroup_root, "net_runner"))
    end

    defp eventually(fun, attempts \\ 40) do
      cond do
        fun.() ->
          true

        attempts == 0 ->
          false

        true ->
          Process.sleep(50)
          eventually(fun, attempts - 1)
      end
    end
  end
end

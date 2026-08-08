defmodule Nous.Tools.EnvTest do
  use ExUnit.Case, async: false

  alias Nous.Hook
  alias Nous.Hook.Runner
  alias Nous.Tools.Env

  # The allowlist tests below assert `scrubbed/0`'s own return value. That is
  # NOT the control this module exists to pin: two consecutive audits certified
  # a working scrub at 100% line coverage while the control was entirely dead,
  # because `env: scrubbed()` was silently dropped by both spawn APIs. The
  # "child environment" describes therefore assert what the SPAWNED PROCESS can
  # actually see, at each of the three spawn sites, and each has a paired
  # control proving the probe mechanism itself bites.
  @probe "NOUS_ENV_SCRUB_PROBE"
  @probe_value "leaked_abc123"

  # `skip: false` runs the test; `skip: <message>` skips it. A runtime `if`
  # around the body would instead make the test vacuous when rg is absent — a
  # test that passes for any implementation, the exact shape P6-T5 sweeps for.
  @no_rg if System.find_executable("rg"), do: false, else: "ripgrep is not installed"

  setup do
    System.put_env(@probe, @probe_value)
    on_exit(fn -> System.delete_env(@probe) end)
    :ok
  end

  describe "scrubbed/0" do
    test "forwards only allowlisted variables" do
      env = Env.scrubbed()
      names = Enum.map(env, fn {name, _} -> name end)

      refute @probe in names
      assert Enum.all?(names, &(&1 in ~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM)))
    end

    test "includes set allowlisted variables with their values" do
      System.put_env("TZ", "UTC")
      on_exit(fn -> System.delete_env("TZ") end)

      assert {"TZ", "UTC"} in Env.scrubbed()
    end

    test "drops unset allowlisted variables instead of emitting nil" do
      original = System.get_env("LC_ALL")
      System.delete_env("LC_ALL")

      on_exit(fn ->
        if original, do: System.put_env("LC_ALL", original)
      end)

      refute Enum.any?(Env.scrubbed(), fn {name, _} -> name == "LC_ALL" end)
      refute Enum.any?(Env.scrubbed(), fn {_, value} -> is_nil(value) end)
    end
  end

  describe "scrub_argv/1" do
    test "runs the command under env -i with only the allowlist re-established" do
      assert [env_bin, "-i" | rest] = Env.scrub_argv(["/bin/sh", "-c", "true"])
      assert Path.basename(env_bin) == "env"

      assignments = Enum.take_while(rest, &String.contains?(&1, "="))
      assert ["/bin/sh", "-c", "true"] == Enum.drop(rest, length(assignments))
      refute Enum.any?(assignments, &String.starts_with?(&1, @probe <> "="))
    end
  end

  describe "child environment: Nous.Tools.Bash" do
    test "the spawned shell cannot read a non-allowlisted variable" do
      assert {:ok, output} =
               Nous.Tools.Bash.execute(Nous.RunContext.new(%{}), %{
                 "command" => "printenv #{@probe}; echo PATH_IS=$PATH"
               })

      refute output =~ @probe_value
      # PATH must survive, or the tool is scrubbed into uselessness rather than
      # scrubbed correctly.
      assert output =~ "PATH_IS=/"
    end

    test "control: the same command leaks the variable when spawned unscrubbed" do
      # Without this, the assertion above would stay green if `printenv` simply
      # were not reachable from the child.
      assert {output, _} = NetRunner.run(["/bin/sh", "-c", "printenv #{@probe}"], timeout: 5_000)
      assert output =~ @probe_value
    end
  end

  describe "child environment: Nous.Tools.FileGrep" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      # `RIPGREP_CONFIG_PATH` is read from rg's own environment, so it is an
      # in-band probe: a config that excludes every file turns a matching search
      # into "no matches". If the BEAM's environment leaks into rg, the needle
      # disappears.
      config = Path.join(tmp_dir, "rg.conf")
      File.write!(config, "--glob=!**\n")
      File.write!(Path.join(tmp_dir, "haystack.txt"), "needle here\n")

      System.put_env("RIPGREP_CONFIG_PATH", config)
      on_exit(fn -> System.delete_env("RIPGREP_CONFIG_PATH") end)

      %{ctx: Nous.RunContext.new(%{workspace_root: tmp_dir})}
    end

    @tag skip: @no_rg
    test "rg does not inherit a config path from the BEAM's environment", ctx do
      assert {:ok, output} =
               Nous.Tools.FileGrep.execute(ctx.ctx, %{
                 "pattern" => "needle",
                 "path" => ctx.tmp_dir,
                 "output_mode" => "content"
               })

      assert output =~ "needle here"
    end

    @tag skip: @no_rg
    test "control: rg does honour RIPGREP_CONFIG_PATH when it inherits it", %{tmp_dir: tmp_dir} do
      # Proves the probe bites. If rg ever stopped reading this variable the test
      # above would pass for the wrong reason, and this one goes red first.
      rg = System.find_executable("rg")

      assert {"", 1} =
               System.cmd(rg, ["--regexp", "needle", "-n", "--", tmp_dir], stderr_to_stdout: true)
    end
  end

  describe "child environment: command hooks" do
    @describetag :tmp_dir

    test "a command hook process cannot read a non-allowlisted variable", %{tmp_dir: tmp_dir} do
      dump = Path.join(tmp_dir, "hook_env")

      hook = %Hook{
        event: :pre_tool_use,
        type: :command,
        # The dump path arrives as a positional argument, not interpolated into
        # the script: ExUnit's :tmp_dir names are derived from the test name and
        # keep apostrophes, which shell quoting would not survive.
        handler: ["/bin/sh", "-c", ~s(printenv > "$1"), "sh", dump],
        priority: 100,
        timeout: 5_000
      }

      assert :allow = Runner.run_hooks([hook], :pre_tool_use, %{tool_name: "probe"})

      env = File.read!(dump)
      refute env =~ @probe_value
      assert env =~ "PATH="
    end
  end
end

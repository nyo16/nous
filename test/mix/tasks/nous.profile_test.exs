defmodule Mix.Tasks.Nous.ProfileTest do
  # End to end, in process: each task runs as `mix` would run it, and a
  # non-zero exit is caught as `{:shutdown, code}`.
  use ExUnit.Case, async: false

  alias Nous.Eval.Profiles
  alias Nous.Eval.Store
  alias Nous.Profile
  alias NousTest.ProfileFixtures, as: F

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp run(task, argv) do
    Mix.Task.reenable(task)

    try do
      Mix.Task.run(task, argv)
      0
    catch
      :exit, {:shutdown, code} -> code
    end
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _kind, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  defp write_profile(dir, name, profile) do
    path = Path.join(dir, name)
    File.write!(path, Profile.encode(profile))
    path
  end

  test "check passes a current profile and fails a stale one with exit 1", %{tmp_dir: dir} do
    path = write_profile(dir, "p.json", F.sealed(F.full_components("NEW"), F.agent()))

    assert run("nous.profile.check", [
             "--agent",
             "NousTest.ProfileFixtures.agent",
             "--profile",
             path
           ]) ==
             0

    assert output() =~ "1 ok, 0 failed"

    assert run("nous.profile.check", [
             "--agent",
             "NousTest.ProfileFixtures.edited_agent",
             "--profile",
             path
           ]) == 1

    assert output() =~ "stale"
  end

  test "check reports a vanished tool and operational errors distinctly", %{tmp_dir: dir} do
    path = write_profile(dir, "p.json", F.sealed(F.full_components("NEW"), F.agent()))

    assert run("nous.profile.check", [
             "--agent",
             "NousTest.ProfileFixtures.toolless_agent",
             "--profile",
             path
           ]) == 1

    assert run("nous.profile.check", ["--agent", "NousTest.ProfileFixtures.raising_agent"]) == 2
    assert run("nous.profile.check", ["--agent", "NoSuch.Module.agent", "--profile", path]) == 2
  end

  test "seal writes a profile whose id and manifest validate against the agent", %{tmp_dir: dir} do
    src = Path.join(dir, "draft.json")
    File.write!(src, JSON.encode!(%{"nous_profile" => 1, "components" => F.full_components("S")}))
    out = Path.join(dir, "sealed.json")

    assert run("nous.profile.seal", [
             "--agent",
             "NousTest.ProfileFixtures.agent",
             src,
             "--out",
             out
           ]) ==
             0

    assert {:ok, sealed} = Profile.load(out)
    assert Profile.validate(sealed, F.agent()) == :ok
  end

  test "rebase re-seals a stale profile against the current base text", %{tmp_dir: dir} do
    stale = F.sealed(F.full_components("R"), F.agent())
    path = write_profile(dir, "stale.json", stale)
    out = Path.join(dir, "rebased.json")

    assert run("nous.profile.rebase", [
             "--agent",
             "NousTest.ProfileFixtures.edited_agent",
             path,
             "--out",
             out
           ]) == 0

    assert {:ok, rebased} = Profile.load(out)
    assert Profile.validate(rebased, F.edited_agent()) == :ok
    assert rebased.components == stale.components
    assert rebased.parent_id == stale.id
  end

  test "rebase refuses when a component's target is gone", %{tmp_dir: dir} do
    path = write_profile(dir, "p.json", F.sealed(F.full_components("R"), F.agent()))

    assert run("nous.profile.rebase", ["--agent", "NousTest.ProfileFixtures.toolless_agent", path]) ==
             1
  end

  test "promote appends a label in the store and diff renders two profiles", %{tmp_dir: dir} do
    store_dir = Path.join(dir, "store")
    {:ok, state} = Store.File.init(root: store_dir)
    first = F.sealed(F.full_components("ONE"), F.agent(), %{"name" => "support"})
    second = F.sealed(F.full_components("TWO"), F.agent(), %{"name" => "support"})
    {:ok, _, state} = Store.File.put_profile(state, first)
    {:ok, _, _state} = Store.File.put_profile(state, second)

    spec = "file:" <> store_dir
    assert run("nous.profile.promote", ["--store", spec, "support", "production", first.id]) == 0
    assert run("nous.profile.promote", ["--store", spec, "support", "production", second.id]) == 0

    assert {:ok, %Profile{id: id}} =
             Profiles.fetch({Store.File, [root: store_dir]}, {:label, "support", "production"})

    assert id == second.id

    assert run("nous.profile.diff", [
             "--store",
             spec,
             "--format",
             "markdown",
             first.id,
             "support@production"
           ]) == 0

    report = output()
    assert report =~ "ONE INSTRUCTIONS"
    assert report =~ "TWO INSTRUCTIONS"
  end

  test "bad arguments exit 2 without creating atoms" do
    bad = fn ->
      assert run("nous.profile.diff", ["--format", "no_such_format_xyz", "a.json", "b.json"]) == 2
      assert run("nous.profile.promote", ["support", "production", "1"]) == 2
    end

    # The first call loads modules (and their atoms); only later calls count.
    bad.()
    before = :erlang.system_info(:atom_count)
    bad.()
    assert :erlang.system_info(:atom_count) == before
  end
end

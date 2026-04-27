defmodule Nous.Tools.PathGuardTest do
  use ExUnit.Case, async: false

  alias Nous.Tools.PathGuard

  setup do
    root = Path.join(System.tmp_dir!(), "path_guard_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "ok.txt"), "ok")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, ctx: %{deps: %{workspace_root: root}}}
  end

  describe "validate/2" do
    test "accepts a path inside the workspace", %{root: root, ctx: ctx} do
      assert {:ok, abs} = PathGuard.validate("ok.txt", ctx)
      assert abs == Path.join(root, "ok.txt")
    end

    test "accepts an absolute path inside the workspace", %{root: root, ctx: ctx} do
      assert {:ok, _} = PathGuard.validate(Path.join(root, "ok.txt"), ctx)
    end

    test "rejects ../.. traversal escape", %{ctx: ctx} do
      assert {:error, reason} = PathGuard.validate("../../etc/passwd", ctx)
      assert reason =~ "escapes the workspace"
    end

    test "rejects an absolute path outside the workspace", %{ctx: ctx} do
      assert {:error, reason} = PathGuard.validate("/etc/passwd", ctx)
      assert reason =~ "escapes the workspace"
    end

    test "rejects path containing NUL byte", %{ctx: ctx} do
      assert {:error, "file_path contains a NUL byte"} =
               PathGuard.validate("ok.txt\x00../../etc/passwd", ctx)
    end

    test "rejects non-binary input", %{ctx: ctx} do
      assert {:error, _} = PathGuard.validate(123, ctx)
    end

    test "rejects a symlink whose target escapes the workspace", %{root: root, ctx: ctx} do
      # /etc exists on every Unix test runner; create a symlink to it inside the workspace.
      link = Path.join(root, "evil_link")
      target = "/etc"
      File.ln_s!(target, link)

      assert {:error, reason} = PathGuard.validate("evil_link", ctx)
      assert reason =~ "symlink"
    end

    test "ctx with no workspace_root falls back to cwd" do
      # Should accept current-directory paths by default.
      assert {:ok, _} = PathGuard.validate("mix.exs", %{deps: %{}})
    end
  end
end

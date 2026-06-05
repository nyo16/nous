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
      # validate/2 returns the canonical (symlink-resolved) path, which may
      # differ from Path.join(root, _) on systems where the tmp dir is itself
      # symlinked (e.g. macOS /var -> /private/var). Assert it points at the
      # right file rather than at a literal unresolved path.
      assert Path.basename(abs) == "ok.txt"
      assert File.read!(abs) == "ok"
      assert {:ok, abs} == PathGuard.validate(Path.join(root, "ok.txt"), ctx)
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

    test "rejects an INTERMEDIATE directory symlink that escapes the workspace",
         %{root: root, ctx: ctx} do
      # link -> /etc, accessed as link/hosts. The leaf (`hosts`) is a regular
      # file, not a symlink, so the old leaf-only lstat check missed this.
      File.ln_s!("/etc", Path.join(root, "linkdir"))

      assert {:error, reason} = PathGuard.validate("linkdir/hosts", ctx)
      assert reason =~ "symlink"
    end

    test "allows a symlink that stays inside the workspace", %{root: root, ctx: ctx} do
      File.mkdir_p!(Path.join(root, "real"))
      File.write!(Path.join(root, "real/data.txt"), "x")
      File.ln_s!(Path.join(root, "real"), Path.join(root, "inside_link"))

      assert {:ok, _} = PathGuard.validate("inside_link/data.txt", ctx)
    end

    test "allows creating a new (non-existent) nested file inside the workspace",
         %{ctx: ctx} do
      assert {:ok, _} = PathGuard.validate("newdir/sub/newfile.txt", ctx)
    end
  end
end

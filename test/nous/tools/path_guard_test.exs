defmodule Nous.Tools.PathGuardTest do
  # async: true is safe — each test gets a unique tmp workspace
  # (System.unique_integer) and touches no shared/global state.
  use ExUnit.Case, async: true

  alias Nous.Tools.PathGuard

  # Mirrors @max_symlink_depth in Nous.Tools.PathGuard.
  @resolution_cap 40

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

    test "rejects a symlink cycle instead of resolving forever", %{root: root, ctx: ctx} do
      # a -> b -> a. The depth cap is the only thing between this and an
      # unbounded recursion, and it is what turns a DoS into a readable error.
      File.ln_s!(Path.join(root, "b"), Path.join(root, "a"))
      File.ln_s!(Path.join(root, "a"), Path.join(root, "b"))

      assert {:error, reason} = PathGuard.validate("a", ctx)
      assert reason =~ "symlink loop"
    end

    test "rejects a symlink chain deeper than the resolution cap", %{root: root, ctx: ctx} do
      # The cap counts every resolved component, not just symlink hops, so a
      # chain of @max_symlink_depth + 1 links exceeds it whatever the workspace
      # root's own depth. The chain terminates at a real file inside the
      # workspace, so nothing but the cap can reject it — raising the cap lets
      # this resolve, lowering it to 0 breaks the single-hop test above.
      dir = Path.join(root, "chain")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "target.txt"), "x")

      last =
        Enum.reduce(1..(@resolution_cap + 1), "target.txt", fn i, prev ->
          File.ln_s!(Path.join(dir, prev), Path.join(dir, "l#{i}"))
          "l#{i}"
        end)

      assert {:error, reason} = PathGuard.validate("chain/#{last}", ctx)
      assert reason =~ "symlink loop"
    end
  end

  describe "an unusable :workspace_root" do
    # A charlist, a forgotten `{:ok, path}` unwrap, an atom from a config typo:
    # each used to raise CaseClauseError from inside the guard rather than
    # returning the error tuple every caller already handles.
    @unusable [nil, :atom, ~c"charlist", 123, {:ok, "/tmp"}, ""]

    for value <- @unusable do
      test "#{inspect(value)} is refused, not raised", %{root: root} do
        ctx = %{deps: %{workspace_root: unquote(Macro.escape(value))}}

        assert {:error, reason} = PathGuard.validate(Path.join(root, "ok.txt"), ctx)
        assert reason =~ "workspace root"
        assert reason =~ "is not a non-empty string"
      end
    end

    test "denies a path that WOULD be legal under the cwd fallback" do
      # The distinguishing test: a silent `nil -> File.cwd!()` fallback would
      # accept this, since the path is inside the cwd. Only failing closed
      # rejects it. The second assertion is the control proving the probe bites.
      cwd_path = Path.join(File.cwd!(), "mix.exs")

      assert {:error, reason} = PathGuard.validate(cwd_path, %{deps: %{workspace_root: nil}})
      assert reason =~ "is not a non-empty string"

      assert {:ok, _} = PathGuard.validate(cwd_path, %{deps: %{}})
    end
  end

  describe "effective_root/1" do
    test "expands a configured root", %{root: root} do
      assert PathGuard.effective_root(%{deps: %{workspace_root: root}}) ==
               {:ok, Path.expand(root)}
    end

    test "an ABSENT key still means the cwd - the documented default" do
      assert PathGuard.effective_root(%{deps: %{}}) == {:ok, Path.expand(File.cwd!())}
    end

    test "an unusable value is an error, so a caller deriving a boundary cannot widen it" do
      assert {:error, _} = PathGuard.effective_root(%{deps: %{workspace_root: :nope}})
    end
  end
end

defmodule Nous.Tools.PathGuardTest do
  # async: true is safe — each test gets a unique tmp workspace
  # (System.unique_integer) and touches no shared/global state.
  use ExUnit.Case, async: true

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

  describe "symlink traversal through .." do
    test "<root>/link/.. does not resolve back inside the workspace", %{root: root} do
      # `escape -> /etc`, so the kernel reads `<root>/escape/..` as the parent of
      # the REAL /etc. `Path.expand/1` alone collapses the `..` lexically before
      # the symlink is resolved and lands back in the workspace — exactly the bug
      # resolve_real/1 exists to prevent.
      File.ln_s!("/etc", Path.join(root, "escape"))

      assert {:ok, real_root} = PathGuard.resolve_real(root)
      assert {:ok, real_etc} = PathGuard.resolve_real("/etc")
      # Derived, not hardcoded: on macOS /etc is itself a symlink, so the parent
      # is /private rather than /.
      parent = Path.dirname(real_etc)

      assert PathGuard.resolve_real(Path.join(root, "escape/..")) == {:ok, parent}

      assert PathGuard.resolve_real(Path.join(root, "escape/../passwd")) ==
               {:ok, Path.join(parent, "passwd")}

      refute parent == real_root
      refute String.starts_with?(parent, real_root <> "/")
    end

    test "validate/2 rejects the traversal in every spelling", %{root: root, ctx: ctx} do
      File.ln_s!("/etc", Path.join(root, "escape"))

      assert {:error, reason} = PathGuard.validate("escape/..", ctx)
      assert reason =~ "symlink"

      assert {:error, reason} = PathGuard.validate("escape/../passwd", ctx)
      assert reason =~ "symlink"

      assert {:error, _} = PathGuard.validate(Path.join(root, "escape/../passwd"), ctx)
    end

    test "a benign .. that stays inside the workspace is still allowed", %{root: root, ctx: ctx} do
      File.mkdir_p!(Path.join(root, "sub"))

      assert {:ok, path} = PathGuard.validate("sub/../ok.txt", ctx)
      assert {:ok, real_root} = PathGuard.resolve_real(root)
      assert path == Path.join(real_root, "ok.txt")
      assert File.read!(path) == "ok"
    end

    test "resolve_real/1 applies . and .. to the resolved prefix", %{root: root} do
      assert {:ok, real_root} = PathGuard.resolve_real(root)

      assert PathGuard.resolve_real(Path.join(root, "sub/..")) == {:ok, real_root}

      assert PathGuard.resolve_real(Path.join(root, "./ok.txt")) ==
               {:ok, Path.join(real_root, "ok.txt")}

      # `..` cannot climb above the filesystem root.
      assert PathGuard.resolve_real("/../../..") == {:ok, "/"}
    end

    test "a relative symlink target with .. is resolved, not collapsed",
         %{root: root, ctx: ctx} do
      # `Path.expand/2` would fold `../evil/..` down to the workspace root
      # before `evil` is ever lstat'd; only `Path.absname/2` keeps the `..` for
      # the component-by-component resolver. Absolute targets cannot show the
      # difference — `Path.absname/2` and `Path.expand/2` agree on them — which
      # is why every other symlink test in this tree misses it. Reverting
      # `resolve_real/1` to `Path.expand(target, resolved)` makes the line below
      # answer `{:ok, real_root}`, `validate/2` answer `{:ok, _}`, and a
      # `FileWrite` follow the link straight out of the jail.
      File.mkdir_p!(Path.join(root, "sub"))
      File.ln_s!("/etc", Path.join(root, "evil"))
      File.ln_s!("../evil/..", Path.join(root, "sub/link"))

      assert {:ok, real_etc} = PathGuard.resolve_real("/etc")
      # Derived, not hardcoded: on macOS /etc is a symlink, so the parent is
      # /private rather than /.
      assert PathGuard.resolve_real(Path.join(root, "sub/link")) ==
               {:ok, Path.dirname(real_etc)}

      assert {:error, reason} = PathGuard.validate("sub/link/passwd", ctx)
      assert reason =~ "symlink"
    end
  end

  describe "the symlink budget counts hops, not components" do
    test "a deep symlink-free path resolves instead of reporting a loop", %{root: root} do
      # 45 components, no symlink anywhere. The budget is 40, and it used to be
      # spent by ordinary directories, so this returned {:error, :symlink_loop}
      # — whereupon `Nous.Sandbox.Policy.canonical/1` swallows the error and
      # falls back to the lexical `Path.expand/1` that this resolver exists to
      # avoid. `realpath(3)` counts hops; so does this now.
      deep = Path.join([root | Enum.map(1..45, &"d#{&1}")])
      File.mkdir_p!(deep)

      assert {:ok, real_root} = PathGuard.resolve_real(root)
      assert {:ok, resolved} = PathGuard.resolve_real(deep)
      assert resolved == Path.join([real_root | Enum.map(1..45, &"d#{&1}")])
    end

    test "a deep path still resolves when it is reached through one symlink",
         %{root: root} do
      # One hop plus 45 components: the hop is what the budget is for.
      deep = Path.join([root, "real" | Enum.map(1..45, &"d#{&1}")])
      File.mkdir_p!(deep)
      File.ln_s!(Path.join(root, "real"), Path.join(root, "via_link"))

      assert {:ok, real_root} = PathGuard.resolve_real(root)

      assert PathGuard.resolve_real(Path.join([root, "via_link" | Enum.map(1..45, &"d#{&1}")])) ==
               {:ok, Path.join([real_root, "real" | Enum.map(1..45, &"d#{&1}")])}
    end

    test "loop detection is unchanged: a self-referential symlink is still a loop",
         %{root: root} do
      # The control the hop fix must not break. Without a budget this recurses
      # forever; the fix only stopped charging non-symlink components for it.
      File.ln_s!(Path.join(root, "ouroboros"), Path.join(root, "ouroboros"))

      assert PathGuard.resolve_real(Path.join(root, "ouroboros")) == {:error, :symlink_loop}
    end

    test "a mutual symlink pair is a loop too", %{root: root} do
      File.ln_s!(Path.join(root, "pong"), Path.join(root, "ping"))
      File.ln_s!(Path.join(root, "ping"), Path.join(root, "pong"))

      assert PathGuard.resolve_real(Path.join(root, "ping")) == {:error, :symlink_loop}

      # And validate/2 reports it rather than leaking the raw tuple.
      ctx = %{deps: %{workspace_root: root}}
      assert {:error, reason} = PathGuard.validate("ping", ctx)
      assert reason =~ "symlink loop"
    end
  end
end

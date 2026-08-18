defmodule Nous.Sandbox.PolicyTest do
  # async: false — `default_mode/0` and therefore `new/1` and `resolve/2` read the
  # `:nous, :sandbox_mode` application env, which these tests set.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nous.RunContext
  alias Nous.Sandbox.Policy
  alias Nous.Tools.PathGuard

  doctest Nous.Sandbox.Policy

  setup do
    original_mode = Application.fetch_env(:nous, :sandbox_mode)

    root = Path.join(System.tmp_dir!(), "policy_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)

      case original_mode do
        {:ok, mode} -> Application.put_env(:nous, :sandbox_mode, mode)
        :error -> Application.delete_env(:nous, :sandbox_mode)
      end
    end)

    {:ok, root: root, canonical_root: canonical!(root)}
  end

  describe "modes/0" do
    test "is exactly the three modes, widest confinement first" do
      assert Policy.modes() == [:read_only, :workspace_write, :danger_full_access]
    end
  end

  describe "new/1" do
    test "accepts a bare mode atom", %{root: _root} do
      Application.put_env(:nous, :sandbox_mode, :read_only)

      policy = Policy.new(:workspace_write)
      assert policy.mode == :workspace_write
      assert policy.session_id == nil
      # No :workspace_root given, so the current directory, canonicalised.
      assert policy.workspace_root == canonical!(File.cwd!())
    end

    test "accepts a keyword list, a map, and an existing policy", %{root: root} do
      from_keyword = Policy.new(mode: :read_only, workspace_root: root, session_id: "s-1")
      from_map = Policy.new(%{mode: :read_only, workspace_root: root, session_id: "s-1"})

      assert from_keyword == from_map
      assert from_keyword.session_id == "s-1"
      # Idempotent: re-normalising a policy must not re-derive anything.
      assert Policy.new(from_keyword) == from_keyword
    end

    test "coerces a mode string without ever creating an atom" do
      for {given, expected} <- [
            {"read_only", :read_only},
            {"workspace_write", :workspace_write},
            {"danger_full_access", :danger_full_access}
          ] do
        assert Policy.new(given).mode == expected
        assert Policy.new(mode: given).mode == expected
      end
    end

    test "an unrecognised mode raises and is never turned into an atom" do
      assert_raise ArgumentError, ~r/invalid sandbox mode/, fn ->
        Policy.new(mode: "not_a_real_sandbox_mode")
      end

      assert_raise ArgumentError, ~r/invalid sandbox mode/, fn ->
        Policy.new(:read_write)
      end

      # The security property behind the whitelist: config that may come from an
      # env var must not be able to grow the atom table.
      assert_raise ArgumentError, fn -> String.to_existing_atom("not_a_real_sandbox_mode") end
    end

    test "expands a relative workspace root against the current directory" do
      policy = Policy.new(mode: :read_only, workspace_root: "test/support")

      assert Path.type(policy.workspace_root) == :absolute
      assert policy.workspace_root == canonical!(Path.expand("test/support"))
    end

    test "canonicalises a symlinked workspace root", %{root: root} do
      real = Path.join(root, "real_root")
      File.mkdir_p!(real)
      link = Path.join(root, "link_root")
      File.ln_s!(real, link)

      policy = Policy.new(mode: :workspace_write, workspace_root: link)

      # It matters for enforcement, not tidiness: an SBPL `(subpath ...)` clause
      # naming the link would never match a write the kernel sees at the target.
      assert policy.workspace_root == canonical!(real)
      refute policy.workspace_root == link
    end

    test "leaves a non-existent workspace root alone beyond making it absolute" do
      root = "/nonexistent-nous-policy-#{System.unique_integer([:positive])}/ws"

      assert Policy.new(mode: :workspace_write, workspace_root: root).workspace_root == root
    end

    test "an explicit mode does not consult the application default" do
      # An explicit policy must not depend on unrelated global config: reaching
      # `default_mode/0` anyway both raises on config the caller never asked for
      # and logs a warning claiming subprocesses run unconfined at the exact
      # moment the caller asked for `:read_only`. Since that warning fires once
      # per VM, spending it here can silence the case it exists for.
      Application.put_env(:nous, :sandbox_mode, :not_a_mode)

      assert Policy.new(mode: :read_only).mode == :read_only
      assert Policy.new(:read_only).mode == :read_only
      assert Policy.new(%{mode: :workspace_write}).mode == :workspace_write
    end

    test "a workspace root of / is refused" do
      # `(subpath "/")` under :workspace_write re-allows writes to the entire
      # filesystem — and bwrap's `--bind / /` after `--ro-bind / /` restores
      # read-write on the whole tree — while the %Confined{} still advertises
      # `enforcement: :sandbox_exec` and every log line still says "confined". A
      # fence that silently fences nothing is worse than no fence.
      #
      # This is reachable by ACCIDENT, not only by misconfiguration: the root
      # DEFAULTS to `File.cwd!/0`, so a Nous started from / lands here with no
      # one having configured anything.
      Application.put_env(:nous, :sandbox_mode, :workspace_write)

      assert_raise ArgumentError, ~r/cannot be/, fn -> Policy.new(workspace_root: "/") end

      # Every mode, since a provider handed :danger_full_access still builds a
      # profile, and every entry point, since `resolve/2` funnels into `new/1`.
      for mode <- Policy.modes() do
        assert_raise ArgumentError, ~r/cannot be/, fn ->
          Policy.new(mode: mode, workspace_root: "/")
        end
      end

      assert_raise ArgumentError, ~r/cannot be/, fn ->
        Policy.resolve(nil, workspace_root: "/")
      end

      # A path that CANONICALISES to "/" is refused too: the check is on the
      # resolved root, not on the string the caller happened to pass.
      assert Policy.canonical("/..") == "/"

      assert_raise ArgumentError, ~r/cannot be/, fn ->
        Policy.new(mode: :workspace_write, workspace_root: "/..")
      end

      # Control: a `..` path that does NOT land on "/" is perfectly legal, so the
      # refusals above are about "/" alone and not about rejecting `..`.
      #
      # The fixture is derived, not written literally. `"/tmp/.."` was the obvious
      # choice and is platform-dependent: on Linux it canonicalises to "/" and is
      # therefore correctly refused, while on macOS `/tmp` is a symlink to
      # `/private/tmp` so it lands on `/private`. It tested a different thing on
      # each OS — green on a laptop, red on CI. A path two levels deep inside the
      # system temp dir has a parent that is never "/" on any host.
      nested =
        Path.join([
          System.tmp_dir!(),
          "nous_policy_control_#{System.unique_integer([:positive])}",
          "child"
        ])

      File.mkdir_p!(nested)
      on_exit(fn -> File.rm_rf!(Path.dirname(nested)) end)

      control = Path.join(nested, "..")
      assert Policy.canonical(control) != "/", "control fixture must not resolve to /"
      assert Policy.new(mode: :workspace_write, workspace_root: control).workspace_root != "/"
    end

    test "a workspace root containing a NUL byte is refused" do
      # A NUL truncates the SBPL profile mid-string, which happens to fail
      # closed (`sandbox-exec` exits 65 on the unterminated string) by luck, not
      # design — and the port layer truncates argv at a NUL outright. Reject it
      # explicitly, the way `Nous.Tools.PathGuard` does for paths.
      Application.put_env(:nous, :sandbox_mode, :workspace_write)

      assert_raise ArgumentError, ~r/NUL/, fn ->
        Policy.new(workspace_root: "/tmp/x" <> <<0>> <> "y")
      end

      # Control: the same path without the byte is accepted, so the raise is
      # caused by the NUL and not by the rest of the string.
      assert Policy.new(workspace_root: "/tmp/xy").workspace_root =~ "xy"
    end

    test "a legitimately deep workspace root is canonicalised, not lexically expanded", %{
      root: root
    } do
      # `PathGuard.resolve_real/1`'s budget counts symlink HOPS, not path
      # components. When it counted components, a symlink-free 34-deep path was
      # refused as `{:error, :symlink_loop}` — and `Policy.canonical/1` swallows
      # that error and falls back to the very `Path.expand/1` the resolver
      # exists to avoid. Silently, for exactly the deeply nested checkouts a
      # workspace root points at.
      real = Path.join(root, "real")
      File.mkdir_p!(real)
      link = Path.join(root, "link")
      File.ln_s!(real, link)

      nesting = List.duplicate("d", 45)
      deep = Path.join([link | nesting])
      File.mkdir_p!(deep)
      assert length(Path.split(deep)) > 45

      # The symlinked prefix is what makes this a real assertion on both hosts:
      # `Path.expand/1` keeps `link`, a resolved path names `real`, so the
      # lexical fallback is observably a different string.
      expected = canonical!(Path.join([real | nesting]))
      refute expected == Path.expand(deep)

      assert Policy.new(mode: :workspace_write, workspace_root: deep).workspace_root == expected
    end
  end

  describe "default_mode/0" do
    test "reads the configured mode" do
      Application.put_env(:nous, :sandbox_mode, :workspace_write)
      assert Policy.default_mode() == :workspace_write
    end

    test "coerces a configured string" do
      Application.put_env(:nous, :sandbox_mode, "read_only")
      assert Policy.default_mode() == :read_only
    end

    test "raises on a configured value that is not a mode" do
      Application.put_env(:nous, :sandbox_mode, :yolo)

      assert_raise ArgumentError, ~r/invalid sandbox mode/, fn -> Policy.default_mode() end
    end

    test "falls back to :danger_full_access when unconfigured" do
      Application.delete_env(:nous, :sandbox_mode)

      # The fallback warns once per VM; another test may already have consumed
      # that, so capture the log rather than asserting on it.
      capture_log(fn ->
        assert Policy.default_mode() == :danger_full_access
      end)
    end
  end

  describe "resolve/2 mode precedence" do
    test "an explicit mode beats the session policy and the application default", %{root: root} do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      ctx = ctx_with(Policy.new(mode: :danger_full_access, workspace_root: root))

      assert Policy.resolve(ctx, mode: :read_only).mode == :read_only
    end

    test "the session policy beats the application default", %{root: root} do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      ctx = ctx_with(Policy.new(mode: :read_only, workspace_root: root))

      assert Policy.resolve(ctx).mode == :read_only
    end

    test "the application default applies when nothing overrides it" do
      Application.put_env(:nous, :sandbox_mode, :workspace_write)

      assert Policy.resolve(nil).mode == :workspace_write
      assert Policy.resolve(%{deps: %{}}).mode == :workspace_write
      assert Policy.resolve(RunContext.new(%{})).mode == :workspace_write
    end

    test "a real RunContext carries the session policy on its :sandbox field", %{root: root} do
      Application.put_env(:nous, :sandbox_mode, :danger_full_access)
      session = Policy.new(mode: :read_only, workspace_root: root, session_id: "sess-7")
      ctx = RunContext.new(%{}, sandbox: session)

      resolved = Policy.resolve(ctx)

      assert resolved.mode == :read_only
      assert resolved.workspace_root == canonical!(root)
      assert resolved.session_id == "sess-7"
    end
  end

  describe "resolve/2 workspace root precedence" do
    test "opts beat the session policy, which beats deps, which beats the cwd", %{
      root: root,
      canonical_root: canonical_root
    } do
      Application.put_env(:nous, :sandbox_mode, :workspace_write)

      session_root = Path.join(root, "session")
      deps_root = Path.join(root, "deps")
      opts_root = Path.join(root, "opts")
      Enum.each([session_root, deps_root, opts_root], &File.mkdir_p!/1)

      ctx = %{
        sandbox: Policy.new(mode: :workspace_write, workspace_root: session_root),
        deps: %{workspace_root: deps_root}
      }

      assert Policy.resolve(ctx, workspace_root: opts_root).workspace_root ==
               canonical!(opts_root)

      assert Policy.resolve(ctx).workspace_root == canonical!(session_root)

      assert Policy.resolve(%{deps: %{workspace_root: deps_root}}).workspace_root ==
               canonical!(deps_root)

      assert Policy.resolve(%{deps: %{}}).workspace_root == canonical!(File.cwd!())
      assert Policy.resolve(nil).workspace_root == canonical!(File.cwd!())

      # `deps[:workspace_root]` is where Nous.Tools.PathGuard reads it from too,
      # so the fence and the sandbox agree on the root by construction.
      assert Policy.resolve(RunContext.new(%{workspace_root: root})).workspace_root ==
               canonical_root
    end
  end

  describe "resolve/2 session id" do
    test "opts beat the session policy, which beats deps" do
      Application.put_env(:nous, :sandbox_mode, :read_only)
      ctx = %{sandbox: Policy.new(session_id: "from-session"), deps: %{session_id: "from-deps"}}

      assert Policy.resolve(ctx, session_id: "from-opts").session_id == "from-opts"
      assert Policy.resolve(ctx).session_id == "from-session"
      assert Policy.resolve(%{deps: %{session_id: "from-deps"}}).session_id == "from-deps"
      assert Policy.resolve(%{deps: %{}}).session_id == nil
    end
  end

  describe "canonical/1" do
    test "resolves symlinked components and leaves canonical paths alone", %{root: root} do
      target = Path.join(root, "target")
      File.mkdir_p!(target)
      File.ln_s!(target, Path.join(root, "link"))

      canonical_target = canonical!(target)

      assert Policy.canonical(Path.join(root, "link")) == canonical_target
      assert Policy.canonical(canonical_target) == canonical_target
    end
  end

  # ---------------------------------------------------------------------------

  defp ctx_with(%Policy{} = policy), do: %{sandbox: policy, deps: %{}}

  defp canonical!(path) do
    assert {:ok, real} = PathGuard.resolve_real(path)
    real
  end
end

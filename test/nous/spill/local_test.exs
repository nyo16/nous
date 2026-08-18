defmodule Nous.Spill.LocalTest do
  # async: true — every test writes under its own unique tmp root and touches no
  # application env or other global state.
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Nous.Spill.Local
  alias Nous.Spill.Locator

  setup do
    root = Path.join(System.tmp_dir!(), "spill_local_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp save(root, attrs) do
    Local.save_text(
      Map.merge(
        %{
          owner: "session-abc",
          source: "file_grep",
          suggested_name: "grep-results.txt",
          content: "hello",
          opts: [root: root]
        },
        attrs
      )
    )
  end

  describe "save_text/1 and fetch/1" do
    test "round-trips small content and reports its size", %{root: root} do
      assert {:ok, %Locator{} = locator} = save(root, %{content: "hello world"})

      assert locator.store == Local
      assert locator.bytes == 11
      assert locator.name == "grep-results.txt"
      assert {:ok, "hello world"} = Local.fetch(locator)
    end

    test "round-trips a multi-megabyte payload byte for byte", %{root: root} do
      # Line-shaped, like the grep/bash output this exists for, and well past
      # any single-read buffer.
      big = String.duplicate("0123456789abcdef\n", 250_000)
      assert byte_size(big) > 4_000_000

      assert {:ok, locator} = save(root, %{content: big})
      assert locator.bytes == byte_size(big)
      assert {:ok, read_back} = Local.fetch(locator)
      assert read_back == big
    end

    test "round-trips multibyte UTF-8 without re-encoding", %{root: root} do
      content = String.duplicate("héllo → κόσμος 😀\n", 1_000)

      assert {:ok, locator} = save(root, %{content: content})
      # bytes is a BYTE count, not a character count: the whole point of the
      # locator is telling the caller what the context would have cost.
      assert locator.bytes == byte_size(content)
      assert locator.bytes > String.length(content)
      assert {:ok, ^content} = Local.fetch(locator)
    end

    test "fetch/1 errors instead of raising when the operator deleted the file", %{root: root} do
      assert {:ok, locator} = save(root, %{})
      File.rm!(locator.id)

      assert {:error, :enoent} = Local.fetch(locator)
    end
  end

  describe "path layout" do
    test "is <root>/session-<sha256_hex(owner)>/<random>-<name>", %{root: root} do
      assert {:ok, locator} = save(root, %{owner: "session-abc"})

      digest = :crypto.hash(:sha256, "session-abc") |> Base.encode16(case: :lower)
      dir = Path.join(root, "session-" <> digest)

      assert Path.dirname(locator.id) == dir
      assert Path.basename(locator.id) =~ ~r/^[A-Za-z0-9_-]{12}-grep-results\.txt$/
      assert File.exists?(locator.id)
    end

    test "hashes the owner rather than using it raw", %{root: root} do
      # A session id with a separator in it must not steer the write: the digest
      # is the only thing that reaches the path.
      assert {:ok, locator} = save(root, %{owner: "../../../etc"})

      assert Path.dirname(locator.id) =~ ~r|/session-[0-9a-f]{64}$|
      refute locator.id =~ "etc/"
      assert Path.expand(locator.id) == locator.id
    end

    test "different owners get different session directories", %{root: root} do
      assert {:ok, a} = save(root, %{owner: "session-a"})
      assert {:ok, b} = save(root, %{owner: "session-b"})

      refute Path.dirname(a.id) == Path.dirname(b.id)
    end

    test "the same owner reuses one session directory", %{root: root} do
      assert {:ok, a} = save(root, %{owner: "session-a"})
      assert {:ok, b} = save(root, %{owner: "session-a", suggested_name: "other.txt"})

      assert Path.dirname(a.id) == Path.dirname(b.id)
      assert [_one] = File.ls!(root)
    end

    test "two saves with the same owner and name do not collide", %{root: root} do
      assert {:ok, a} = save(root, %{content: "first"})
      assert {:ok, b} = save(root, %{content: "second"})

      refute a.id == b.id
      assert {:ok, "first"} = Local.fetch(a)
      assert {:ok, "second"} = Local.fetch(b)
      assert length(File.ls!(Path.dirname(a.id))) == 2
    end
  end

  describe "permissions" do
    test "the file is 0600 and its session directory is 0700", %{root: root} do
      assert {:ok, locator} = save(root, %{content: "secret output"})

      assert band(File.stat!(locator.id).mode, 0o777) == 0o600
      assert band(File.stat!(Path.dirname(locator.id)).mode, 0o777) == 0o700
    end
  end

  describe "suggested_name sanitisation" do
    for {label, name} <- [
          {"traversal", "../../etc/passwd"},
          {"separator", "a/b"},
          {"whitespace only", " "},
          {"empty", ""},
          {"absolute", "/etc/shadow"},
          {"dotfile", ".ssh-config"},
          {"nul byte and shell metacharacters", "a\0b;rm -rf /"},
          {"300 characters", String.duplicate("n", 300)}
        ] do
      test "a #{label} name stays inside the session directory", %{root: root} do
        assert {:ok, locator} = save(root, %{suggested_name: unquote(name)})

        dir = Path.dirname(locator.id)
        base = Path.basename(locator.id)

        # Assert on the RESOLVED path, not just the name: a traversal component
        # that survived sanitisation would expand out of the session directory
        # even when the basename looks harmless.
        assert Path.expand(locator.id) == locator.id
        assert String.starts_with?(locator.id, root <> "/")
        assert dir =~ ~r|/session-[0-9a-f]{64}$|
        assert Path.dirname(dir) == root

        refute base =~ "/"
        refute base =~ ".."
        refute String.starts_with?(locator.name, ".")
        assert byte_size(locator.name) <= 64
        assert File.exists?(locator.id)
      end
    end

    test "a name with nothing salvageable falls back to result.txt", %{root: root} do
      assert {:ok, locator} = save(root, %{suggested_name: "  "})
      assert locator.name == "result.txt"

      assert {:ok, locator} = save(root, %{suggested_name: nil})
      assert locator.name == "result.txt"
    end

    test "a long name is capped but keeps its readable prefix", %{root: root} do
      assert {:ok, locator} = save(root, %{suggested_name: String.duplicate("ab", 200)})

      assert byte_size(locator.name) == 64
      assert String.starts_with?(locator.name, "abab")
    end
  end

  describe "failure paths" do
    test "a root that is a regular file returns an error and does not raise", %{root: root} do
      File.mkdir_p!(Path.dirname(root))
      File.write!(root, "not a directory")

      assert {:error, reason} = save(root, %{})
      assert reason in [:enotdir, :eexist]
    end

    test "a non-string :root is an error, not an exception" do
      attrs = %{
        owner: "session-a",
        source: "file_read",
        suggested_name: "x.txt",
        content: "y",
        opts: [root: :not_a_path]
      }

      assert {:error, {:invalid_root, :not_a_path}} = Local.save_text(attrs)
    end

    test "a read-only root returns an error and does not raise", %{root: root} do
      File.mkdir_p!(root)
      locked = Path.join(root, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod(locked, 0o700) end)

      case File.touch(Path.join(locked, "probe")) do
        {:error, :eacces} ->
          assert {:error, _reason} = save(locked, %{})

        :ok ->
          # A privileged uid ignores mode bits, so there is no fence to assert
          # on here. The regular-file root above covers the failure path in a
          # uid-independent way.
          File.rm!(Path.join(locked, "probe"))
      end
    end

    test "exclusive create refuses a planted symlink instead of following it", %{root: root} do
      # save_text/1 picks an unguessable random component, so no real call can
      # be aimed at a planted link; what this pins is the primitive that makes
      # that unguessability non-load-bearing — the exact open flags save_text/1
      # uses must fail on an existing symlink rather than truncate its target.
      File.mkdir_p!(root)
      victim = Path.join(root, "victim.txt")
      File.write!(victim, "untouched")
      link = Path.join(root, "planted")
      :ok = File.ln_s(victim, link)

      assert {:error, :eexist} = File.open(link, [:write, :exclusive, :binary])
      assert File.read!(victim) == "untouched"
    end
  end

  describe "default root" do
    test "falls back to a nous-spill directory under the system tmp dir" do
      attrs = %{
        owner: "default-root-#{System.unique_integer([:positive])}",
        source: "file_read",
        suggested_name: "x.txt",
        content: "y",
        opts: []
      }

      assert {:ok, locator} = Local.save_text(attrs)
      on_exit(fn -> File.rm_rf!(Path.dirname(locator.id)) end)

      assert Path.dirname(Path.dirname(locator.id)) ==
               Path.join(System.tmp_dir!(), "nous-spill")
    end
  end

  describe "retrieval_hint/1" do
    test "names the concrete path and the tool that opens it", %{root: root} do
      assert {:ok, locator} = save(root, %{})

      hint = Local.retrieval_hint(locator)

      assert hint =~ locator.id
      assert hint =~ "file_read"
      assert String.ends_with?(hint, ".")
    end
  end
end

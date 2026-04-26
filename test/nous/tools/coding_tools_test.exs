defmodule Nous.Tools.CodingToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.{Bash, FileRead, FileWrite, FileEdit, FileGlob, FileGrep}

  # Shared test context
  @test_dir System.tmp_dir!()
            |> Path.join("nous_coding_tools_test_#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@test_dir)

    File.write!(
      Path.join(@test_dir, "hello.txt"),
      "Hello World\nThis is line 2\nGoodbye World\n"
    )

    File.write!(
      Path.join(@test_dir, "sample.ex"),
      "defmodule Sample do\n  def greet, do: :hello\nend\n"
    )

    File.mkdir_p!(Path.join(@test_dir, "nested"))
    File.write!(Path.join(@test_dir, "nested/deep.txt"), "deep content\n")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  # All file tools now require an in-workspace path; tests scope the workspace
  # to the same tmp dir they create fixtures under.
  defp ctx, do: Nous.RunContext.new(%{workspace_root: @test_dir})

  # -- Bash --

  describe "Bash" do
    test "metadata" do
      meta = Bash.metadata()
      assert meta.name == "bash"
      assert meta.category == :execute
      assert meta.requires_approval == true
    end

    test "executes echo command" do
      assert {:ok, output} = Bash.execute(ctx(), %{"command" => "echo hello"})
      assert String.trim(output) == "hello"
    end

    test "returns non-zero exit code output" do
      assert {:ok, output} = Bash.execute(ctx(), %{"command" => "exit 42"})
      assert output =~ "Exit code: 42"
    end

    test "timeout returns error" do
      assert {:error, msg} = Bash.execute(ctx(), %{"command" => "sleep 10", "timeout" => 100})
      assert msg =~ "timed out"
    end
  end

  # -- FileRead --

  describe "FileRead" do
    test "metadata" do
      meta = FileRead.metadata()
      assert meta.name == "file_read"
      assert meta.category == :read
      assert meta.requires_approval == false
    end

    test "reads a file with line numbers" do
      path = Path.join(@test_dir, "hello.txt")
      assert {:ok, output} = FileRead.execute(ctx(), %{"file_path" => path})
      assert output =~ "1\tHello World"
      assert output =~ "2\tThis is line 2"
    end

    test "respects offset and limit" do
      path = Path.join(@test_dir, "hello.txt")

      assert {:ok, output} =
               FileRead.execute(ctx(), %{"file_path" => path, "offset" => 2, "limit" => 1})

      assert output == "2\tThis is line 2"
    end

    test "returns error for missing file" do
      # Use an in-workspace nonexistent path so PathGuard accepts it and we
      # fall through to File.read's error.
      assert {:error, msg} = FileRead.execute(ctx(), %{"file_path" => "no_such_file.txt"})
      assert msg =~ "Failed to read"
    end

    test "rejects path outside workspace root" do
      assert {:error, msg} = FileRead.execute(ctx(), %{"file_path" => "/etc/passwd"})
      assert msg =~ "escapes the workspace"
    end
  end

  # -- FileWrite --

  describe "FileWrite" do
    test "metadata" do
      meta = FileWrite.metadata()
      assert meta.name == "file_write"
      assert meta.category == :write
      assert meta.requires_approval == true
    end

    test "writes a file" do
      path = Path.join(@test_dir, "new_file.txt")

      assert {:ok, msg} =
               FileWrite.execute(ctx(), %{"file_path" => path, "content" => "test content"})

      assert msg =~ "Wrote"
      assert File.read!(path) == "test content"
      File.rm!(path)
    end

    test "creates parent directories" do
      path = Path.join(@test_dir, "new_dir/sub/file.txt")
      assert {:ok, _} = FileWrite.execute(ctx(), %{"file_path" => path, "content" => "deep"})
      assert File.read!(path) == "deep"
      File.rm_rf!(Path.join(@test_dir, "new_dir"))
    end
  end

  # -- FileEdit --

  describe "FileEdit" do
    test "metadata" do
      meta = FileEdit.metadata()
      assert meta.name == "file_edit"
      assert meta.category == :write
      assert meta.requires_approval == true
    end

    test "replaces unique string" do
      path = Path.join(@test_dir, "edit_test.txt")
      File.write!(path, "Hello World\nThis is unique\nGoodbye\n")

      assert {:ok, msg} =
               FileEdit.execute(ctx(), %{
                 "file_path" => path,
                 "old_string" => "This is unique",
                 "new_string" => "This was replaced"
               })

      assert msg =~ "Edited"
      assert File.read!(path) =~ "This was replaced"
      File.rm!(path)
    end

    test "fails on non-unique string without replace_all" do
      path = Path.join(@test_dir, "edit_dup.txt")
      File.write!(path, "World World World")

      assert {:error, msg} =
               FileEdit.execute(ctx(), %{
                 "file_path" => path,
                 "old_string" => "World",
                 "new_string" => "Earth"
               })

      assert msg =~ "found 3 times"
      File.rm!(path)
    end

    test "replace_all replaces all occurrences" do
      path = Path.join(@test_dir, "edit_all.txt")
      File.write!(path, "World World World")

      assert {:ok, _} =
               FileEdit.execute(ctx(), %{
                 "file_path" => path,
                 "old_string" => "World",
                 "new_string" => "Earth",
                 "replace_all" => true
               })

      assert File.read!(path) == "Earth Earth Earth"
      File.rm!(path)
    end

    test "fails when old_string not found" do
      path = Path.join(@test_dir, "hello.txt")

      assert {:error, msg} =
               FileEdit.execute(ctx(), %{
                 "file_path" => path,
                 "old_string" => "NONEXISTENT",
                 "new_string" => "replacement"
               })

      assert msg =~ "not found"
    end
  end

  # -- FileGlob --

  describe "FileGlob" do
    test "metadata" do
      meta = FileGlob.metadata()
      assert meta.name == "file_glob"
      assert meta.category == :search
      assert meta.requires_approval == false
    end

    test "finds files matching pattern" do
      assert {:ok, output} =
               FileGlob.execute(ctx(), %{"pattern" => "**/*.txt", "path" => @test_dir})

      assert output =~ "hello.txt"
      assert output =~ "deep.txt"
    end

    test "finds .ex files" do
      assert {:ok, output} =
               FileGlob.execute(ctx(), %{"pattern" => "*.ex", "path" => @test_dir})

      assert output =~ "sample.ex"
    end

    test "returns message when no matches" do
      assert {:ok, output} =
               FileGlob.execute(ctx(), %{"pattern" => "*.xyz", "path" => @test_dir})

      assert output =~ "No files matched"
    end
  end

  # -- FileGrep --

  describe "FileGrep" do
    test "metadata" do
      meta = FileGrep.metadata()
      assert meta.name == "file_grep"
      assert meta.category == :search
      assert meta.requires_approval == false
    end

    test "finds files with matches" do
      assert {:ok, output} =
               FileGrep.execute(ctx(), %{"pattern" => "defmodule", "path" => @test_dir})

      assert output =~ "sample.ex"
    end

    test "content mode shows line numbers" do
      assert {:ok, output} =
               FileGrep.execute(ctx(), %{
                 "pattern" => "Hello",
                 "path" => @test_dir,
                 "output_mode" => "content"
               })

      assert output =~ ":1:"
      assert output =~ "Hello World"
    end

    test "count mode shows match counts" do
      assert {:ok, output} =
               FileGrep.execute(ctx(), %{
                 "pattern" => "World",
                 "path" => Path.join(@test_dir, "hello.txt"),
                 "output_mode" => "count"
               })

      # rg returns just "2" for a single file, Elixir fallback returns "path:2"
      assert output =~ "2"
    end

    test "returns no matches message" do
      assert {:ok, output} =
               FileGrep.execute(ctx(), %{
                 "pattern" => "ZZZZZZNONEXISTENT",
                 "path" => @test_dir
               })

      assert output =~ "No matches"
    end

    test "returns error for invalid regex" do
      result = FileGrep.execute(ctx(), %{"pattern" => "[invalid", "path" => @test_dir})

      # rg returns its own error format, Elixir fallback returns "Invalid regex"
      case result do
        {:error, msg} -> assert msg =~ "regex" or msg =~ "Invalid"
        _ -> flunk("Expected {:error, _} but got #{inspect(result)}")
      end
    end
  end
end

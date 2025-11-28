defmodule Coderex.Tools.FileToolsTest do
  use ExUnit.Case
  alias Coderex.Tools.FileTools

  setup do
    # Create a temporary directory for each test
    tmp_dir = Path.join(System.tmp_dir!(), "coderex_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(tmp_dir)

    # Create a mock context
    ctx = %{deps: %{cwd: tmp_dir}}

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, ctx: ctx, tmp_dir: tmp_dir}
  end

  describe "read_file/2" do
    test "reads existing file", %{ctx: ctx, tmp_dir: tmp_dir} do
      # Create a test file
      test_file = Path.join(tmp_dir, "test.txt")
      File.write!(test_file, "hello world")

      result = FileTools.read_file(ctx, %{"path" => "test.txt"})

      assert result.content == "hello world"
      assert result.path == "test.txt"
      assert result.lines == 1
    end

    test "returns error for non-existent file", %{ctx: ctx} do
      result = FileTools.read_file(ctx, %{"path" => "nonexistent.txt"})
      assert result.error =~ "not found"
    end
  end

  describe "write_file/2" do
    test "creates new file", %{ctx: ctx, tmp_dir: tmp_dir} do
      result = FileTools.write_file(ctx, %{
        "path" => "new_file.txt",
        "content" => "new content"
      })

      assert result.success == true
      assert result.bytes_written == 11

      # Verify file exists
      assert File.read!(Path.join(tmp_dir, "new_file.txt")) == "new content"
    end

    test "creates directories as needed", %{ctx: ctx, tmp_dir: tmp_dir} do
      result = FileTools.write_file(ctx, %{
        "path" => "subdir/nested/file.txt",
        "content" => "nested content"
      })

      assert result.success == true
      assert File.exists?(Path.join(tmp_dir, "subdir/nested/file.txt"))
    end
  end

  describe "edit_file/2" do
    test "applies diff to file", %{ctx: ctx, tmp_dir: tmp_dir} do
      # Create original file
      test_file = Path.join(tmp_dir, "edit_me.txt")
      File.write!(test_file, "hello world")

      diff = """
      ------- SEARCH
      hello world
      =======
      hello universe
      +++++++ REPLACE
      """

      result = FileTools.edit_file(ctx, %{"path" => "edit_me.txt", "diff" => diff})

      assert result.success == true
      assert result.diff_output != nil
      assert result.diff_output =~ "edit_me.txt"

      # Verify the change
      new_content = File.read!(test_file)
      assert new_content =~ "hello universe"
    end

    test "returns error for non-existent file", %{ctx: ctx} do
      diff = """
      ------- SEARCH
      something
      =======
      other
      +++++++ REPLACE
      """

      result = FileTools.edit_file(ctx, %{"path" => "nonexistent.txt", "diff" => diff})
      assert result.error =~ "not found"
    end
  end

  describe "list_files/2" do
    test "lists files in directory", %{ctx: ctx, tmp_dir: tmp_dir} do
      # Create some test files
      File.write!(Path.join(tmp_dir, "file1.txt"), "")
      File.write!(Path.join(tmp_dir, "file2.txt"), "")
      File.write!(Path.join(tmp_dir, "file3.ex"), "")

      result = FileTools.list_files(ctx, %{})

      assert result.count == 3
      assert "file1.txt" in result.files
      assert "file2.txt" in result.files
      assert "file3.ex" in result.files
    end

    test "filters by pattern", %{ctx: ctx, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "")
      File.write!(Path.join(tmp_dir, "file2.ex"), "")

      result = FileTools.list_files(ctx, %{"pattern" => "*.ex"})

      assert result.count == 1
      assert "file2.ex" in result.files
    end

    test "recursive listing", %{ctx: ctx, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(tmp_dir, "subdir/nested.txt"), "")

      result = FileTools.list_files(ctx, %{"recursive" => true})

      assert result.count == 2
    end
  end

  describe "search_files/2" do
    test "finds pattern in files", %{ctx: ctx, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "hello world\nfoo bar")
      File.write!(Path.join(tmp_dir, "file2.txt"), "baz qux\nhello again")

      result = FileTools.search_files(ctx, %{"pattern" => "hello"})

      assert result.count == 2
      assert Enum.any?(result.results, fn r -> r.file == "file1.txt" end)
      assert Enum.any?(result.results, fn r -> r.file == "file2.txt" end)
    end

    test "limits results", %{ctx: ctx, tmp_dir: tmp_dir} do
      # Create file with many matches
      content = Enum.map(1..100, fn i -> "line #{i} match" end) |> Enum.join("\n")
      File.write!(Path.join(tmp_dir, "many.txt"), content)

      result = FileTools.search_files(ctx, %{"pattern" => "match", "max_results" => 10})

      assert result.count == 10
      assert result.truncated == true
    end
  end

  describe "file_info/2" do
    test "returns info for existing file", %{ctx: ctx, tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "info_test.txt")
      File.write!(test_file, "hello")

      result = FileTools.file_info(ctx, %{"path" => "info_test.txt"})

      assert result.exists == true
      assert result.type == :regular
      assert result.size == 5
    end

    test "returns exists: false for non-existent file", %{ctx: ctx} do
      result = FileTools.file_info(ctx, %{"path" => "nonexistent.txt"})
      assert result.exists == false
    end
  end

  describe "create_directory/2" do
    test "creates directory", %{ctx: ctx, tmp_dir: tmp_dir} do
      result = FileTools.create_directory(ctx, %{"path" => "new_dir"})

      assert result.success == true
      assert File.dir?(Path.join(tmp_dir, "new_dir"))
    end

    test "creates nested directories", %{ctx: ctx, tmp_dir: tmp_dir} do
      result = FileTools.create_directory(ctx, %{"path" => "a/b/c"})

      assert result.success == true
      assert File.dir?(Path.join(tmp_dir, "a/b/c"))
    end
  end

  describe "delete_file/2" do
    test "deletes existing file", %{ctx: ctx, tmp_dir: tmp_dir} do
      test_file = Path.join(tmp_dir, "to_delete.txt")
      File.write!(test_file, "delete me")

      result = FileTools.delete_file(ctx, %{"path" => "to_delete.txt"})

      assert result.success == true
      refute File.exists?(test_file)
    end

    test "returns error for non-existent file", %{ctx: ctx} do
      result = FileTools.delete_file(ctx, %{"path" => "nonexistent.txt"})
      assert result.error =~ "not found"
    end
  end
end

defmodule Nous.Tools.FileReadTest do
  # async: true is safe — every test gets its own `@tag :tmp_dir` workspace.
  use ExUnit.Case, async: true

  alias Nous.Tools.FileRead

  @moduletag :tmp_dir

  # 80-byte lines: 5 + 8 + 66 + 1. Line N is self-describing so a window
  # assertion can check both the number the tool printed and the content it
  # attached to it.
  @line_bytes 80

  setup %{tmp_dir: tmp_dir} do
    {:ok, ctx: Nous.RunContext.new(%{workspace_root: tmp_dir})}
  end

  defp write_lines!(path, count) do
    File.write!(path, Enum.map(1..count, &line/1))
  end

  defp line(n) do
    "line-" <>
      String.pad_leading(Integer.to_string(n), 8, "0") <> String.duplicate("x", 66) <> "\n"
  end

  # The pre-streaming implementation, kept as the byte-for-byte oracle.
  defp reference(content, offset, limit) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.drop(offset - 1)
    |> Enum.take(limit)
    |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
    |> Enum.join("\n")
  end

  describe "rendering" do
    test "is byte-identical to the whole-file implementation", %{ctx: ctx, tmp_dir: dir} do
      chunk = 64 * 1024

      fixtures = [
        "Hello World\nThis is line 2\nGoodbye World\n",
        "no trailing newline\nsecond",
        "",
        "\n",
        "crlf\r\nlines\r\n",
        "single line",
        # A line that spans the read chunk boundary must be reassembled...
        String.duplicate("a", chunk + 10) <> "\nb\n",
        # ...and a newline landing exactly on the boundary must not double up.
        String.duplicate("a", chunk - 1) <> "\n" <> String.duplicate("b", chunk - 1) <> "\nc"
      ]

      for {content, i} <- Enum.with_index(fixtures),
          {offset, limit} <- [{1, 2000}, {2, 1}, {1, 0}] do
        path = Path.join(dir, "fixture_#{i}.txt")
        File.write!(path, content)

        assert {:ok, output} =
                 FileRead.execute(ctx, %{
                   "file_path" => path,
                   "offset" => offset,
                   "limit" => limit
                 })

        assert output == reference(content, offset, limit),
               "fixture #{inspect(content)} offset=#{offset} limit=#{limit}"
      end
    end

    test "respects offset and limit", %{ctx: ctx, tmp_dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "Hello World\nThis is line 2\nGoodbye World\n")

      assert {:ok, "2\tThis is line 2"} =
               FileRead.execute(ctx, %{"file_path" => path, "offset" => 2, "limit" => 1})
    end

    test "an offset past EOF yields an empty result, not an error", %{ctx: ctx, tmp_dir: dir} do
      path = Path.join(dir, "short.txt")
      File.write!(path, "one\ntwo\n")

      assert {:ok, ""} = FileRead.execute(ctx, %{"file_path" => path, "offset" => 50})
    end
  end

  describe "large files" do
    test "streams a 2000-line window out of an 8 MB file", %{ctx: ctx, tmp_dir: dir} do
      path = Path.join(dir, "big.txt")
      count = div(8_000_000, @line_bytes)
      write_lines!(path, count)

      {micros, result} =
        :timer.tc(fn -> FileRead.execute(ctx, %{"file_path" => path, "limit" => 2000}) end)

      assert {:ok, output} = result
      lines = String.split(output, "\n")
      assert length(lines) == 2000
      assert hd(lines) == "1\t" <> String.trim_trailing(line(1), "\n")
      assert List.last(lines) == "2000\t" <> String.trim_trailing(line(2000), "\n")

      # Coarse regression guard only: the real guarantee is that the window is
      # taken from File.stream!/2 so the file is never held in memory whole.
      # Reading 160 KB out of 8 MB has no business taking anywhere near this.
      assert micros < 2_000_000, "window read took #{div(micros, 1000)} ms"
    end

    test "a window deep into the file is numbered from the file start", %{ctx: ctx, tmp_dir: dir} do
      path = Path.join(dir, "deep.txt")
      write_lines!(path, 50_000)

      assert {:ok, output} =
               FileRead.execute(ctx, %{"file_path" => path, "offset" => 49_999, "limit" => 3})

      # Line 50_001 is the trailing "" the terminator-split leaves behind.
      assert output ==
               "49999\t" <>
                 String.trim_trailing(line(49_999), "\n") <>
                 "\n50000\t" <> String.trim_trailing(line(50_000), "\n") <> "\n50001\t"
    end

    test "refuses a file over the 10 MB cap and names the cap", %{ctx: ctx, tmp_dir: dir} do
      path = Path.join(dir, "huge.txt")
      count = div(12_000_000, @line_bytes)
      write_lines!(path, count)

      assert {:error, msg} = FileRead.execute(ctx, %{"file_path" => path, "limit" => 1})
      assert msg =~ "10 MB cap"
      assert msg =~ "#{count * @line_bytes} bytes"
    end
  end

  describe "errors" do
    test "missing file", %{ctx: ctx} do
      assert {:error, msg} = FileRead.execute(ctx, %{"file_path" => "no_such_file.txt"})
      assert msg =~ "Failed to read"
    end

    test "directory", %{ctx: ctx, tmp_dir: dir} do
      assert {:error, msg} = FileRead.execute(ctx, %{"file_path" => dir})
      assert msg =~ "Failed to read"
      assert msg =~ "eisdir"
    end

    test "path outside the workspace is rejected before any stat", %{ctx: ctx} do
      assert {:error, msg} = FileRead.execute(ctx, %{"file_path" => "/etc/passwd"})
      assert msg =~ "escapes the workspace"
    end
  end
end

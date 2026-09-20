defmodule Nous.Tools.FileGrepTest do
  # `async: false`: the fallback-engine tests below force the pure-Elixir path
  # by overriding the VM-global rg memo in `:persistent_term`. ExUnit runs sync
  # modules after every async module has finished, so nothing else observes it.
  use ExUnit.Case, async: false

  alias Nous.Tools.FileGrep

  @moduletag :tmp_dir

  @cap 1_000_000
  @marker "\n\n[Output truncated at #{@cap} bytes]"
  @limit 250

  @rg_available not is_nil(System.find_executable("rg"))

  defp ctx(root), do: Nous.RunContext.new(%{workspace_root: root})

  # 30 files x 250 matching lines x ~200 bytes: rg's per-file `--max-count`
  # still lets all 250 lines per file through, so the raw output is ~1.5 MB.
  @line String.duplicate("needle ", 28)
  defp write_big_fixture(root) do
    body = String.duplicate(@line <> "\n", 250)
    for i <- 1..30, do: File.write!(Path.join(root, "big_#{i}.txt"), body)
  end

  defp assert_capped_on_line_boundary(output) do
    assert byte_size(output) <= @cap + byte_size(@marker)
    assert String.ends_with?(output, @marker)

    body = String.replace_suffix(output, @marker, "")
    lines = String.split(body, "\n")
    assert length(lines) > 1

    # Every surviving line is a complete `path:line:text` record — nothing was
    # cut mid-line, so the model never sees a torn path or a half sentence.
    for line <- lines do
      assert [_path, num, text] = String.split(line, ":", parts: 3)
      assert String.to_integer(num) in 1..250
      assert text == @line
    end
  end

  defp force_fallback do
    :persistent_term.put({FileGrep, :rg_path}, nil)
    on_exit(fn -> :persistent_term.erase({FileGrep, :rg_path}) end)
  end

  if @rg_available do
    describe "rg engine" do
      test "caps content output at the byte ceiling on a line boundary", %{tmp_dir: root} do
        write_big_fixture(root)

        assert {:ok, output} =
                 FileGrep.execute(ctx(root), %{
                   "pattern" => "needle",
                   "path" => root,
                   "output_mode" => "content"
                 })

        assert_capped_on_line_boundary(output)
      end
    end
  end

  describe "fallback engine" do
    setup do
      force_fallback()
      :ok
    end

    test "caps content output at the byte ceiling on a line boundary", %{tmp_dir: root} do
      # The fallback stops at @limit lines, so cross the cap with long lines:
      # 250 lines x ~5 KB.
      long = String.duplicate("needle ", 700)
      File.write!(Path.join(root, "long.txt"), String.duplicate(long <> "\n", 300))

      assert {:ok, output} =
               FileGrep.execute(ctx(root), %{
                 "pattern" => "needle",
                 "path" => root,
                 "output_mode" => "content"
               })

      assert byte_size(output) <= @cap + byte_size(@marker)
      assert String.ends_with?(output, @marker)

      body = String.replace_suffix(output, @marker, "")

      for line <- String.split(body, "\n") do
        assert [_path, _num, text] = String.split(line, ":", parts: 3)
        assert text == long
      end
    end

    test "never searches build output, deps, node_modules, or hidden dirs", %{tmp_dir: root} do
      for dir <- ~w(_build deps node_modules .git lib) do
        File.mkdir_p!(Path.join(root, dir))
        File.write!(Path.join([root, dir, "x.ex"]), "needle\n")
      end

      assert {:ok, output} = FileGrep.execute(ctx(root), %{"pattern" => "needle", "path" => root})

      assert output == Path.join([root, "lib", "x.ex"])
    end

    test "stops at the result limit", %{tmp_dir: root} do
      for i <- 1..(@limit + 5), do: File.write!(Path.join(root, "m_#{i}.txt"), "needle\n")

      assert {:ok, output} = FileGrep.execute(ctx(root), %{"pattern" => "needle", "path" => root})

      assert length(String.split(output, "\n")) == @limit
    end

    test "content mode limit spans files and keeps whole lines", %{tmp_dir: root} do
      # 3 files x 100 matches = 300 candidate lines; only @limit come back, in
      # walk order, so the third file is cut partway through.
      for i <- 1..3 do
        File.write!(Path.join(root, "c_#{i}.txt"), String.duplicate("needle\n", 100))
      end

      assert {:ok, output} =
               FileGrep.execute(ctx(root), %{
                 "pattern" => "needle",
                 "path" => root,
                 "output_mode" => "content"
               })

      lines = String.split(output, "\n")
      assert length(lines) == @limit
      assert List.last(lines) == Path.join(root, "c_3.txt") <> ":50:needle"
    end

    test "skips files over the per-file size cap", %{tmp_dir: root} do
      File.write!(Path.join(root, "huge.log"), String.duplicate("needle\n", 1_600_000))
      File.write!(Path.join(root, "small.log"), "needle\n")

      assert {:ok, output} = FileGrep.execute(ctx(root), %{"pattern" => "needle", "path" => root})

      assert output == Path.join(root, "small.log")
    end

    test "glob keeps Path.wildcard semantics relative to the search root", %{tmp_dir: root} do
      File.write!(Path.join(root, "top.ex"), "needle\n")
      File.mkdir_p!(Path.join(root, "nested"))
      File.write!(Path.join(root, "nested/deep.ex"), "needle\n")
      File.write!(Path.join(root, "nested/deep.txt"), "needle\n")

      grep = fn glob ->
        {:ok, output} =
          FileGrep.execute(ctx(root), %{"pattern" => "needle", "path" => root, "glob" => glob})

        output |> String.split("\n") |> Enum.map(&Path.relative_to(&1, root)) |> Enum.sort()
      end

      assert grep.("*.ex") == ["top.ex"]
      assert grep.("**/*.ex") == ["nested/deep.ex", "top.ex"]
      assert grep.("**/*.{ex,txt}") == ["nested/deep.ex", "nested/deep.txt", "top.ex"]
      assert grep.("--debug") == ["No matches found"]
    end

    test "searches an explicit file target through the workspace check", %{tmp_dir: root} do
      file = Path.join(root, "one.txt")
      File.write!(file, "a\nneedle\nc\n")

      assert {:ok, output} =
               FileGrep.execute(ctx(root), %{
                 "pattern" => "needle",
                 "path" => file,
                 "output_mode" => "count"
               })

      assert output == file <> ":1"
    end
  end
end

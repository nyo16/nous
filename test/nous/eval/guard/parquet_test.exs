if Code.ensure_loaded?(Nous.Eval.Guard.Parquet) do
  defmodule Nous.Eval.Guard.ParquetTest do
    use ExUnit.Case, async: true

    alias Nous.Eval.Guard.Parquet

    @moduletag :duckdb

    defp parquet_body do
      dir = Path.join(System.tmp_dir!(), "nous_pq_src_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "fixture.parquet")
      {:ok, db} = Duckdbex.open()
      {:ok, conn} = Duckdbex.connection(db)

      {:ok, _} =
        Duckdbex.query(
          conn,
          "COPY (SELECT * FROM (VALUES ('hello', 1)) t(text, label)) TO '#{path}' (FORMAT PARQUET)"
        )

      File.read!(path)
    end

    test "reads rows from a temp root whose path contains a single quote, and cleans up" do
      root = Path.join(System.tmp_dir!(), "nous_o'quote_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      assert {:ok, [%{"text" => "hello", "label" => 1}]} = Parquet.rows(parquet_body(), root)
      assert File.ls!(root) == []
    end

    test "an unreadable body is an error and leaves nothing behind" do
      root = Path.join(System.tmp_dir!(), "nous_pq_bad_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      assert {:error, "parquet read failed: " <> _} = Parquet.rows("not parquet", root)
      assert File.ls!(root) == []
    end
  end
end

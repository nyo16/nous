if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Eval.Guard.Parquet do
    @moduledoc false
    # Parquet rows for registry sources, read with the optional `:duckdbex`
    # dependency from an in-memory database. The body was checksummed before
    # it reaches here.

    @spec rows(binary(), Path.t()) :: {:ok, [map()]} | {:error, String.t()}
    def rows(body, tmp_root \\ System.tmp_dir!()) when is_binary(body) do
      # A private, randomly named directory (0700) so no other local user can
      # pre-create, swap or read the file; the file itself is created
      # exclusively.
      dir =
        Path.join(tmp_root, "nous_guard_" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))

      path = Path.join(dir, "data.parquet")

      try do
        with :ok <- File.mkdir(dir),
             :ok <- File.chmod(dir, 0o700),
             :ok <- File.write(path, body, [:exclusive]) do
          query(path)
        else
          {:error, reason} -> {:error, "parquet temp file failed: #{inspect(reason)}"}
        end
      after
        File.rm_rf(dir)
      end
    end

    defp query(path) do
      # A table function takes no prepared parameters, so the path is
      # inlined as an SQL string literal with `'` doubled.
      literal = "'" <> String.replace(path, "'", "''") <> "'"

      with {:ok, db} <- Duckdbex.open(),
           {:ok, conn} <- Duckdbex.connection(db),
           {:ok, result} <- Duckdbex.query(conn, "SELECT * FROM read_parquet(#{literal})") do
        columns = Duckdbex.columns(result)
        {:ok, Enum.map(Duckdbex.fetch_all(result), &Map.new(Enum.zip(columns, &1)))}
      else
        {:error, reason} -> {:error, "parquet read failed: #{inspect(reason)}"}
      end
    end
  end
end

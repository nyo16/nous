if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Eval.Guard.Parquet do
    @moduledoc false
    # Parquet rows for registry sources, read with the optional `:duckdbex`
    # dependency from an in-memory database. The body was checksummed before
    # it reaches here.

    @spec rows(binary()) :: {:ok, [map()]} | {:error, String.t()}
    def rows(body) when is_binary(body) do
      path =
        Path.join(System.tmp_dir!(), "nous_guard_#{System.unique_integer([:positive])}.parquet")

      try do
        File.write!(path, body)

        # A table function takes no prepared parameters; the path is our own
        # temp file name (digits only), so it is safe to inline.
        with {:ok, db} <- Duckdbex.open(),
             {:ok, conn} <- Duckdbex.connection(db),
             {:ok, result} <- Duckdbex.query(conn, "SELECT * FROM read_parquet('#{path}')") do
          columns = Duckdbex.columns(result)
          {:ok, Enum.map(Duckdbex.fetch_all(result), &Map.new(Enum.zip(columns, &1)))}
        else
          {:error, reason} -> {:error, "parquet read failed: #{inspect(reason)}"}
        end
      after
        File.rm(path)
      end
    end
  end
end

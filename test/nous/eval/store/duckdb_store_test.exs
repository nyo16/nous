if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Eval.Store.DuckDBConformanceTest do
    @moduledoc false
    use Nous.Eval.Store.Conformance,
      store: Nous.Eval.Store.DuckDB,
      tmp_dir: {:path, "eval.duckdb"},
      tag: :duckdb
  end

  defmodule Nous.Eval.Store.DuckDBTest do
    use ExUnit.Case, async: true

    @moduletag :duckdb

    alias Nous.Eval.Store.{Conformance, DuckDB}

    test "get_run/2 refuses a payload written by a newer schema version" do
      {:ok, state} = DuckDB.init([])
      {:ok, state} = DuckDB.put_run(state, Conformance.run_fixture("run-future"))

      {:ok, _} =
        Duckdbex.query(
          state.conn,
          ~s|UPDATE nous_eval_runs SET payload = replace(payload, '"schema_version":1,', '"schema_version":99,')|
        )

      assert {:error, {:unsupported_schema_version, 99}} = DuckDB.get_run(state, "run-future")
    end
  end
end

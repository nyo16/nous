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

    test "a profile whose stored text was edited is refused by every ref" do
      {:ok, state} = DuckDB.init([])
      profile = Conformance.profile_fixture("support_agent", "a")
      {:ok, _, state} = DuckDB.put_profile(state, profile)
      {:ok, state} = DuckDB.put_profile_label(state, "support_agent", "production", profile.id)

      {:ok, _} =
        Duckdbex.query(
          state.conn,
          "UPDATE nous_eval_profiles SET payload = replace(payload, 'Never quote', 'Always quote')"
        )

      for ref <- [
            {:id, profile.id},
            {:version, "support_agent", 1},
            {:label, "support_agent", "production"}
          ] do
        assert {:error, %Nous.Errors.ProfileError{reason: :id_mismatch}} =
                 DuckDB.get_profile(state, ref)

        assert {:error, %Nous.Errors.ProfileError{reason: :id_mismatch}} =
                 Nous.Eval.Profiles.fetch(DuckDB, state, ref)
      end

      assert {:error, %Nous.Errors.ProfileError{reason: :id_mismatch}} =
               DuckDB.list_profiles(state, "support_agent")
    end
  end
end

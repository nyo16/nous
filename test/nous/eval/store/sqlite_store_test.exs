if Code.ensure_loaded?(Exqlite) do
  defmodule Nous.Eval.Store.SQLiteConformanceTest do
    @moduledoc false
    use Nous.Eval.Store.Conformance,
      store: Nous.Eval.Store.SQLite,
      tmp_dir: {:path, "eval.sqlite3"},
      tag: :sqlite
  end

  defmodule Nous.Eval.Store.SQLiteTest do
    use ExUnit.Case, async: true

    @moduletag :sqlite

    alias Exqlite.Sqlite3
    alias Nous.Eval.Store.{Conformance, SQLite}

    test "get_run/2 refuses a payload written by a newer schema version" do
      {:ok, conn} = SQLite.init([])
      {:ok, conn} = SQLite.put_run(conn, Conformance.run_fixture("run-future"))

      {:ok, stmt} =
        Sqlite3.prepare(
          conn,
          "UPDATE nous_eval_runs SET payload = json_set(payload, '$.schema_version', 99)"
        )

      :done = Sqlite3.step(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)

      assert {:error, {:unsupported_schema_version, 99}} = SQLite.get_run(conn, "run-future")
    end

    test "a profile whose stored text was edited is refused by every ref" do
      {:ok, conn} = SQLite.init([])
      profile = Conformance.profile_fixture("support_agent", "a")
      {:ok, _, conn} = SQLite.put_profile(conn, profile)
      {:ok, conn} = SQLite.put_profile_label(conn, "support_agent", "production", profile.id)

      {:ok, stmt} =
        Sqlite3.prepare(
          conn,
          "UPDATE nous_eval_profiles SET payload = replace(payload, 'Never quote', 'Always quote')"
        )

      :done = Sqlite3.step(conn, stmt)
      :ok = Sqlite3.release(conn, stmt)

      for ref <- [
            {:id, profile.id},
            {:version, "support_agent", 1},
            {:label, "support_agent", "production"}
          ] do
        assert {:error, %Nous.Errors.ProfileError{reason: :id_mismatch}} =
                 SQLite.get_profile(conn, ref)

        assert {:error, %Nous.Errors.ProfileError{reason: :id_mismatch}} =
                 Nous.Eval.Profiles.fetch(SQLite, conn, ref)
      end

      assert {:error, %Nous.Errors.ProfileError{reason: :id_mismatch}} =
               SQLite.list_profiles(conn, "support_agent")
    end
  end
end

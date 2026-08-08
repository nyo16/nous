if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Memory.Store.DuckDBTest do
    use ExUnit.Case, async: true

    @moduletag :duckdb

    alias Nous.Memory.Entry
    alias Nous.Memory.Store.DuckDB

    setup do
      {:ok, state} = DuckDB.init([])
      %{state: state}
    end

    describe "decoding a corrupt persisted row" do
      test "an unknown type yields nil rather than raising", %{state: state} do
        now = DateTime.to_iso8601(DateTime.utc_now())

        insert = """
        INSERT INTO memories (id, content, type, created_at, updated_at, last_accessed_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """

        {:ok, _} =
          Duckdbex.query(state.conn, insert, [
            "corrupt-entry",
            "hello",
            "no_such_memory_type_xyz",
            now,
            now,
            now
          ])

        assert {:ok, fetched} = DuckDB.fetch(state, "corrupt-entry")
        assert fetched.type == nil
        assert fetched.content == "hello"
      end

      test "every declared memory type still roundtrips", %{state: state} do
        for type <- [:semantic, :episodic, :procedural] do
          entry = Entry.new(%{content: "note", type: type})
          {:ok, _state} = DuckDB.store(state, entry)

          assert {:ok, fetched} = DuckDB.fetch(state, entry.id)
          assert fetched.type == type
        end
      end
    end
  end
else
  # Without this branch the file compiles to nothing, and a file that compiles
  # to nothing is indistinguishable from a passing one in `mix test` output.
  # The placeholder turns that silence into a counted, named skip. The reason
  # lives in the test NAME because the default formatter prints the `skip:`
  # tag's value nowhere — not even under --trace.
  #
  # The column allowlist is covered unconditionally by
  # `test/nous/memory/store/duckdb_columns_test.exs`.
  defmodule Nous.Memory.Store.DuckDBTest do
    use ExUnit.Case, async: true

    @tag skip: "Duckdbex not available"
    test "memory DuckDB store suite skipped: uncomment {:duckdbex, \"~> 0.3\"} in mix.exs to run it" do
      flunk("tagged skip; this body must never execute")
    end
  end
end

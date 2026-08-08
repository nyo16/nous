defmodule Nous.Decisions.Store.DuckDB.ColumnsTest do
  use ExUnit.Case, async: true

  # Deliberately NOT gated on `Code.ensure_loaded?(Duckdbex)`. The store itself
  # is, and `duckdbex` is not installed in CI, so this is the only place the
  # P5-T3 SQL-identifier control is exercised by `mix test`.
  alias Nous.Decisions.Store.DuckDB.Columns

  describe "fetch!/1" do
    test "an injected identifier raises instead of becoming a column name" do
      assert_raise ArgumentError, ~r/unknown decision column/, fn ->
        Columns.fetch!("id; DROP TABLE decision_nodes --")
      end
    end

    test "a plausible-but-wrong field name raises" do
      # `node_type` is the physical column, not the Node field — close enough to
      # slip past review, still not a key of the allowlist.
      assert_raise ArgumentError, ~r/unknown decision column :node_type/, fn ->
        Columns.fetch!(:node_type)
      end
    end

    test "the error names the allowlist so the caller can see what is legal" do
      error = assert_raise ArgumentError, fn -> Columns.fetch!(:nope) end

      for field <- Map.keys(Columns.column_map()) do
        assert error.message =~ inspect(field)
      end
    end

    test "every allowlisted field maps to its decision_nodes column" do
      assert Columns.column_map() == %{
               id: "id",
               type: "node_type",
               label: "label",
               status: "status",
               confidence: "confidence",
               rationale: "rationale",
               metadata: "metadata_json",
               created_at: "created_at",
               updated_at: "updated_at"
             }

      for {field, column} <- Columns.column_map() do
        assert Columns.fetch!(field) == column
      end
    end

    # The allowlist is interpolated into SQL, so every value must be a bare
    # identifier: no quoting, no whitespace, no comment or statement delimiter.
    test "no allowlisted column name can carry SQL syntax" do
      for column <- Map.values(Columns.column_map()) do
        assert column =~ ~r/^[a-z_]+$/
      end
    end
  end

  describe "validate!/1" do
    test "accepts an update map built only from allowlisted fields" do
      updates = Map.new(Map.keys(Columns.column_map()), &{&1, nil})
      assert Columns.validate!(updates) == :ok
    end

    test "rejects the whole update when any single key is unknown" do
      assert_raise ArgumentError, ~r/unknown decision column/, fn ->
        Columns.validate!(%{"1=1 --" => "not fine", label: "fine"})
      end
    end

    test "an empty update map is accepted" do
      assert Columns.validate!(%{}) == :ok
    end
  end
end

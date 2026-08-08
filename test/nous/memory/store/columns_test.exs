defmodule Nous.Memory.Store.ColumnsTest do
  use ExUnit.Case, async: true

  # Deliberately NOT gated on `Code.ensure_loaded?(Exqlite)` /
  # `Code.ensure_loaded?(Duckdbex)`. Both memory stores are, and `duckdbex` is
  # not installed at all, so this is the only place the SQL-identifier control
  # from the 2026-06 audit (P1-T3, P5-T3) is exercised by `mix test`.
  #
  # This replaces the two per-store column suites: the SQLite and DuckDB
  # allowlists were byte-identical clones kept in step by a drift-detecting
  # assertion, and are now one module, so there is nothing left to drift.
  alias Nous.Decisions.Store.DuckDB.Columns, as: DecisionColumns
  alias Nous.Memory.Entry
  alias Nous.Memory.Store.Columns

  # Spelled out rather than derived from the module: a literal is the only thing
  # that notices a field being silently added to or dropped from the allowlist.
  @entry_columns %{
    id: "id",
    content: "content",
    type: "type",
    importance: "importance",
    evergreen: "evergreen",
    embedding: "embedding",
    agent_id: "agent_id",
    session_id: "session_id",
    user_id: "user_id",
    namespace: "namespace",
    metadata: "metadata_json",
    access_count: "access_count",
    created_at: "created_at",
    updated_at: "updated_at",
    last_accessed_at: "last_accessed_at"
  }

  describe "fetch!/1" do
    test "an injected identifier raises instead of becoming a column name" do
      assert_raise ArgumentError, ~r/unknown memory column/, fn ->
        Columns.fetch!("id; DROP TABLE memories --")
      end
    end

    test "a plausible-but-wrong field name raises" do
      # `metadata_json` is the physical column; the Entry field is `:metadata`.
      assert_raise ArgumentError, ~r/unknown memory column :metadata_json/, fn ->
        Columns.fetch!(:metadata_json)
      end
    end

    test "every allowlisted field maps to its memories column" do
      assert Columns.column_map() == @entry_columns

      for {field, column} <- @entry_columns do
        assert Columns.fetch!(field) == column
      end
    end

    test "every Entry field the stores persist is allowlisted" do
      # `struct(entry, updates)` is how both stores apply an update, so any
      # Entry field absent here can never be written — and any field here that
      # Entry does not have would build a SET clause for a value of `nil`.
      persisted = Map.keys(Map.from_struct(%Entry{}))
      assert Enum.sort(Map.keys(@entry_columns)) == Enum.sort(persisted)
    end

    # The allowlist is interpolated into SQL, so every value must be a bare
    # identifier: no quoting, no whitespace, no comment or statement delimiter.
    test "no allowlisted column name can carry SQL syntax" do
      for column <- Map.values(Columns.column_map()) do
        assert column =~ ~r/^[a-z_]+$/
      end
    end

    # The memory and decisions allowlists address different tables; one shared
    # map would let either domain write the other's columns. `refute mem_map ==
    # dec_map` used to stand here and could never fail — the key sets differ, so
    # `==` is false by construction. Deriving the exclusive fields from the two
    # maps is no better: "fields only in B are unknown to A" is true by
    # definition of the difference. The fields have to be named for the check to
    # bite.
    test "neither allowlist resolves the other table's exclusive fields" do
      for field <- [:node_type, :label, :status, :confidence, :rationale] do
        assert_raise ArgumentError, ~r/unknown memory column/, fn -> Columns.fetch!(field) end
      end

      for field <- [:content, :importance, :evergreen, :embedding, :access_count] do
        assert_raise ArgumentError, ~r/unknown decision column/, fn ->
          DecisionColumns.fetch!(field)
        end
      end

      # `:type` is in both allowlists and must keep resolving per-table. This is
      # the assertion that stops a future reader merging the two maps.
      assert Columns.fetch!(:type) == "type"
      assert DecisionColumns.fetch!(:type) == "node_type"
    end
  end

  describe "validate!/1" do
    test "accepts an update map built only from allowlisted fields" do
      updates = Map.new(Map.keys(@entry_columns), &{&1, nil})
      assert Columns.validate!(updates) == :ok
    end

    test "rejects the whole update when any single key is unknown" do
      assert_raise ArgumentError, ~r/unknown memory column/, fn ->
        Columns.validate!(%{"1=1 --" => "not fine", content: "fine"})
      end
    end

    test "an empty update map is accepted" do
      assert Columns.validate!(%{}) == :ok
    end
  end
end

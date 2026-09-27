if Code.ensure_loaded?(Duckdbex) do
  defmodule Nous.Memory.Store.DuckDBConformanceTest do
    @moduledoc false
    # Ran nowhere before duckdbex became a declared optional dep (audit D-M2).
    use Nous.Memory.Store.Conformance, store: Nous.Memory.Store.DuckDB, tag: :duckdb
  end

  defmodule Nous.Memory.Store.DuckDBVectorTest do
    use ExUnit.Case, async: true

    @moduletag :duckdb

    alias Nous.Memory.Entry
    alias Nous.Memory.Store.DuckDB

    setup do
      {:ok, state} = DuckDB.init([])
      %{state: state}
    end

    test "search_vector/3 ranks by cosine similarity and applies scope and limit", %{state: state} do
      near = Entry.new(%{content: "near", embedding: [1.0, 0.0], user_id: "u1"})
      far = Entry.new(%{content: "far", embedding: [0.0, 1.0], user_id: "u1"})
      other = Entry.new(%{content: "other user", embedding: [1.0, 0.0], user_id: "u2"})

      state =
        Enum.reduce([near, far, other], state, fn e, acc ->
          {:ok, acc} = DuckDB.store(acc, e)
          acc
        end)

      assert {:ok, [{top, top_score}, {second, second_score}]} =
               DuckDB.search_vector(state, [1.0, 0.0], scope: %{user_id: "u1"}, limit: 10)

      assert top.id == near.id
      assert second.id == far.id
      assert top_score > second_score

      assert {:ok, [{only, _}]} = DuckDB.search_vector(state, [1.0, 0.0], limit: 1)
      assert only.id in [near.id, other.id]
    end
  end
end

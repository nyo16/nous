if Code.ensure_loaded?(Exqlite) do
  defmodule Nous.Memory.Store.SQLiteConformanceTest do
    @moduledoc false
    # Ran nowhere before exqlite became a declared optional dep (audit D-M2):
    # the module was an `if Code.ensure_loaded?` ghost. First run surfaced a
    # removed exqlite API (`Sqlite3.bind/3` -> `bind/2`).
    use Nous.Memory.Store.Conformance, store: Nous.Memory.Store.SQLite, tag: :sqlite
  end

  defmodule Nous.Memory.Store.SQLiteVectorTest do
    use ExUnit.Case, async: true

    @moduletag :sqlite

    alias Nous.Memory.Entry
    alias Nous.Memory.Store.SQLite

    setup do
      {:ok, state} = SQLite.init([])
      %{state: state}
    end

    test "search_vector/3 ranks by cosine similarity and applies scope and limit", %{state: state} do
      near = Entry.new(%{content: "near", embedding: [1.0, 0.0], user_id: "u1"})
      far = Entry.new(%{content: "far", embedding: [0.0, 1.0], user_id: "u1"})
      other = Entry.new(%{content: "other user", embedding: [1.0, 0.0], user_id: "u2"})

      state =
        Enum.reduce([near, far, other], state, fn e, acc ->
          {:ok, acc} = SQLite.store(acc, e)
          acc
        end)

      assert {:ok, [{top, top_score}, {second, second_score}]} =
               SQLite.search_vector(state, [1.0, 0.0], scope: %{user_id: "u1"}, limit: 10)

      assert top.id == near.id
      assert second.id == far.id
      assert top_score > second_score

      assert {:ok, [{only, _}]} = SQLite.search_vector(state, [1.0, 0.0], limit: 1)
      assert only.id in [near.id, other.id]
    end
  end
end

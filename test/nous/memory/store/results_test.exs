defmodule Nous.Memory.Store.ResultsTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Entry
  alias Nous.Memory.Store.Results

  setup do
    table = :ets.new(:results_test, [:set, :public])
    {:ok, table: table}
  end

  defp put(table, id, attrs \\ %{}) do
    entry = Entry.new(Map.merge(%{id: id, content: id}, attrs))
    :ets.insert(table, {id, entry})
    entry
  end

  defp entry(attrs), do: Entry.new(Map.merge(%{content: "c"}, attrs))

  defp hit(id, score), do: %{id: id, score: score}

  describe "rank/5" do
    test "hydrates hit ids from the ETS side table", %{table: table} do
      put(table, "a", %{content: "alpha"})
      put(table, "b", %{content: "beta"})

      assert [{first, 0.9}, {second, 0.4}] =
               Results.rank([hit("a", 0.9), hit("b", 0.4)], table, %{}, 0.0, 10)

      assert first.content == "alpha"
      assert second.content == "beta"
    end

    test "drops hits whose entry is no longer in the table", %{table: table} do
      put(table, "a")

      # The search index and the entries table are written separately, so an
      # indexed id can outlive the row it points at.
      assert [{entry, 0.9}] = Results.rank([hit("a", 0.9), hit("gone", 0.8)], table, %{}, 0.0, 10)
      assert entry.id == "a"
    end

    test "filters scored results by scope instead of raising", %{table: table} do
      put(table, "mine", %{agent_id: "agent-1"})
      put(table, "theirs", %{agent_id: "agent-2"})

      # Regression: each store's private filter_by_scope/2 guarded its
      # bare-entry clause on is_list/1, which a list of {entry, score} pairs
      # also satisfies. The scored clause below it was therefore dead and
      # every scoped search raised BadMapError from Map.get/2 on a tuple.
      assert [{entry, 0.5}] =
               Results.rank(
                 [hit("mine", 0.5), hit("theirs", 0.9)],
                 table,
                 %{agent_id: "agent-1"},
                 0.0,
                 10
               )

      assert entry.id == "mine"
    end

    test "requires every scope key to match", %{table: table} do
      put(table, "a", %{agent_id: "agent-1", session_id: "s1"})
      put(table, "b", %{agent_id: "agent-1", session_id: "s2"})

      scope = %{agent_id: "agent-1", session_id: "s2"}

      assert [{entry, _}] = Results.rank([hit("a", 0.9), hit("b", 0.1)], table, scope, 0.0, 10)
      assert entry.id == "b"
    end

    test "excludes scores at the minimum, not just below it", %{table: table} do
      put(table, "at")
      put(table, "above")

      assert [{entry, 0.51}] =
               Results.rank([hit("at", 0.5), hit("above", 0.51)], table, %{}, 0.5, 10)

      assert entry.id == "above"
    end

    test "sorts by score descending before truncating to the limit", %{table: table} do
      for id <- ~w(low high mid), do: put(table, id)

      assert [{first, 0.9}, {second, 0.5}] =
               Results.rank(
                 [hit("low", 0.1), hit("high", 0.9), hit("mid", 0.5)],
                 table,
                 %{},
                 0.0,
                 2
               )

      assert first.id == "high"
      assert second.id == "mid"
    end

    test "applies the scope before the limit so in-scope hits are not crowded out", %{
      table: table
    } do
      put(table, "loud", %{agent_id: "other"})
      put(table, "quiet", %{agent_id: "mine"})

      assert [{entry, 0.2}] =
               Results.rank(
                 [hit("loud", 0.99), hit("quiet", 0.2)],
                 table,
                 %{agent_id: "mine"},
                 0.0,
                 1
               )

      assert entry.id == "quiet"
    end
  end

  describe "filter_by_scope/2" do
    test "returns the list untouched for an empty scope" do
      entries = [entry(%{content: "a"}), entry(%{content: "b"})]
      assert Results.filter_by_scope(entries, %{}) == entries
    end

    test "matches bare entries on every scope key" do
      mine = entry(%{user_id: "u1"})
      theirs = entry(%{user_id: "u2"})

      assert Results.filter_by_scope([mine, theirs], %{user_id: "u1"}) == [mine]
    end

    test "matches scored pairs on the entry, not the tuple" do
      mine = entry(%{user_id: "u1"})
      theirs = entry(%{user_id: "u2"})

      assert Results.filter_by_scope([{mine, 0.1}, {theirs, 0.9}], %{user_id: "u1"}) ==
               [{mine, 0.1}]
    end

    test "a scope key that is not an Entry field matches nothing" do
      assert Results.filter_by_scope([entry(%{})], %{not_a_field: "x"}) == []
    end
  end

  describe "all_entries/1" do
    test "returns the stored entries without their keys", %{table: table} do
      a = put(table, "a")
      b = put(table, "b")

      assert Enum.sort_by(Results.all_entries(table), & &1.id) == [a, b]
    end

    test "is empty for an empty table", %{table: table} do
      assert Results.all_entries(table) == []
    end
  end
end

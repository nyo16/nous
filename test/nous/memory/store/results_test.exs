defmodule Nous.Memory.Store.ResultsTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Entry
  alias Nous.Memory.Store.Results

  # Public, pure, and the module behind the #76 BadMapError fix — but its only
  # in-repo callers are the optional SQLite/DuckDB stores, so nothing exercised
  # it. These pin the contract an external Nous.Memory.Store relies on.

  defp entry(id, attrs \\ []) do
    Entry.new(Map.merge(%{id: id, content: "entry #{id}"}, Map.new(attrs)))
  end

  defp table(entries) do
    tab = :ets.new(:results_test, [:set, :public])
    for e <- entries, do: :ets.insert(tab, {e.id, e})
    tab
  end

  describe "filter_by_scope/2" do
    test "an empty scope keeps everything, in either shape" do
      entries = [entry("a"), entry("b")]
      scored = [{entry("a"), 0.9}, {entry("b"), 0.1}]

      assert Results.filter_by_scope(entries, %{}) == entries
      assert Results.filter_by_scope(scored, %{}) == scored
    end

    test "keeps only entries matching every scope key" do
      entries = [
        entry("a", user_id: "u1", agent_id: "ag1"),
        entry("b", user_id: "u1", agent_id: "ag2"),
        entry("c", user_id: "u2", agent_id: "ag1")
      ]

      assert Results.filter_by_scope(entries, %{user_id: "u1"}) |> Enum.map(& &1.id) == ["a", "b"]

      assert Results.filter_by_scope(entries, %{user_id: "u1", agent_id: "ag1"})
             |> Enum.map(& &1.id) == ["a"]
    end

    test "the scored shape is dispatched per element (the clause that used to raise)" do
      # Pre-#76 the scored clause was shadowed by an is_list/1 guard, so a
      # scoped vector/full-text search hit Map.get/2 on a tuple: BadMapError.
      scored = [
        {entry("a", user_id: "u1"), 0.9},
        {entry("b", user_id: "u2"), 0.8}
      ]

      assert [{%Entry{id: "a"}, 0.9}] = Results.filter_by_scope(scored, %{user_id: "u1"})
    end
  end

  describe "rank/5" do
    test "hydrates hits from the table, drops ids with no row, orders by score desc" do
      tab = table([entry("a"), entry("b"), entry("c")])

      hits = [
        %{id: "b", score: 0.5},
        %{id: "ghost", score: 0.99},
        %{id: "a", score: 0.9},
        %{id: "c", score: 0.7}
      ]

      assert Results.rank(hits, tab, %{}, 0.0, 10) |> Enum.map(fn {e, s} -> {e.id, s} end) ==
               [{"a", 0.9}, {"c", 0.7}, {"b", 0.5}]
    end

    test "min_score is exclusive and limit truncates after sorting" do
      tab = table([entry("a"), entry("b"), entry("c"), entry("d")])

      hits = [
        %{id: "a", score: 0.2},
        %{id: "b", score: 0.9},
        %{id: "c", score: 0.5},
        %{id: "d", score: 0.7}
      ]

      # 0.5 is NOT > 0.5, so "c" is cut; then the top 2 of the survivors.
      assert Results.rank(hits, tab, %{}, 0.5, 2) |> Enum.map(fn {e, _} -> e.id end) ==
               ["b", "d"]
    end

    test "scope is applied to the hydrated entries before min_score and limit" do
      tab =
        table([entry("a", user_id: "u1"), entry("b", user_id: "u2"), entry("c", user_id: "u1")])

      hits = [%{id: "b", score: 0.9}, %{id: "a", score: 0.4}, %{id: "c", score: 0.3}]

      # "b" is the best hit but out of scope; the limit of 1 must apply to
      # what survives, not hand back an empty list because the top hit was cut.
      assert [{%Entry{id: "a"}, 0.4}] = Results.rank(hits, tab, %{user_id: "u1"}, 0.0, 1)
    end

    test "equal scores keep their hit order (sort is stable)" do
      tab = table([entry("a"), entry("b"), entry("c")])
      hits = [%{id: "c", score: 0.5}, %{id: "a", score: 0.5}, %{id: "b", score: 0.5}]

      assert Results.rank(hits, tab, %{}, 0.0, 10) |> Enum.map(fn {e, _} -> e.id end) ==
               ["c", "a", "b"]
    end
  end

  describe "all_entries/1" do
    test "returns every entry, unordered, without ids" do
      tab = table([entry("a"), entry("b")])

      assert Results.all_entries(tab) |> Enum.map(& &1.id) |> Enum.sort() == ["a", "b"]
    end
  end
end

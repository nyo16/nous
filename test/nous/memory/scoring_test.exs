defmodule Nous.Memory.ScoringTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Entry
  alias Nous.Memory.Scoring

  defp make_entry(id, opts \\ %{}) do
    now = DateTime.utc_now()

    Entry.new(
      Map.merge(
        %{
          id: id,
          content: "entry #{id}",
          last_accessed_at: now,
          created_at: now,
          updated_at: now
        },
        opts
      )
    )
  end

  describe "rrf_merge/3" do
    test "merges two ranked lists" do
      a = make_entry("a")
      b = make_entry("b")
      c = make_entry("c")

      list_a = [{a, 0.9}, {b, 0.7}]
      list_b = [{c, 0.8}, {a, 0.6}]

      merged = Scoring.rrf_merge(list_a, list_b)

      # "a" appears in both lists, so it should have the highest RRF score
      {top, _score} = hd(merged)
      assert top.id == "a"
      assert length(merged) == 3
    end

    test "handles overlapping entries" do
      a = make_entry("a")
      b = make_entry("b")

      list_a = [{a, 0.9}, {b, 0.5}]
      list_b = [{b, 0.8}, {a, 0.4}]

      merged = Scoring.rrf_merge(list_a, list_b)

      assert length(merged) == 2
      # Both entries appear in both lists with the same ranks, so scores should be equal
      [{_, score_1}, {_, score_2}] = merged
      assert_in_delta score_1, score_2, 0.0001
    end

    test "handles empty lists" do
      a = make_entry("a")

      assert Scoring.rrf_merge([], []) == []
      assert length(Scoring.rrf_merge([{a, 0.9}], [])) == 1
      assert length(Scoring.rrf_merge([], [{a, 0.9}])) == 1
    end
  end

  describe "temporal_decay/3" do
    test "returns original score for evergreen entries" do
      entry = make_entry("e", %{evergreen: true})
      assert Scoring.temporal_decay(0.8, entry, []) == 0.8
    end

    test "reduces score over time" do
      past = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
      entry = make_entry("old", %{last_accessed_at: past})

      now = DateTime.utc_now()
      decayed = Scoring.temporal_decay(1.0, entry, now: now)

      assert decayed < 1.0
      assert decayed > 0.0
    end

    test "recent entries have minimal decay" do
      entry = make_entry("recent")
      decayed = Scoring.temporal_decay(1.0, entry, [])

      # Just created, so decay should be negligible
      assert_in_delta decayed, 1.0, 0.01
    end

    test "respects custom decay lambda" do
      past = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
      entry = make_entry("old", %{last_accessed_at: past})
      now = DateTime.utc_now()

      # Higher lambda = faster decay
      slow = Scoring.temporal_decay(1.0, entry, now: now, decay_lambda: 0.001)
      fast = Scoring.temporal_decay(1.0, entry, now: now, decay_lambda: 0.1)

      assert fast < slow
    end
  end

  describe "composite_score/3" do
    test "computes score with default weights" do
      entry = make_entry("c", %{importance: 0.8})

      score = Scoring.composite_score(0.9, entry)

      # relevance: 0.5 * 0.9 = 0.45
      # importance: 0.3 * 0.8 = 0.24
      # recency: 0.2 * ~1.0 = ~0.2 (just created)
      assert score > 0.8
      assert score < 1.0
    end

    test "computes score with custom weights" do
      entry = make_entry("c", %{importance: 1.0})

      # Weight importance heavily
      score =
        Scoring.composite_score(0.0, entry,
          weights: [relevance: 0.0, importance: 1.0, recency: 0.0]
        )

      assert_in_delta score, 1.0, 0.01
    end

    test "recency decreases for older entries" do
      recent_entry = make_entry("recent")

      past = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
      old_entry = make_entry("old", %{importance: 0.5, last_accessed_at: past})

      now = DateTime.utc_now()

      recent_score = Scoring.composite_score(0.5, recent_entry, now: now)
      old_score = Scoring.composite_score(0.5, old_entry, now: now)

      assert recent_score > old_score
    end
  end
end

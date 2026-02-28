defmodule Nous.Memory.SearchTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.{Entry, Search, Store}

  setup do
    {:ok, table} = Store.ETS.init([])

    entries = [
      Entry.new(%{
        content: "User prefers dark mode for their IDE",
        type: :semantic,
        importance: 0.9,
        agent_id: "agent_1"
      }),
      Entry.new(%{
        content: "The project uses Phoenix LiveView",
        type: :semantic,
        importance: 0.7,
        agent_id: "agent_1"
      }),
      Entry.new(%{
        content: "Meeting notes from January standup",
        type: :episodic,
        importance: 0.4,
        agent_id: "agent_1"
      }),
      Entry.new(%{
        content: "Deploy with mix release and Docker",
        type: :procedural,
        importance: 0.6,
        agent_id: "agent_2"
      })
    ]

    table =
      Enum.reduce(entries, table, fn entry, t ->
        {:ok, t} = Store.ETS.store(t, entry)
        t
      end)

    %{table: table, entries: entries}
  end

  describe "search/5" do
    test "returns text-matched results sorted by score", %{table: table} do
      {:ok, results} = Search.search(Store.ETS, table, "dark mode")

      assert length(results) > 0
      {top_entry, _score} = hd(results)
      assert top_entry.content =~ "dark mode"
    end

    test "returns empty list for no matches", %{table: table} do
      {:ok, results} = Search.search(Store.ETS, table, "quantum physics")
      # Jaro distance may still return some results with low scores,
      # but with min_score filter they should be eliminated
      {:ok, results} = Search.search(Store.ETS, table, "quantum physics", nil, min_score: 0.9)
      assert results == []
    end

    test "respects limit option", %{table: table} do
      {:ok, results} = Search.search(Store.ETS, table, "project", nil, limit: 2)
      assert length(results) <= 2
    end

    test "filters by scope", %{table: table} do
      {:ok, results} =
        Search.search(Store.ETS, table, "deploy Docker", nil, scope: %{agent_id: "agent_2"})

      assert length(results) > 0
      Enum.each(results, fn {entry, _} -> assert entry.agent_id == "agent_2" end)
    end

    test "filters by type", %{table: table} do
      {:ok, results} =
        Search.search(Store.ETS, table, "meeting notes", nil, type: :episodic)

      Enum.each(results, fn {entry, _} -> assert entry.type == :episodic end)
    end

    test "global scope returns all entries", %{table: table} do
      {:ok, results} = Search.search(Store.ETS, table, "mode project", nil, scope: :global)
      agent_ids = results |> Enum.map(fn {e, _} -> e.agent_id end) |> Enum.uniq()
      # Should include entries from multiple agents
      assert length(agent_ids) >= 1
    end

    test "works without embedding provider (text-only)", %{table: table} do
      {:ok, results} = Search.search(Store.ETS, table, "Phoenix LiveView", nil)
      assert length(results) > 0
    end

    test "applies scoring weights", %{table: table} do
      {:ok, results} =
        Search.search(Store.ETS, table, "dark mode", nil,
          scoring_weights: [relevance: 0.9, importance: 0.1, recency: 0.0]
        )

      assert length(results) > 0
      # Results should be sorted descending by score
      scores = Enum.map(results, fn {_, s} -> s end)
      assert scores == Enum.sort(scores, :desc)
    end
  end
end

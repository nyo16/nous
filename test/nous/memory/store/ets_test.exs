defmodule Nous.Memory.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Entry
  alias Nous.Memory.Store.ETS

  setup do
    {:ok, table} = ETS.init([])
    %{table: table}
  end

  describe "init/1" do
    test "creates a table" do
      {:ok, table} = ETS.init([])
      assert is_reference(table)
    end
  end

  describe "store/2 and fetch/2" do
    test "roundtrip stores and fetches an entry", %{table: table} do
      entry = Entry.new(%{content: "hello world"})
      {:ok, _table} = ETS.store(table, entry)

      assert {:ok, fetched} = ETS.fetch(table, entry.id)
      assert fetched.id == entry.id
      assert fetched.content == "hello world"
    end

    test "fetch returns error for non-existent entry", %{table: table} do
      assert {:error, :not_found} = ETS.fetch(table, "nonexistent")
    end
  end

  describe "delete/2" do
    test "removes an entry", %{table: table} do
      entry = Entry.new(%{content: "to delete"})
      {:ok, _} = ETS.store(table, entry)
      {:ok, _} = ETS.delete(table, entry.id)

      assert {:error, :not_found} = ETS.fetch(table, entry.id)
    end
  end

  describe "update/3" do
    test "updates specific fields on an entry", %{table: table} do
      entry = Entry.new(%{content: "original", importance: 0.5})
      {:ok, _} = ETS.store(table, entry)

      {:ok, _} = ETS.update(table, entry.id, %{importance: 0.9, content: "updated"})

      {:ok, updated} = ETS.fetch(table, entry.id)
      assert updated.importance == 0.9
      assert updated.content == "updated"
      assert updated.updated_at > entry.updated_at || updated.updated_at == entry.updated_at
    end

    test "returns error when entry not found", %{table: table} do
      assert {:error, :not_found} = ETS.update(table, "nonexistent", %{importance: 1.0})
    end
  end

  describe "search_text/3" do
    test "finds entries by fuzzy text match", %{table: table} do
      entry = Entry.new(%{content: "User prefers dark mode"})
      {:ok, _} = ETS.store(table, entry)

      # Also store a less relevant entry
      other = Entry.new(%{content: "The weather is sunny today"})
      {:ok, _} = ETS.store(table, other)

      {:ok, results} = ETS.search_text(table, "dark mode", [])

      assert length(results) > 0
      # The entry containing "dark mode" should rank first
      {top_entry, _top_score} = hd(results)
      assert top_entry.id == entry.id
    end

    test "respects limit option", %{table: table} do
      for i <- 1..5 do
        entry = Entry.new(%{content: "entry #{i}"})
        ETS.store(table, entry)
      end

      {:ok, results} = ETS.search_text(table, "entry", limit: 2)
      assert length(results) == 2
    end

    test "respects min_score option", %{table: table} do
      entry = Entry.new(%{content: "completely unrelated xyz"})
      {:ok, _} = ETS.store(table, entry)

      {:ok, results} = ETS.search_text(table, "dark mode preferences", min_score: 0.9)
      assert results == []
    end

    test "filters by scope", %{table: table} do
      entry_a = Entry.new(%{content: "scoped entry", agent_id: "agent-1"})
      entry_b = Entry.new(%{content: "scoped entry", agent_id: "agent-2"})
      {:ok, _} = ETS.store(table, entry_a)
      {:ok, _} = ETS.store(table, entry_b)

      {:ok, results} = ETS.search_text(table, "scoped entry", scope: %{agent_id: "agent-1"})

      assert length(results) == 1
      {found, _score} = hd(results)
      assert found.agent_id == "agent-1"
    end
  end

  describe "list/2" do
    test "lists all entries", %{table: table} do
      for i <- 1..3 do
        entry = Entry.new(%{content: "entry #{i}"})
        ETS.store(table, entry)
      end

      {:ok, entries} = ETS.list(table, [])
      assert length(entries) == 3
    end

    test "lists entries filtered by scope", %{table: table} do
      a = Entry.new(%{content: "a", namespace: "ns1"})
      b = Entry.new(%{content: "b", namespace: "ns2"})
      c = Entry.new(%{content: "c", namespace: "ns1"})
      {:ok, _} = ETS.store(table, a)
      {:ok, _} = ETS.store(table, b)
      {:ok, _} = ETS.store(table, c)

      {:ok, entries} = ETS.list(table, scope: %{namespace: "ns1"})
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.namespace == "ns1"))
    end

    test "returns empty list when no entries", %{table: table} do
      {:ok, entries} = ETS.list(table, [])
      assert entries == []
    end
  end
end

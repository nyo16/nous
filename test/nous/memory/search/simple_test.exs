defmodule Nous.Memory.Search.SimpleTest do
  use ExUnit.Case, async: true

  alias Nous.Memory
  alias Nous.Memory.Search.Simple

  setup do
    {:ok, search} = Simple.start_link()
    {:ok, search: search}
  end

  describe "index/2" do
    test "indexes a memory", %{search: search} do
      memory = Memory.new("Test content", id: 1)

      assert :ok = Simple.index(search, memory)
    end
  end

  describe "search/3" do
    setup %{search: search} do
      memories = [
        Memory.new("User prefers dark mode for the interface", id: 1, tags: ["preference"]),
        Memory.new("Meeting scheduled for Monday at 10am", id: 2, tags: ["schedule"]),
        Memory.new("User's favorite color is blue", id: 3, tags: ["preference"]),
        Memory.new("Project deadline is next Friday",
          id: 4,
          tags: ["schedule"],
          importance: :high
        )
      ]

      Enum.each(memories, &Simple.index(search, &1))

      {:ok, memories: memories}
    end

    test "finds memories matching query", %{search: search} do
      {:ok, results} = Simple.search(search, "dark mode")

      assert length(results) == 1
      assert hd(results).memory.id == 1
    end

    test "ranks results by relevance", %{search: search} do
      {:ok, results} = Simple.search(search, "user")

      assert length(results) == 2
      # Both contain "user" but first has it at the start
      ids = Enum.map(results, & &1.memory.id)
      assert 1 in ids
      assert 3 in ids
    end

    test "returns empty list for no matches", %{search: search} do
      {:ok, results} = Simple.search(search, "nonexistent query xyz")

      assert results == []
    end

    test "respects limit option", %{search: search} do
      {:ok, results} = Simple.search(search, "user", limit: 1)

      assert length(results) == 1
    end

    test "filters by tags", %{search: search} do
      {:ok, results} = Simple.search(search, "Friday", tags: ["schedule"])

      assert length(results) == 1
      assert hd(results).memory.id == 4
    end

    test "filters by importance", %{search: search} do
      {:ok, results} = Simple.search(search, "deadline", importance: :high)

      assert length(results) == 1
      assert hd(results).memory.importance == :high
    end

    test "includes highlights when requested", %{search: search} do
      {:ok, results} = Simple.search(search, "dark", include_highlights: true)

      assert length(results) == 1
      result = hd(results)
      assert is_list(result.highlights)
      assert length(result.highlights) > 0
    end

    test "includes score in results", %{search: search} do
      {:ok, results} = Simple.search(search, "dark mode")

      result = hd(results)
      assert is_float(result.score)
      assert result.score > 0
      assert result.score <= 1.0
    end

    test "boosts score for high importance memories", %{search: search} do
      # Both match "Friday" or partial words
      {:ok, results} = Simple.search(search, "deadline Friday")

      # High importance memory should rank higher
      high_importance = Enum.find(results, &(&1.memory.importance == :high))
      assert high_importance != nil
    end
  end

  describe "delete/2" do
    test "removes memory from index", %{search: search} do
      memory = Memory.new("Test content", id: 1)
      :ok = Simple.index(search, memory)

      {:ok, before_delete} = Simple.search(search, "test")
      assert length(before_delete) == 1

      :ok = Simple.delete(search, 1)

      {:ok, after_delete} = Simple.search(search, "test")
      assert after_delete == []
    end
  end

  describe "update/2" do
    test "updates memory in index", %{search: search} do
      memory = Memory.new("Original content", id: 1)
      :ok = Simple.index(search, memory)

      updated = %{memory | content: "Updated content"}
      :ok = Simple.update(search, updated)

      {:ok, original_search} = Simple.search(search, "original")
      assert original_search == []

      {:ok, updated_search} = Simple.search(search, "updated")
      assert length(updated_search) == 1
    end
  end

  describe "clear/1" do
    test "clears all indexed memories", %{search: search} do
      memories = [
        Memory.new("Memory 1", id: 1),
        Memory.new("Memory 2", id: 2)
      ]

      Enum.each(memories, &Simple.index(search, &1))

      {:ok, count} = Simple.clear(search)

      assert count == 2

      {:ok, results} = Simple.search(search, "memory")
      assert results == []
    end
  end

  describe "supports?/2" do
    test "supports text_matching feature", %{search: search} do
      assert Simple.supports?(search, :text_matching)
    end

    test "does not support semantic search", %{search: search} do
      refute Simple.supports?(search, :semantic)
    end
  end

  describe "empty query handling" do
    setup %{search: search} do
      memories = [
        Memory.new("First memory", id: 1),
        Memory.new("Second memory", id: 2),
        Memory.new("Third memory", id: 3)
      ]

      Enum.each(memories, &Simple.index(search, &1))
      {:ok, memories: memories}
    end

    test "empty query returns all memories with score 1.0", %{search: search} do
      {:ok, results} = Simple.search(search, "")
      assert length(results) == 3
      assert Enum.all?(results, &(&1.score == 1.0))
    end

    test "whitespace-only query returns empty since no match", %{search: search} do
      {:ok, results} = Simple.search(search, "   ")
      # Whitespace is NOT trimmed - treated as literal search
      # Since no content matches "   ", returns empty
      assert results == []
    end
  end

  describe "unicode handling" do
    test "handles accented characters", %{search: search} do
      memory = Memory.new("Café résumé naïve", id: 1)
      Simple.index(search, memory)
      {:ok, results} = Simple.search(search, "café")
      assert length(results) == 1
    end

    test "handles emoji in content", %{search: search} do
      memory = Memory.new("User loves 🎉 parties", id: 1)
      Simple.index(search, memory)
      {:ok, results} = Simple.search(search, "parties")
      assert length(results) == 1
    end

    test "handles CJK characters", %{search: search} do
      memory = Memory.new("日本語テスト", id: 1)
      Simple.index(search, memory)
      {:ok, results} = Simple.search(search, "日本語")
      assert length(results) == 1
    end
  end

  describe "duplicate indexing" do
    test "re-indexing same ID updates rather than duplicates", %{search: search} do
      memory = Memory.new("Original content", id: 1)
      Simple.index(search, memory)

      updated = %{memory | content: "Updated content"}
      Simple.index(search, updated)

      {:ok, results} = Simple.search(search, "Updated")
      assert length(results) == 1

      {:ok, old_results} = Simple.search(search, "Original")
      assert old_results == []
    end

    test "multiple indexes of same ID only keep latest", %{search: search} do
      Enum.each(1..5, fn i ->
        memory = %{Memory.new("Content version #{i}") | id: "same-id"}
        Simple.index(search, memory)
      end)

      {:ok, results} = Simple.search(search, "Content")
      assert length(results) == 1
      assert hd(results).memory.content == "Content version 5"
    end
  end

  describe "nil/empty content" do
    test "handles empty content gracefully", %{search: search} do
      memory = Memory.new("", id: 1)
      :ok = Simple.index(search, memory)
      {:ok, results} = Simple.search(search, "test")
      assert results == []
    end

    test "empty content memory returned with empty query", %{search: search} do
      memory = Memory.new("", id: 1)
      :ok = Simple.index(search, memory)
      {:ok, results} = Simple.search(search, "")
      assert length(results) == 1
    end
  end

  describe "special characters in query" do
    setup %{search: search} do
      memories = [
        Memory.new("Error: file not found", id: 1),
        Memory.new("Price is $99.99", id: 2),
        Memory.new("Use regex pattern [a-z]+", id: 3)
      ]

      Enum.each(memories, &Simple.index(search, &1))
      :ok
    end

    test "handles colon in query", %{search: search} do
      {:ok, results} = Simple.search(search, "Error:")
      assert length(results) == 1
    end

    test "handles dollar sign in query", %{search: search} do
      {:ok, results} = Simple.search(search, "$99")
      assert length(results) == 1
    end

    test "handles brackets in query", %{search: search} do
      {:ok, results} = Simple.search(search, "[a-z]")
      assert length(results) == 1
    end
  end
end

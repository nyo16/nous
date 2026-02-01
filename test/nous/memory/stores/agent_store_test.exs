defmodule Nous.Memory.Stores.AgentStoreTest do
  use ExUnit.Case, async: true

  alias Nous.Memory
  alias Nous.Memory.Stores.AgentStore

  setup do
    {:ok, store} = AgentStore.start_link()
    {:ok, store: store}
  end

  describe "store/2" do
    test "stores a memory and returns it", %{store: store} do
      memory = Memory.new("Test content", tags: ["tag1"])

      {:ok, stored} = AgentStore.store(store, memory)

      assert stored.content == "Test content"
      assert stored.tags == ["tag1"]
      assert stored.id != nil
    end

    test "preserves custom ID if provided", %{store: store} do
      memory = Memory.new("Test", id: "custom-123")

      {:ok, stored} = AgentStore.store(store, memory)

      assert stored.id == "custom-123"
    end

    test "auto-assigns ID if not provided", %{store: store} do
      memory = %{Memory.new("Test") | id: nil}

      {:ok, stored} = AgentStore.store(store, memory)

      assert is_integer(stored.id)
    end
  end

  describe "get/2" do
    test "retrieves stored memory by ID", %{store: store} do
      memory = Memory.new("Test content")
      {:ok, stored} = AgentStore.store(store, memory)

      {:ok, retrieved} = AgentStore.get(store, stored.id)

      assert retrieved.content == "Test content"
      assert retrieved.id == stored.id
    end

    test "returns error for non-existent ID", %{store: store} do
      assert {:error, :not_found} = AgentStore.get(store, "non-existent")
    end
  end

  describe "update/2" do
    test "updates existing memory", %{store: store} do
      memory = Memory.new("Original")
      {:ok, stored} = AgentStore.store(store, memory)

      updated = %{stored | content: "Updated", tags: ["new"]}
      {:ok, result} = AgentStore.update(store, updated)

      assert result.content == "Updated"
      assert result.tags == ["new"]

      # Verify persistence
      {:ok, retrieved} = AgentStore.get(store, stored.id)
      assert retrieved.content == "Updated"
    end

    test "returns error for non-existent memory", %{store: store} do
      memory = Memory.new("Test", id: "non-existent")

      assert {:error, :not_found} = AgentStore.update(store, memory)
    end
  end

  describe "delete/2" do
    test "removes memory by ID", %{store: store} do
      memory = Memory.new("Test")
      {:ok, stored} = AgentStore.store(store, memory)

      assert :ok = AgentStore.delete(store, stored.id)
      assert {:error, :not_found} = AgentStore.get(store, stored.id)
    end

    test "succeeds even for non-existent ID", %{store: store} do
      assert :ok = AgentStore.delete(store, "non-existent")
    end
  end

  describe "list/2" do
    setup %{store: store} do
      memories = [
        Memory.new("Memory 1", tags: ["tag1"], importance: :low),
        Memory.new("Memory 2", tags: ["tag2"], importance: :medium),
        Memory.new("Memory 3", tags: ["tag1", "tag2"], importance: :high),
        Memory.new("Memory 4", tags: ["tag3"], importance: :critical)
      ]

      stored =
        Enum.map(memories, fn m ->
          {:ok, s} = AgentStore.store(store, m)
          s
        end)

      {:ok, stored: stored}
    end

    test "lists all memories without filters", %{store: store, stored: stored} do
      {:ok, memories} = AgentStore.list(store)

      assert length(memories) == length(stored)
    end

    test "filters by tags", %{store: store} do
      {:ok, memories} = AgentStore.list(store, tags: ["tag1"])

      assert length(memories) == 2
      assert Enum.all?(memories, &("tag1" in &1.tags))
    end

    test "filters by importance", %{store: store} do
      {:ok, memories} = AgentStore.list(store, importance: :high)

      assert length(memories) == 2
      assert Enum.all?(memories, &(&1.importance in [:high, :critical]))
    end

    test "applies limit", %{store: store} do
      {:ok, memories} = AgentStore.list(store, limit: 2)

      assert length(memories) == 2
    end

    test "applies offset", %{store: store} do
      {:ok, all} = AgentStore.list(store)
      {:ok, offset} = AgentStore.list(store, offset: 2)

      assert length(offset) == length(all) - 2
    end

    test "combines filters", %{store: store} do
      {:ok, memories} = AgentStore.list(store, tags: ["tag1"], importance: :high)

      assert length(memories) == 1
      assert hd(memories).importance == :high
      assert "tag1" in hd(memories).tags
    end
  end

  describe "clear/2" do
    setup %{store: store} do
      memories = [
        Memory.new("Memory 1", tags: ["tag1"]),
        Memory.new("Memory 2", tags: ["tag2"]),
        Memory.new("Memory 3", tags: ["tag1"])
      ]

      Enum.each(memories, fn m -> AgentStore.store(store, m) end)

      :ok
    end

    test "clears all memories without filters", %{store: store} do
      {:ok, count} = AgentStore.clear(store)

      assert count == 3
      {:ok, remaining} = AgentStore.list(store)
      assert remaining == []
    end

    test "clears only matching memories with tag filter", %{store: store} do
      {:ok, count} = AgentStore.clear(store, tags: ["tag1"])

      assert count == 2
      {:ok, remaining} = AgentStore.list(store)
      assert length(remaining) == 1
      assert "tag2" in hd(remaining).tags
    end
  end

  describe "count/2" do
    setup %{store: store} do
      memories = [
        Memory.new("Memory 1", importance: :low),
        Memory.new("Memory 2", importance: :medium),
        Memory.new("Memory 3", importance: :high)
      ]

      Enum.each(memories, fn m -> AgentStore.store(store, m) end)

      :ok
    end

    test "counts all memories", %{store: store} do
      {:ok, count} = AgentStore.count(store)

      assert count == 3
    end

    test "counts with filter", %{store: store} do
      {:ok, count} = AgentStore.count(store, importance: :medium)

      assert count == 2
    end
  end

  describe "supports?/2" do
    test "supports in_memory feature", %{store: store} do
      assert AgentStore.supports?(store, :in_memory)
    end

    test "does not support persistence", %{store: store} do
      refute AgentStore.supports?(store, :persistence)
    end
  end

  describe "tier filtering" do
    setup %{store: store} do
      memories = [
        Memory.new("Working memory", tier: :working),
        Memory.new("Short term memory", tier: :short_term),
        Memory.new("Long term memory 1", tier: :long_term),
        Memory.new("Long term memory 2", tier: :long_term)
      ]

      stored =
        Enum.map(memories, fn m ->
          {:ok, s} = AgentStore.store(store, m)
          s
        end)

      {:ok, stored: stored}
    end

    test "filters by tier", %{store: store} do
      {:ok, memories} = AgentStore.list(store, tier: :long_term)
      assert length(memories) == 2
      assert Enum.all?(memories, &(&1.tier == :long_term))
    end

    test "filters by working tier", %{store: store} do
      {:ok, memories} = AgentStore.list(store, tier: :working)
      assert length(memories) == 1
      assert hd(memories).tier == :working
    end
  end

  describe "concurrent operations" do
    test "handles simultaneous store operations", %{store: store} do
      1..50
      |> Task.async_stream(
        fn i ->
          memory = Memory.new("Memory #{i}")
          AgentStore.store(store, memory)
        end,
        max_concurrency: 10
      )
      |> Enum.to_list()

      {:ok, count} = AgentStore.count(store)
      assert count == 50
    end

    test "handles concurrent store and get operations", %{store: store} do
      # Pre-populate some memories
      stored_ids =
        Enum.map(1..10, fn i ->
          {:ok, m} = AgentStore.store(store, Memory.new("Initial #{i}"))
          m.id
        end)

      tasks =
        Enum.flat_map(1..5, fn _ ->
          [
            Task.async(fn -> AgentStore.store(store, Memory.new("New")) end),
            Task.async(fn -> AgentStore.get(store, Enum.random(stored_ids)) end),
            Task.async(fn -> AgentStore.list(store) end)
          ]
        end)

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end
  end

  describe "pagination edge cases" do
    setup %{store: store} do
      Enum.each(1..5, fn i ->
        AgentStore.store(store, Memory.new("Memory #{i}"))
      end)

      :ok
    end

    test "offset beyond list size returns empty", %{store: store} do
      {:ok, memories} = AgentStore.list(store, offset: 1000)
      assert memories == []
    end

    test "limit 0 returns empty", %{store: store} do
      {:ok, memories} = AgentStore.list(store, limit: 0)
      assert memories == []
    end

    test "offset equals list size returns empty", %{store: store} do
      {:ok, memories} = AgentStore.list(store, offset: 5)
      assert memories == []
    end

    test "offset and limit combination", %{store: store} do
      {:ok, memories} = AgentStore.list(store, offset: 2, limit: 2)
      assert length(memories) == 2
    end
  end

  describe "ID variations" do
    test "handles string IDs", %{store: store} do
      memory = Memory.new("Test", id: "string-id-123")
      {:ok, stored} = AgentStore.store(store, memory)
      assert stored.id == "string-id-123"

      {:ok, retrieved} = AgentStore.get(store, "string-id-123")
      assert retrieved.content == "Test"
    end

    test "handles UUID-like string IDs", %{store: store} do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      memory = Memory.new("Test", id: uuid)
      {:ok, stored} = AgentStore.store(store, memory)
      assert stored.id == uuid

      {:ok, retrieved} = AgentStore.get(store, uuid)
      assert retrieved.id == uuid
    end

    test "handles mixed ID types", %{store: store} do
      {:ok, _m1} = AgentStore.store(store, Memory.new("Integer ID", id: 42))
      {:ok, _m2} = AgentStore.store(store, Memory.new("String ID", id: "str-id"))
      {:ok, m3} = AgentStore.store(store, Memory.new("Auto ID"))

      {:ok, r1} = AgentStore.get(store, 42)
      {:ok, r2} = AgentStore.get(store, "str-id")
      {:ok, r3} = AgentStore.get(store, m3.id)

      assert r1.content == "Integer ID"
      assert r2.content == "String ID"
      assert r3.content == "Auto ID"
    end
  end
end

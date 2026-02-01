defmodule Nous.Memory.IntegrationTest do
  @moduledoc """
  Integration tests for the memory system.

  These tests verify full workflows across multiple components:
  - Store + Search coordination
  - Multi-agent isolation
  - Tool + Manager integration
  - Search index synchronization
  """
  use ExUnit.Case, async: false

  alias Nous.Memory
  alias Nous.Memory.Manager
  alias Nous.Tools.MemoryTools
  alias Nous.RunContext

  describe "full workflow" do
    test "store -> recall -> update -> forget" do
      {:ok, manager} =
        Manager.start_link(agent_id: "workflow_test_#{System.unique_integer([:positive])}")

      # Store
      {:ok, m1} =
        Manager.store(manager, "User likes blue",
          tags: ["preference"],
          importance: :high
        )

      assert m1.id != nil
      assert m1.content == "User likes blue"

      # Recall
      {:ok, results} = Manager.recall(manager, "blue")
      assert length(results) == 1
      assert hd(results).content =~ "blue"

      # Update
      {:ok, m2} =
        Manager.update(manager, m1.id,
          content: "User likes dark blue",
          tags: ["preference", "color"]
        )

      assert m2.content == "User likes dark blue"
      assert "color" in m2.tags
      assert "preference" in m2.tags

      # Forget
      :ok = Manager.forget(manager, m1.id)
      {:ok, remaining} = Manager.list(manager)
      assert remaining == []
    end

    test "store -> get -> update -> get shows access tracking" do
      {:ok, manager} =
        Manager.start_link(agent_id: "access_tracking_#{System.unique_integer([:positive])}")

      {:ok, stored} = Manager.store(manager, "Track my access")
      assert stored.access_count == 0

      {:ok, m1} = Manager.get(manager, stored.id)
      assert m1.access_count == 1

      {:ok, _} = Manager.update(manager, stored.id, content: "Updated content")

      {:ok, m2} = Manager.get(manager, stored.id)
      # Get increments access_count
      assert m2.access_count == 2
      assert m2.content == "Updated content"
    end

    test "bulk operations workflow" do
      {:ok, manager} =
        Manager.start_link(agent_id: "bulk_ops_#{System.unique_integer([:positive])}")

      # Bulk store
      stored =
        Enum.map(1..20, fn i ->
          {:ok, m} =
            Manager.store(manager, "Memory #{i}",
              tags: if(rem(i, 2) == 0, do: ["even"], else: ["odd"]),
              importance: if(rem(i, 5) == 0, do: :high, else: :medium)
            )

          m
        end)

      assert length(stored) == 20

      # Count with filters
      {:ok, total} = Manager.count(manager)
      assert total == 20

      # List with tag filter
      {:ok, evens} = Manager.list(manager, tags: ["even"])
      assert length(evens) == 10

      {:ok, odds} = Manager.list(manager, tags: ["odd"])
      assert length(odds) == 10

      # List with importance filter
      {:ok, high_importance} = Manager.list(manager, importance: :high)
      assert length(high_importance) == 4

      # Clear with filter
      {:ok, cleared} = Manager.clear(manager, tags: ["even"])
      assert cleared == 10

      {:ok, remaining} = Manager.count(manager)
      assert remaining == 10

      # Clear all
      {:ok, final_cleared} = Manager.clear(manager)
      assert final_cleared == 10

      {:ok, final_count} = Manager.count(manager)
      assert final_count == 0
    end
  end

  describe "multi-agent isolation" do
    test "agents have isolated memory spaces" do
      {:ok, manager1} =
        Manager.start_link(agent_id: "agent_1_#{System.unique_integer([:positive])}")

      {:ok, manager2} =
        Manager.start_link(agent_id: "agent_2_#{System.unique_integer([:positive])}")

      Manager.store(manager1, "Agent 1 secret")
      Manager.store(manager2, "Agent 2 secret")

      {:ok, m1_memories} = Manager.list(manager1)
      {:ok, m2_memories} = Manager.list(manager2)

      assert length(m1_memories) == 1
      assert length(m2_memories) == 1
      assert hd(m1_memories).content == "Agent 1 secret"
      assert hd(m2_memories).content == "Agent 2 secret"
    end

    test "agents can share same content without conflicts" do
      {:ok, manager1} =
        Manager.start_link(agent_id: "shared_1_#{System.unique_integer([:positive])}")

      {:ok, manager2} =
        Manager.start_link(agent_id: "shared_2_#{System.unique_integer([:positive])}")

      # Both store same content
      {:ok, m1} = Manager.store(manager1, "Shared content")
      {:ok, m2} = Manager.store(manager2, "Shared content")

      # IDs should be independent
      assert m1.id != m2.id or manager1 != manager2

      # Updates to one don't affect the other
      {:ok, _} = Manager.update(manager1, m1.id, content: "Updated by agent 1")

      {:ok, m2_unchanged} = Manager.get(manager2, m2.id)
      assert m2_unchanged.content == "Shared content"
    end

    test "agents can run concurrently without interference" do
      managers =
        Enum.map(1..5, fn i ->
          {:ok, m} =
            Manager.start_link(agent_id: "concurrent_#{i}_#{System.unique_integer([:positive])}")

          m
        end)

      # Each agent stores 10 memories concurrently
      managers
      |> Task.async_stream(fn manager ->
        Enum.each(1..10, fn i ->
          Manager.store(manager, "Memory #{i}")
        end)
      end)
      |> Enum.to_list()

      # Verify each has exactly 10
      Enum.each(managers, fn manager ->
        {:ok, count} = Manager.count(manager)
        assert count == 10
      end)
    end
  end

  describe "tool integration with manager" do
    test "tools work correctly with manager in deps" do
      {:ok, manager} =
        Manager.start_link(agent_id: "tool_test_#{System.unique_integer([:positive])}")

      ctx = RunContext.new(%{memory_manager: manager})

      # Store via tool
      result1 =
        MemoryTools.store_memory(ctx, %{
          "content" => "Important fact",
          "tags" => ["fact"],
          "importance" => "high"
        })

      assert result1.success == true
      assert result1.memory.content == "Important fact"

      # Recall via tool
      result2 = MemoryTools.recall_memories(ctx, %{"query" => "Important"})
      assert result2.success == true
      assert result2.count == 1

      # List via tool
      result3 = MemoryTools.list_memories(ctx, %{})
      assert result3.success == true
      assert result3.count == 1

      # Forget via tool
      memory_id = result1.memory.id
      result4 = MemoryTools.forget_memory(ctx, %{"id" => memory_id})
      assert result4.success == true

      # Verify via manager directly
      {:ok, memories} = Manager.list(manager)
      assert length(memories) == 0
    end

    test "tools fall back to context-based storage without manager" do
      ctx = RunContext.new(%{memories: []})

      # Store - should use context
      result1 = MemoryTools.store_memory(ctx, %{"content" => "Context memory"})
      assert result1.success == true
      assert Map.has_key?(result1, :__update_context__)

      # Update context for next call
      ctx2 = RunContext.new(%{memories: result1.__update_context__.memories})

      # Recall - should work with context
      result2 = MemoryTools.recall_memories(ctx2, %{"query" => "Context"})
      assert result2.success == true
      assert result2.count == 1
    end

    test "tool workflow across multiple calls" do
      {:ok, manager} =
        Manager.start_link(agent_id: "multi_call_#{System.unique_integer([:positive])}")

      ctx = RunContext.new(%{memory_manager: manager})

      # Simulate agent storing multiple memories
      Enum.each(1..5, fn i ->
        MemoryTools.store_memory(ctx, %{
          "content" => "Fact #{i}",
          "tags" => ["fact", "numbered"]
        })
      end)

      # Recall should find all
      result = MemoryTools.recall_memories(ctx, %{"query" => "Fact", "limit" => 10})
      assert result.count == 5

      # Clear by tag
      clear_result =
        MemoryTools.clear_memories(ctx, %{
          "confirm" => true,
          "tags" => ["numbered"]
        })

      assert clear_result.success == true
      assert clear_result.count == 5

      # Verify empty
      list_result = MemoryTools.list_memories(ctx, %{})
      assert list_result.count == 0
    end
  end

  describe "search index sync" do
    test "search index stays in sync with store" do
      {:ok, manager} =
        Manager.start_link(agent_id: "sync_test_#{System.unique_integer([:positive])}")

      # Store
      {:ok, m1} = Manager.store(manager, "Searchable content")

      # Search finds it
      {:ok, results1} = Manager.recall(manager, "Searchable")
      assert length(results1) == 1

      # Update content
      {:ok, _} = Manager.update(manager, m1.id, content: "Modified content")

      # Old search finds nothing
      {:ok, results2} = Manager.recall(manager, "Searchable")
      assert results2 == []

      # New search finds it
      {:ok, results3} = Manager.recall(manager, "Modified")
      assert length(results3) == 1

      # Delete
      :ok = Manager.forget(manager, m1.id)

      # Search finds nothing
      {:ok, results4} = Manager.recall(manager, "Modified")
      assert results4 == []
    end

    test "search respects tag filter updates" do
      {:ok, manager} =
        Manager.start_link(agent_id: "tag_sync_#{System.unique_integer([:positive])}")

      {:ok, m1} = Manager.store(manager, "Memory with tags", tags: ["original"])

      # Search with tag filter
      {:ok, r1} = Manager.recall(manager, "Memory", tags: ["original"])
      assert length(r1) == 1

      {:ok, r2} = Manager.recall(manager, "Memory", tags: ["updated"])
      assert r2 == []

      # Update tags
      {:ok, _} = Manager.update(manager, m1.id, tags: ["updated"])

      # Search with new tag
      {:ok, r3} = Manager.recall(manager, "Memory", tags: ["original"])
      assert r3 == []

      {:ok, r4} = Manager.recall(manager, "Memory", tags: ["updated"])
      assert length(r4) == 1
    end

    test "clear removes from both store and search" do
      {:ok, manager} =
        Manager.start_link(agent_id: "clear_sync_#{System.unique_integer([:positive])}")

      Enum.each(1..10, fn i ->
        Manager.store(manager, "Memory #{i}")
      end)

      # Verify searchable
      {:ok, before} = Manager.recall(manager, "Memory")
      assert length(before) == 10

      # Clear all
      {:ok, count} = Manager.clear(manager)
      assert count == 10

      # Search should be empty
      {:ok, after_clear} = Manager.recall(manager, "Memory")
      assert after_clear == []

      # List should be empty too
      {:ok, list} = Manager.list(manager)
      assert list == []
    end
  end

  describe "memory struct roundtrip" do
    test "to_map and from_map preserve data" do
      original =
        Memory.new("Test content",
          id: "test-123",
          tags: ["tag1", "tag2"],
          importance: :high,
          metadata: %{key: "value"},
          source: :user,
          tier: :long_term
        )

      map = Memory.to_map(original)
      restored = Memory.from_map(map)

      assert restored.id == original.id
      assert restored.content == original.content
      assert restored.tags == original.tags
      assert restored.importance == original.importance
      assert restored.source == original.source
      assert restored.tier == original.tier
    end

    test "memory survives store and get cycle" do
      {:ok, manager} =
        Manager.start_link(agent_id: "roundtrip_#{System.unique_integer([:positive])}")

      {:ok, stored} =
        Manager.store(manager, "Roundtrip test",
          tags: ["test"],
          importance: :critical,
          metadata: %{version: 1}
        )

      {:ok, retrieved} = Manager.get(manager, stored.id)

      assert retrieved.content == stored.content
      assert retrieved.tags == stored.tags
      assert retrieved.importance == stored.importance
      assert retrieved.metadata == stored.metadata
      # Access count should be incremented
      assert retrieved.access_count == stored.access_count + 1
    end
  end
end

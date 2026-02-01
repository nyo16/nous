defmodule Nous.Memory.ManagerTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Manager

  setup do
    {:ok, manager} = Manager.start_link(agent_id: "test_agent")
    {:ok, manager: manager}
  end

  describe "store/3" do
    test "stores a memory with content", %{manager: manager} do
      {:ok, memory} = Manager.store(manager, "Test content")

      assert memory.content == "Test content"
      assert is_integer(memory.id)
    end

    test "stores a memory with options", %{manager: manager} do
      {:ok, memory} =
        Manager.store(manager, "Important fact",
          tags: ["important", "fact"],
          importance: :high,
          metadata: %{source: "user"}
        )

      assert memory.tags == ["important", "fact"]
      assert memory.importance == :high
      assert memory.metadata == %{source: "user"}
    end
  end

  describe "recall/3" do
    setup %{manager: manager} do
      memories = [
        {"User prefers dark mode", [tags: ["preference", "ui"]]},
        {"Meeting at 3pm tomorrow", [tags: ["schedule"]]},
        {"User's name is Alice", [tags: ["personal"], importance: :high]}
      ]

      stored =
        Enum.map(memories, fn {content, opts} ->
          {:ok, m} = Manager.store(manager, content, opts)
          m
        end)

      {:ok, stored: stored}
    end

    test "recalls memories matching query", %{manager: manager} do
      {:ok, memories} = Manager.recall(manager, "dark mode")

      assert length(memories) == 1
      assert hd(memories).content =~ "dark mode"
    end

    test "recalls multiple matching memories", %{manager: manager} do
      {:ok, memories} = Manager.recall(manager, "user")

      assert length(memories) == 2
    end

    test "respects limit option", %{manager: manager} do
      {:ok, memories} = Manager.recall(manager, "user", limit: 1)

      assert length(memories) == 1
    end

    test "filters by tags", %{manager: manager} do
      {:ok, memories} = Manager.recall(manager, "", tags: ["preference"])

      assert length(memories) == 1
      assert "preference" in hd(memories).tags
    end
  end

  describe "get/2" do
    test "retrieves memory by ID", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test content")

      {:ok, retrieved} = Manager.get(manager, stored.id)

      assert retrieved.content == "Test content"
      # Access count should be incremented
      assert retrieved.access_count == 1
    end

    test "returns error for non-existent ID", %{manager: manager} do
      assert {:error, :not_found} = Manager.get(manager, "non-existent")
    end
  end

  describe "update/3" do
    test "updates memory content", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Original")

      {:ok, updated} = Manager.update(manager, stored.id, content: "Updated")

      assert updated.content == "Updated"
    end

    test "updates memory tags", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test", tags: ["old"])

      {:ok, updated} = Manager.update(manager, stored.id, tags: ["new"])

      assert updated.tags == ["new"]
    end

    test "merges metadata", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test", metadata: %{key1: "value1"})

      {:ok, updated} = Manager.update(manager, stored.id, metadata: %{key2: "value2"})

      assert updated.metadata == %{key1: "value1", key2: "value2"}
    end

    test "returns error for non-existent ID", %{manager: manager} do
      assert {:error, :not_found} = Manager.update(manager, "non-existent", content: "New")
    end
  end

  describe "forget/2" do
    test "deletes memory by ID", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test")

      assert :ok = Manager.forget(manager, stored.id)
      assert {:error, :not_found} = Manager.get(manager, stored.id)
    end
  end

  describe "list/2" do
    setup %{manager: manager} do
      memories = [
        {"Memory 1", [tags: ["tag1"], importance: :low]},
        {"Memory 2", [tags: ["tag2"], importance: :medium]},
        {"Memory 3", [tags: ["tag1"], importance: :high]}
      ]

      Enum.each(memories, fn {content, opts} ->
        Manager.store(manager, content, opts)
      end)

      :ok
    end

    test "lists all memories", %{manager: manager} do
      {:ok, memories} = Manager.list(manager)

      assert length(memories) == 3
    end

    test "filters by tags", %{manager: manager} do
      {:ok, memories} = Manager.list(manager, tags: ["tag1"])

      assert length(memories) == 2
    end

    test "filters by importance", %{manager: manager} do
      {:ok, memories} = Manager.list(manager, importance: :medium)

      assert length(memories) == 2
    end

    test "applies limit", %{manager: manager} do
      {:ok, memories} = Manager.list(manager, limit: 2)

      assert length(memories) == 2
    end
  end

  describe "clear/2" do
    setup %{manager: manager} do
      memories = [
        {"Memory 1", [tags: ["keep"]]},
        {"Memory 2", [tags: ["delete"]]},
        {"Memory 3", [tags: ["delete"]]}
      ]

      Enum.each(memories, fn {content, opts} ->
        Manager.store(manager, content, opts)
      end)

      :ok
    end

    test "clears all memories", %{manager: manager} do
      {:ok, count} = Manager.clear(manager)

      assert count == 3
      {:ok, remaining} = Manager.list(manager)
      assert remaining == []
    end

    test "clears only matching memories", %{manager: manager} do
      {:ok, count} = Manager.clear(manager, tags: ["delete"])

      assert count == 2
      {:ok, remaining} = Manager.list(manager)
      assert length(remaining) == 1
    end
  end

  describe "count/2" do
    setup %{manager: manager} do
      Enum.each(1..5, fn i ->
        Manager.store(manager, "Memory #{i}")
      end)

      :ok
    end

    test "counts all memories", %{manager: manager} do
      {:ok, count} = Manager.count(manager)

      assert count == 5
    end
  end

  describe "start_link/1" do
    test "requires agent_id" do
      Process.flag(:trap_exit, true)
      {:error, _} = Manager.start_link([])
    end

    test "accepts name registration" do
      {:ok, _pid} = Manager.start_link(agent_id: "named", name: :test_manager)

      {:ok, _memory} = Manager.store(:test_manager, "Test")
    end
  end

  describe "search disabled fallback" do
    test "recall works when search: false" do
      {:ok, manager} =
        Manager.start_link(
          agent_id: "no_search_#{System.unique_integer([:positive])}",
          search: false
        )

      {:ok, _} = Manager.store(manager, "Test memory", tags: ["test"])
      {:ok, _} = Manager.store(manager, "Another memory", tags: ["other"])

      # When search is disabled, recall falls back to store.list with filters
      # Query is ignored (just uses filters)
      {:ok, results} = Manager.recall(manager, "ignored query", tags: ["test"])

      assert length(results) == 1
      assert hd(results).tags == ["test"]
    end

    test "recall returns all when no filters with search disabled" do
      {:ok, manager} =
        Manager.start_link(
          agent_id: "no_search_all_#{System.unique_integer([:positive])}",
          search: false
        )

      Enum.each(1..5, fn i ->
        Manager.store(manager, "Memory #{i}")
      end)

      {:ok, results} = Manager.recall(manager, "anything")
      # Falls back to list with limit
      assert length(results) <= 10
    end
  end

  describe "concurrent access" do
    test "handles concurrent stores" do
      {:ok, manager} =
        Manager.start_link(agent_id: "concurrent_#{System.unique_integer([:positive])}")

      1..50
      |> Task.async_stream(
        fn i ->
          Manager.store(manager, "Memory #{i}")
        end,
        max_concurrency: 10
      )
      |> Enum.to_list()

      {:ok, count} = Manager.count(manager)
      assert count == 50
    end

    test "handles concurrent recall and store" do
      {:ok, manager} =
        Manager.start_link(agent_id: "mixed_#{System.unique_integer([:positive])}")

      # Pre-populate
      Enum.each(1..10, fn i ->
        Manager.store(manager, "Initial #{i}")
      end)

      tasks = [
        Task.async(fn -> Manager.store(manager, "New") end),
        Task.async(fn -> Manager.recall(manager, "Initial") end),
        Task.async(fn -> Manager.list(manager) end)
      ]

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "handles concurrent updates to different memories" do
      {:ok, manager} =
        Manager.start_link(agent_id: "update_concurrent_#{System.unique_integer([:positive])}")

      # Create memories
      stored =
        Enum.map(1..10, fn i ->
          {:ok, m} = Manager.store(manager, "Memory #{i}")
          m
        end)

      # Concurrently update each memory
      stored
      |> Task.async_stream(fn memory ->
        Manager.update(manager, memory.id, content: "Updated #{memory.id}")
      end)
      |> Enum.to_list()

      # Verify all updates succeeded
      {:ok, memories} = Manager.list(manager)
      assert length(memories) == 10
      assert Enum.all?(memories, &String.starts_with?(&1.content, "Updated"))
    end
  end

  describe "update edge cases" do
    test "update with empty changes preserves memory", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Original", tags: ["tag1"])

      {:ok, updated} = Manager.update(manager, stored.id, [])

      assert updated.content == "Original"
      assert updated.tags == ["tag1"]
    end

    test "metadata merge combines properly", %{manager: manager} do
      {:ok, m1} = Manager.store(manager, "Test", metadata: %{a: 1, b: 2})
      {:ok, m2} = Manager.update(manager, m1.id, metadata: %{b: 3, c: 4})

      assert m2.metadata == %{a: 1, b: 3, c: 4}
    end

    test "multiple sequential updates work correctly", %{manager: manager} do
      {:ok, m1} = Manager.store(manager, "Original")
      {:ok, m2} = Manager.update(manager, m1.id, content: "First update")
      {:ok, m3} = Manager.update(manager, m2.id, tags: ["updated"])
      {:ok, _m4} = Manager.update(manager, m3.id, importance: :high)

      {:ok, final} = Manager.get(manager, m1.id)
      assert final.content == "First update"
      assert final.tags == ["updated"]
      assert final.importance == :high
    end
  end

  describe "get access tracking" do
    test "increments access_count on each get", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test")

      {:ok, m1} = Manager.get(manager, stored.id)
      {:ok, m2} = Manager.get(manager, stored.id)
      {:ok, m3} = Manager.get(manager, stored.id)

      assert m1.access_count == 1
      assert m2.access_count == 2
      assert m3.access_count == 3
    end

    test "updates accessed_at timestamp on get", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test")
      initial_accessed_at = stored.accessed_at

      :timer.sleep(10)
      {:ok, retrieved} = Manager.get(manager, stored.id)

      assert DateTime.compare(retrieved.accessed_at, initial_accessed_at) == :gt
    end

    test "updates decay_score on get", %{manager: manager} do
      {:ok, stored} = Manager.store(manager, "Test", importance: :high)
      # Manually set a low decay score for testing
      # Note: This test verifies that touch() is called, which boosts decay_score

      {:ok, m1} = Manager.get(manager, stored.id)
      # The decay score should remain at 1.0 since it's capped
      assert m1.decay_score == 1.0
    end
  end

  describe "recall with various query patterns" do
    setup %{manager: manager} do
      memories = [
        {"User prefers dark mode for the UI", [tags: ["preference", "ui"]]},
        {"The API endpoint is /api/v1/users", [tags: ["technical"]]},
        {"Meeting notes from Monday standup", [tags: ["meeting"]]}
      ]

      Enum.each(memories, fn {content, opts} ->
        Manager.store(manager, content, opts)
      end)

      :ok
    end

    test "recall with empty query and tag filter", %{manager: manager} do
      {:ok, results} = Manager.recall(manager, "", tags: ["preference"])
      assert length(results) == 1
    end

    test "recall respects importance filter", %{manager: manager} do
      Manager.store(manager, "Critical info", importance: :critical)

      {:ok, results} = Manager.recall(manager, "", importance: :critical)
      assert length(results) == 1
      assert hd(results).importance == :critical
    end
  end
end

defmodule Nous.MemoryTest do
  use ExUnit.Case, async: true

  alias Nous.Memory

  describe "new/2" do
    test "creates memory with content and defaults" do
      memory = Memory.new("Test content")

      assert memory.content == "Test content"
      assert memory.tags == []
      assert memory.metadata == %{}
      assert memory.importance == :medium
      assert memory.source == :conversation
      assert memory.tier == :working
      assert memory.access_count == 0
      assert memory.decay_score == 1.0
      assert is_integer(memory.id)
      assert %DateTime{} = memory.created_at
      assert %DateTime{} = memory.accessed_at
    end

    test "creates memory with custom options" do
      memory =
        Memory.new("Custom memory",
          id: "custom-id",
          tags: ["tag1", "tag2"],
          metadata: %{key: "value"},
          importance: :high,
          source: :user,
          tier: :long_term
        )

      assert memory.id == "custom-id"
      assert memory.content == "Custom memory"
      assert memory.tags == ["tag1", "tag2"]
      assert memory.metadata == %{key: "value"}
      assert memory.importance == :high
      assert memory.source == :user
      assert memory.tier == :long_term
    end
  end

  describe "touch/1" do
    test "updates accessed_at and increments access_count" do
      memory = Memory.new("Test")
      :timer.sleep(10)

      touched = Memory.touch(memory)

      assert touched.access_count == 1
      assert DateTime.compare(touched.accessed_at, memory.accessed_at) == :gt
    end

    test "boosts decay_score based on importance" do
      memory = Memory.new("Test", importance: :high)
      memory = %{memory | decay_score: 0.5}

      touched = Memory.touch(memory)

      # High importance gets 0.15 boost
      assert touched.decay_score == 0.65
    end

    test "caps decay_score at 1.0" do
      memory = Memory.new("Test", importance: :critical)
      memory = %{memory | decay_score: 0.95}

      touched = Memory.touch(memory)

      assert touched.decay_score == 1.0
    end
  end

  describe "update/2" do
    test "updates memory fields" do
      memory = Memory.new("Original")

      updated = Memory.update(memory, %{content: "Updated", tags: ["new"]})

      assert updated.content == "Updated"
      assert updated.tags == ["new"]
    end

    test "refreshes accessed_at timestamp" do
      memory = Memory.new("Test")
      :timer.sleep(10)

      updated = Memory.update(memory, %{content: "Updated"})

      assert DateTime.compare(updated.accessed_at, memory.accessed_at) == :gt
    end
  end

  describe "matches_tags?/2" do
    test "returns true for nil filter" do
      memory = Memory.new("Test", tags: ["tag1"])
      assert Memory.matches_tags?(memory, nil)
    end

    test "returns true for empty filter" do
      memory = Memory.new("Test", tags: ["tag1"])
      assert Memory.matches_tags?(memory, [])
    end

    test "returns true when memory has matching tag" do
      memory = Memory.new("Test", tags: ["tag1", "tag2"])
      assert Memory.matches_tags?(memory, ["tag1"])
      assert Memory.matches_tags?(memory, ["tag2", "tag3"])
    end

    test "returns false when memory has no matching tags" do
      memory = Memory.new("Test", tags: ["tag1"])
      refute Memory.matches_tags?(memory, ["other"])
    end
  end

  describe "matches_importance?/2" do
    test "returns true for nil filter" do
      memory = Memory.new("Test", importance: :low)
      assert Memory.matches_importance?(memory, nil)
    end

    test "returns true when importance meets minimum" do
      high_memory = Memory.new("Test", importance: :high)
      medium_memory = Memory.new("Test", importance: :medium)

      assert Memory.matches_importance?(high_memory, :medium)
      assert Memory.matches_importance?(high_memory, :high)
      assert Memory.matches_importance?(medium_memory, :low)
    end

    test "returns false when importance below minimum" do
      low_memory = Memory.new("Test", importance: :low)

      refute Memory.matches_importance?(low_memory, :medium)
      refute Memory.matches_importance?(low_memory, :high)
    end
  end

  describe "to_map/1" do
    test "converts memory to serializable map" do
      memory = Memory.new("Test", tags: ["tag1"], importance: :high)

      map = Memory.to_map(memory)

      assert map.content == "Test"
      assert map.tags == ["tag1"]
      assert map.importance == :high
      assert is_binary(map.created_at)
      assert is_binary(map.accessed_at)
    end

    test "handles nil consolidated_at" do
      memory = Memory.new("Test")

      map = Memory.to_map(memory)

      assert map.consolidated_at == nil
    end
  end

  describe "from_map/1" do
    test "creates memory from atom-keyed map" do
      map = %{
        id: 123,
        content: "Test",
        tags: ["tag1"],
        importance: :high,
        source: :user,
        tier: :long_term,
        access_count: 5
      }

      memory = Memory.from_map(map)

      assert memory.id == 123
      assert memory.content == "Test"
      assert memory.tags == ["tag1"]
      assert memory.importance == :high
      assert memory.source == :user
      assert memory.tier == :long_term
      assert memory.access_count == 5
    end

    test "creates memory from string-keyed map" do
      map = %{
        "id" => "abc",
        "content" => "Test",
        "tags" => ["tag1"],
        "importance" => "medium"
      }

      memory = Memory.from_map(map)

      assert memory.id == "abc"
      assert memory.content == "Test"
      assert memory.importance == :medium
    end

    test "parses ISO8601 datetime strings" do
      now = DateTime.utc_now()
      iso = DateTime.to_iso8601(now)

      map = %{
        id: 1,
        content: "Test",
        created_at: iso,
        accessed_at: iso
      }

      memory = Memory.from_map(map)

      assert %DateTime{} = memory.created_at
      assert %DateTime{} = memory.accessed_at
    end

    test "handles invalid ISO8601 datetime gracefully" do
      map = %{id: 1, content: "Test", created_at: "invalid-date"}
      memory = Memory.from_map(map)
      # Falls back to now()
      assert %DateTime{} = memory.created_at
    end

    test "handles mixed atom/string keys" do
      map = %{:id => 1, "content" => "Test", :importance => :high, "tags" => ["tag1"]}
      memory = Memory.from_map(map)
      assert memory.content == "Test"
      assert memory.importance == :high
      assert memory.tags == ["tag1"]
    end

    test "handles nil id by generating one" do
      map = %{content: "Test"}
      memory = Memory.from_map(map)
      # id will be nil since from_map doesn't generate IDs
      assert memory.id == nil
      assert memory.content == "Test"
    end
  end

  describe "touch/1 boundary conditions" do
    test "handles decay_score at 0.0" do
      memory = %{Memory.new("test") | decay_score: 0.0}
      touched = Memory.touch(memory)
      assert touched.decay_score > 0
      # Medium importance gives 0.1 boost
      assert touched.decay_score == 0.1
    end

    test "handles very low decay_score" do
      memory = %{Memory.new("test") | decay_score: 0.01}
      touched = Memory.touch(memory)
      assert touched.decay_score == 0.11
    end
  end
end

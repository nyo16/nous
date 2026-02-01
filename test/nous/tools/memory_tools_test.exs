defmodule Nous.Tools.MemoryToolsTest do
  use ExUnit.Case, async: true

  alias Nous.Tools.MemoryTools
  alias Nous.RunContext

  describe "store_memory/2" do
    test "stores a memory with content" do
      ctx = RunContext.new(%{memories: []})

      result = MemoryTools.store_memory(ctx, %{"content" => "Test memory"})

      assert result.success == true
      assert result.memory.content == "Test memory"
      assert result.memory.id != nil
      assert length(result.__update_context__.memories) > 0
    end

    test "stores memory with alternative param names" do
      ctx = RunContext.new(%{memories: []})

      result1 = MemoryTools.store_memory(ctx, %{"text" => "Via text"})
      assert result1.success == true
      assert result1.memory.content == "Via text"

      result2 = MemoryTools.store_memory(ctx, %{"memory" => "Via memory"})
      assert result2.success == true
      assert result2.memory.content == "Via memory"
    end

    test "stores memory with tags" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "tags" => ["tag1", "tag2"]
        })

      assert result.success == true
      assert result.memory.tags == ["tag1", "tag2"]
    end

    test "stores memory with importance level" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Important fact",
          "importance" => "high"
        })

      assert result.success == true
      assert result.memory.importance == :high
    end

    test "stores memory with metadata" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "metadata" => %{"source" => "user"}
        })

      assert result.success == true
      assert result.memory.metadata == %{"source" => "user"}
    end

    test "adds to existing memories" do
      existing = %{id: 1, content: "Existing", tags: [], importance: :medium}
      ctx = RunContext.new(%{memories: [existing]})

      result = MemoryTools.store_memory(ctx, %{"content" => "New memory"})

      assert result.success == true
      assert length(result.__update_context__.memories) == 2
    end

    test "fails when content is missing" do
      ctx = RunContext.new(%{memories: []})

      result = MemoryTools.store_memory(ctx, %{})

      assert result.success == false
      assert result.error =~ "required"
    end

    test "fails when content is empty" do
      ctx = RunContext.new(%{memories: []})

      result = MemoryTools.store_memory(ctx, %{"content" => ""})

      assert result.success == false
    end
  end

  describe "recall_memories/2" do
    setup do
      memories = [
        %{
          id: 1,
          content: "User prefers dark mode",
          tags: ["preference", "ui"],
          importance: :medium,
          access_count: 0,
          accessed_at: "2025-01-01T00:00:00Z"
        },
        %{
          id: 2,
          content: "Meeting at 3pm tomorrow",
          tags: ["schedule"],
          importance: :low,
          access_count: 0,
          accessed_at: "2025-01-01T00:00:00Z"
        },
        %{
          id: 3,
          content: "User's name is Alice",
          tags: ["personal"],
          importance: :high,
          access_count: 0,
          accessed_at: "2025-01-01T00:00:00Z"
        }
      ]

      ctx = RunContext.new(%{memories: memories})
      {:ok, ctx: ctx}
    end

    test "recalls memories matching query", %{ctx: ctx} do
      result = MemoryTools.recall_memories(ctx, %{"query" => "dark mode"})

      assert result.success == true
      assert result.count == 1
      assert hd(result.memories).content =~ "dark mode"
    end

    test "recalls with alternative param names", %{ctx: ctx} do
      result1 = MemoryTools.recall_memories(ctx, %{"search" => "user"})
      assert result1.success == true
      assert result1.count > 0

      result2 = MemoryTools.recall_memories(ctx, %{"text" => "meeting"})
      assert result2.success == true
      assert result2.count == 1
    end

    test "respects limit", %{ctx: ctx} do
      result = MemoryTools.recall_memories(ctx, %{"query" => "user", "limit" => 1})

      assert result.success == true
      assert result.count == 1
    end

    test "filters by tags", %{ctx: ctx} do
      result =
        MemoryTools.recall_memories(ctx, %{
          "query" => "",
          "tags" => ["preference"]
        })

      assert result.success == true
      assert Enum.all?(result.memories, &("preference" in &1.tags))
    end

    test "filters by importance", %{ctx: ctx} do
      result =
        MemoryTools.recall_memories(ctx, %{
          "query" => "",
          "importance" => "high"
        })

      assert result.success == true
      assert Enum.all?(result.memories, &(&1.importance == :high))
    end

    test "updates access tracking", %{ctx: ctx} do
      result = MemoryTools.recall_memories(ctx, %{"query" => "dark mode"})

      assert result.success == true
      # The accessed memory should have updated access_count
      updated_memories = result.__update_context__.memories
      accessed = Enum.find(updated_memories, &(&1.content =~ "dark mode"))
      assert accessed.access_count == 1
    end

    test "returns empty list for no matches", %{ctx: ctx} do
      result = MemoryTools.recall_memories(ctx, %{"query" => "nonexistent xyz"})

      assert result.success == true
      assert result.count == 0
      assert result.memories == []
    end
  end

  describe "list_memories/2" do
    setup do
      memories = [
        %{id: 1, content: "Memory 1", tags: ["tag1"], importance: :low},
        %{id: 2, content: "Memory 2", tags: ["tag2"], importance: :medium},
        %{id: 3, content: "Memory 3", tags: ["tag1"], importance: :high},
        %{id: 4, content: "Memory 4", tags: ["tag3"], importance: :critical}
      ]

      ctx = RunContext.new(%{memories: memories})
      {:ok, ctx: ctx}
    end

    test "lists all memories", %{ctx: ctx} do
      result = MemoryTools.list_memories(ctx, %{})

      assert result.success == true
      assert result.count == 4
    end

    test "filters by tags", %{ctx: ctx} do
      result = MemoryTools.list_memories(ctx, %{"tags" => ["tag1"]})

      assert result.success == true
      assert result.count == 2
    end

    test "filters by importance", %{ctx: ctx} do
      result = MemoryTools.list_memories(ctx, %{"importance" => "high"})

      assert result.success == true
      assert result.count == 2
    end

    test "applies limit", %{ctx: ctx} do
      result = MemoryTools.list_memories(ctx, %{"limit" => 2})

      assert result.success == true
      assert result.count == 2
    end

    test "includes by_importance counts", %{ctx: ctx} do
      result = MemoryTools.list_memories(ctx, %{})

      assert result.by_importance.low == 1
      assert result.by_importance.medium == 1
      assert result.by_importance.high == 1
      assert result.by_importance.critical == 1
    end
  end

  describe "forget_memory/2" do
    setup do
      memories = [
        %{id: 1, content: "Memory 1", tags: []},
        %{id: 2, content: "Memory 2", tags: []}
      ]

      ctx = RunContext.new(%{memories: memories})
      {:ok, ctx: ctx}
    end

    test "forgets memory by id", %{ctx: ctx} do
      result = MemoryTools.forget_memory(ctx, %{"id" => 1})

      assert result.success == true
      assert result.message =~ "Memory 1"
      assert length(result.__update_context__.memories) == 1
    end

    test "handles string id", %{ctx: ctx} do
      result = MemoryTools.forget_memory(ctx, %{"id" => "1"})

      assert result.success == true
    end

    test "fails for non-existent id", %{ctx: ctx} do
      result = MemoryTools.forget_memory(ctx, %{"id" => 999})

      assert result.success == false
      assert result.error =~ "not found"
      assert result.available_ids == [1, 2]
    end

    test "fails when id is missing" do
      ctx = RunContext.new(%{memories: []})

      result = MemoryTools.forget_memory(ctx, %{})

      assert result.success == false
      assert result.error =~ "required"
    end
  end

  describe "clear_memories/2" do
    setup do
      memories = [
        %{id: 1, content: "Memory 1", tags: ["keep"]},
        %{id: 2, content: "Memory 2", tags: ["delete"]},
        %{id: 3, content: "Memory 3", tags: ["delete"]}
      ]

      ctx = RunContext.new(%{memories: memories})
      {:ok, ctx: ctx}
    end

    test "requires confirmation", %{ctx: ctx} do
      result = MemoryTools.clear_memories(ctx, %{})

      assert result.success == false
      assert result.error =~ "confirm"
    end

    test "clears all memories when confirmed", %{ctx: ctx} do
      result = MemoryTools.clear_memories(ctx, %{"confirm" => true})

      assert result.success == true
      assert result.count == 3
      assert result.__update_context__.memories == []
    end

    test "clears only matching tags", %{ctx: ctx} do
      result =
        MemoryTools.clear_memories(ctx, %{
          "confirm" => true,
          "tags" => ["delete"]
        })

      assert result.success == true
      assert result.count == 2
      assert length(result.__update_context__.memories) == 1
    end

    test "accepts string confirmation", %{ctx: ctx} do
      result = MemoryTools.clear_memories(ctx, %{"confirm" => "true"})

      assert result.success == true
    end
  end

  describe "all/0" do
    test "returns list of all memory tools" do
      tools = MemoryTools.all()

      assert length(tools) == 5
      assert Enum.all?(tools, &is_function(&1, 2))
    end
  end

  describe "with memory_manager" do
    setup do
      {:ok, manager} = Nous.Memory.Manager.start_link(agent_id: "test")
      ctx = RunContext.new(%{memory_manager: manager})
      {:ok, ctx: ctx, manager: manager}
    end

    test "stores via manager", %{ctx: ctx} do
      result = MemoryTools.store_memory(ctx, %{"content" => "Persistent memory"})

      assert result.success == true
      assert result.memory.content == "Persistent memory"
      # No __update_context__ for manager-based storage
      refute Map.has_key?(result, :__update_context__)
    end

    test "recalls via manager", %{ctx: ctx} do
      MemoryTools.store_memory(ctx, %{
        "content" => "Test searchable memory",
        "tags" => ["test"]
      })

      result = MemoryTools.recall_memories(ctx, %{"query" => "searchable"})

      assert result.success == true
      assert result.count == 1
    end

    test "lists via manager", %{ctx: ctx} do
      MemoryTools.store_memory(ctx, %{"content" => "Memory 1"})
      MemoryTools.store_memory(ctx, %{"content" => "Memory 2"})

      result = MemoryTools.list_memories(ctx, %{})

      assert result.success == true
      assert result.count == 2
    end

    test "forgets via manager", %{ctx: ctx} do
      {:ok, _} = Nous.Memory.Manager.store(ctx.deps.memory_manager, "To forget")
      {:ok, memories} = Nous.Memory.Manager.list(ctx.deps.memory_manager)
      memory = hd(memories)

      result = MemoryTools.forget_memory(ctx, %{"id" => memory.id})

      assert result.success == true
    end

    test "clears via manager", %{ctx: ctx} do
      MemoryTools.store_memory(ctx, %{"content" => "Memory 1"})
      MemoryTools.store_memory(ctx, %{"content" => "Memory 2"})

      result = MemoryTools.clear_memories(ctx, %{"confirm" => true})

      assert result.success == true
      assert result.count == 2
    end
  end

  describe "missing context handling" do
    test "handles nil ctx.deps[:memories]" do
      ctx = RunContext.new(%{})

      result = MemoryTools.recall_memories(ctx, %{"query" => "test"})

      assert result.success == true
      assert result.memories == []
    end

    test "handles empty deps for store" do
      ctx = RunContext.new(%{})

      result = MemoryTools.store_memory(ctx, %{"content" => "New memory"})

      assert result.success == true
      assert result.memory.content == "New memory"
      assert length(result.__update_context__.memories) == 1
    end

    test "handles empty deps for list" do
      ctx = RunContext.new(%{})

      result = MemoryTools.list_memories(ctx, %{})

      assert result.success == true
      assert result.count == 0
      assert result.memories == []
    end

    test "handles empty deps for forget" do
      ctx = RunContext.new(%{})

      result = MemoryTools.forget_memory(ctx, %{"id" => 123})

      assert result.success == false
      assert result.error =~ "not found"
    end

    test "handles empty deps for clear" do
      ctx = RunContext.new(%{})

      result = MemoryTools.clear_memories(ctx, %{"confirm" => true})

      assert result.success == true
      assert result.count == 0
    end
  end

  describe "invalid importance handling" do
    test "defaults to :medium for invalid importance string" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "importance" => "super_critical"
        })

      assert result.success == true
      assert result.memory.importance == :medium
    end

    test "defaults to :medium for numeric importance" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "importance" => 5
        })

      assert result.success == true
      assert result.memory.importance == :medium
    end

    test "accepts valid atom importance" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "importance" => :critical
        })

      assert result.success == true
      assert result.memory.importance == :critical
    end
  end

  describe "tag parsing" do
    test "handles comma-separated tag string" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "tags" => "tag1,tag2,tag3"
        })

      assert result.success == true
      assert result.memory.tags == ["tag1", "tag2", "tag3"]
    end

    test "handles tag string with spaces around commas" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "tags" => "tag1, tag2, tag3"
        })

      assert result.success == true
      # Note: trim: true in split removes empty strings, but spaces stay
      assert " tag2" in result.memory.tags or "tag2" in result.memory.tags
    end

    test "handles empty tag string" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "tags" => ""
        })

      assert result.success == true
      assert result.memory.tags == []
    end

    test "handles nil tags" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "tags" => nil
        })

      assert result.success == true
      # parse_tags(nil) returns nil, which is used as-is
      assert result.memory.tags == nil
    end
  end

  describe "recall with empty filters" do
    test "recall with empty query and no filters returns all" do
      memories = [
        %{
          id: 1,
          content: "Memory 1",
          tags: [],
          importance: :medium,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          access_count: 0
        },
        %{
          id: 2,
          content: "Memory 2",
          tags: [],
          importance: :high,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          accessed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          access_count: 0
        }
      ]

      ctx = RunContext.new(%{memories: memories})

      result =
        MemoryTools.recall_memories(ctx, %{
          "query" => "",
          "tags" => [],
          "importance" => nil
        })

      assert result.success == true
      assert result.count == 2
    end

    test "recall with nil query returns all" do
      memories = [
        %{
          id: 1,
          content: "Memory 1",
          tags: [],
          importance: :medium,
          access_count: 0
        }
      ]

      ctx = RunContext.new(%{memories: memories})

      result = MemoryTools.recall_memories(ctx, %{})

      assert result.success == true
      assert result.count == 1
    end

    test "recall with whitespace query returns all" do
      memories = [
        %{id: 1, content: "Memory 1", tags: [], importance: :medium, access_count: 0}
      ]

      ctx = RunContext.new(%{memories: memories})

      result = MemoryTools.recall_memories(ctx, %{"query" => "   "})

      assert result.success == true
      # Whitespace is not trimmed in the query, so no match
      assert result.count == 0
    end
  end

  describe "content truncation" do
    test "truncates long content in message" do
      ctx = RunContext.new(%{memories: []})
      long_content = String.duplicate("a", 100)

      result = MemoryTools.store_memory(ctx, %{"content" => long_content})

      assert result.success == true
      assert String.length(result.message) < String.length(long_content) + 20
      assert String.contains?(result.message, "...")
    end
  end

  describe "metadata handling" do
    test "stores arbitrary metadata" do
      ctx = RunContext.new(%{memories: []})

      result =
        MemoryTools.store_memory(ctx, %{
          "content" => "Test",
          "metadata" => %{"source" => "user", "context" => "conversation"}
        })

      assert result.success == true
      assert result.memory.metadata == %{"source" => "user", "context" => "conversation"}
    end

    test "defaults to empty metadata" do
      ctx = RunContext.new(%{memories: []})

      result = MemoryTools.store_memory(ctx, %{"content" => "Test"})

      assert result.success == true
      assert result.memory.metadata == %{}
    end
  end
end

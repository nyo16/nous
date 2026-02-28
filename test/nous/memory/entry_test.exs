defmodule Nous.Memory.EntryTest do
  use ExUnit.Case, async: true

  alias Nous.Memory.Entry

  describe "new/1" do
    test "creates entry with required content" do
      entry = Entry.new(%{content: "hello world"})

      assert entry.content == "hello world"
      assert is_binary(entry.id)
      assert byte_size(entry.id) == 32
    end

    test "defaults type to :semantic" do
      entry = Entry.new(%{content: "test"})
      assert entry.type == :semantic
    end

    test "defaults importance to 0.5" do
      entry = Entry.new(%{content: "test"})
      assert entry.importance == 0.5
    end

    test "defaults evergreen to false" do
      entry = Entry.new(%{content: "test"})
      assert entry.evergreen == false
    end

    test "defaults metadata to empty map" do
      entry = Entry.new(%{content: "test"})
      assert entry.metadata == %{}
    end

    test "defaults access_count to 0" do
      entry = Entry.new(%{content: "test"})
      assert entry.access_count == 0
    end

    test "auto-generates id and timestamps" do
      entry = Entry.new(%{content: "test"})

      assert is_binary(entry.id)
      assert %DateTime{} = entry.created_at
      assert %DateTime{} = entry.updated_at
      assert %DateTime{} = entry.last_accessed_at
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now()

      entry =
        Entry.new(%{
          content: "important fact",
          type: :episodic,
          importance: 0.9,
          evergreen: true,
          embedding: [0.1, 0.2, 0.3],
          metadata: %{source: "test"},
          agent_id: "agent-1",
          session_id: "session-1",
          user_id: "user-1",
          namespace: "project-x",
          created_at: now,
          updated_at: now,
          last_accessed_at: now
        })

      assert entry.content == "important fact"
      assert entry.type == :episodic
      assert entry.importance == 0.9
      assert entry.evergreen == true
      assert entry.embedding == [0.1, 0.2, 0.3]
      assert entry.metadata == %{source: "test"}
      assert entry.agent_id == "agent-1"
      assert entry.session_id == "session-1"
      assert entry.user_id == "user-1"
      assert entry.namespace == "project-x"
      assert entry.created_at == now
      assert entry.updated_at == now
      assert entry.last_accessed_at == now
    end

    test "allows custom id" do
      entry = Entry.new(%{content: "test", id: "custom-id"})
      assert entry.id == "custom-id"
    end

    test "raises on missing content" do
      assert_raise KeyError, fn ->
        Entry.new(%{})
      end
    end
  end
end

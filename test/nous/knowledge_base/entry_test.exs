defmodule Nous.KnowledgeBase.EntryTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.Entry

  describe "new/1" do
    test "creates entry with required title and content" do
      entry = Entry.new(%{title: "GenServer Patterns", content: "# GenServer\n..."})

      assert entry.title == "GenServer Patterns"
      assert entry.content == "# GenServer\n..."
      assert is_binary(entry.id)
      assert byte_size(entry.id) == 32
    end

    test "auto-generates slug from title" do
      entry = Entry.new(%{title: "Elixir GenServer Patterns", content: "test"})
      assert entry.slug == "elixir-genserver-patterns"
    end

    test "defaults entry_type to :article" do
      entry = Entry.new(%{title: "test", content: "test"})
      assert entry.entry_type == :article
    end

    test "defaults confidence to 0.5" do
      entry = Entry.new(%{title: "test", content: "test"})
      assert entry.confidence == 0.5
    end

    test "defaults concepts and tags to empty lists" do
      entry = Entry.new(%{title: "test", content: "test"})
      assert entry.concepts == []
      assert entry.tags == []
    end

    test "defaults source_doc_ids to empty list" do
      entry = Entry.new(%{title: "test", content: "test"})
      assert entry.source_doc_ids == []
    end

    test "defaults metadata to empty map" do
      entry = Entry.new(%{title: "test", content: "test"})
      assert entry.metadata == %{}
    end

    test "auto-generates id and timestamps" do
      entry = Entry.new(%{title: "test", content: "test"})

      assert is_binary(entry.id)
      assert %DateTime{} = entry.created_at
      assert %DateTime{} = entry.updated_at
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now()

      entry =
        Entry.new(%{
          title: "OTP Supervision",
          content: "# Supervision\n...",
          slug: "custom-slug",
          summary: "How OTP supervision trees work",
          entry_type: :concept,
          concepts: ["supervision", "otp", "fault-tolerance"],
          tags: ["elixir", "otp"],
          confidence: 0.9,
          source_doc_ids: ["doc-1", "doc-2"],
          embedding: [0.1, 0.2, 0.3],
          metadata: %{reviewed: true},
          kb_id: "my-kb",
          created_at: now,
          updated_at: now,
          last_verified_at: now
        })

      assert entry.slug == "custom-slug"
      assert entry.summary == "How OTP supervision trees work"
      assert entry.entry_type == :concept
      assert entry.concepts == ["supervision", "otp", "fault-tolerance"]
      assert entry.tags == ["elixir", "otp"]
      assert entry.confidence == 0.9
      assert entry.source_doc_ids == ["doc-1", "doc-2"]
      assert entry.embedding == [0.1, 0.2, 0.3]
      assert entry.metadata == %{reviewed: true}
      assert entry.kb_id == "my-kb"
      assert entry.last_verified_at == now
    end

    test "allows custom id" do
      entry = Entry.new(%{title: "test", content: "test", id: "custom-id"})
      assert entry.id == "custom-id"
    end

    test "raises on missing title" do
      # apply/3 hides the literal struct from dialyzer's incompatible-types check.
      assert_raise KeyError, fn ->
        apply(Entry, :new, [%{content: "test"}])
      end
    end

    test "raises on missing content" do
      assert_raise KeyError, fn ->
        apply(Entry, :new, [%{title: "test"}])
      end
    end
  end

  describe "slugify/1" do
    test "converts title to lowercase kebab-case" do
      assert Entry.slugify("Elixir GenServer Patterns") == "elixir-genserver-patterns"
    end

    test "removes special characters" do
      assert Entry.slugify("What's New in OTP 27?") == "whats-new-in-otp-27"
    end

    test "collapses multiple spaces and hyphens" do
      assert Entry.slugify("Too   Many   Spaces") == "too-many-spaces"
      assert Entry.slugify("Already---Hyphenated") == "already-hyphenated"
    end

    test "trims leading and trailing hyphens" do
      assert Entry.slugify(" Leading Space ") == "leading-space"
      assert Entry.slugify("-Dashes-") == "dashes"
    end

    test "handles underscores" do
      assert Entry.slugify("snake_case_title") == "snake-case-title"
    end

    test "handles empty string" do
      assert Entry.slugify("") == ""
    end
  end
end
